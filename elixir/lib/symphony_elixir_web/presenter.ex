defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{
    ApprovalStore,
    Artifact,
    CodexTranscript,
    Config,
    DispatchGate,
    OperatorFeedback,
    Orchestrator,
    StatusDashboard,
    Workspace
  }

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        # The gate and the review approvals are read once per payload: the
        # dashboard needs a run status and a review decision on every tracker row
        # and every blocked row, and they all come from two files.
        gate_statuses = DispatchGate.statuses()
        review_approved = ApprovalStore.review_approved_ids()
        tracker = tracker_payload(Map.get(snapshot, :tracker), snapshot, gate_statuses, review_approved)

        blocked =
          Enum.map(
            Map.get(snapshot, :blocked, []),
            &blocked_entry_payload(&1, gate_statuses, review_approved)
          )

        %{
          generated_at: generated_at,
          counts: %{
            tracker_active: length(tracker.issues),
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(blocked),
            waiting: Enum.count(tracker.issues, &(&1.run_status == :waiting)),
            paused: Enum.count(tracker.issues, &(&1.run_status == :paused))
          },
          tracker: tracker,
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: blocked,
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs:
          issue_id_from_entries(running, retry, blocked)
          |> transcript_runs_payload()
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      recent_events: recent_events_payload(entry),
      # A run in flight has whatever earlier phases published, which is what makes
      # the approved analysis readable while the implementation is still running.
      artifacts: entry.issue_id |> Artifact.list() |> Enum.map(&artifact_payload/1),
      transcript: transcript_payload(entry.issue_id),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry, gate_statuses, review_approved) do
    block_reason = Map.get(entry, :block_reason, :input_required)
    reviewed? = MapSet.member?(review_approved, entry.issue_id)
    gate_phase = gate_phase(block_reason, entry.issue_id, reviewed?)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      block_reason: block_reason,
      run_status: run_status(gate_statuses, entry.issue_id),
      review_approved: reviewed?,
      # The artifact this gate is asking about comes first; the earlier phases stay
      # reachable, because reviewing an implementation means reading it against the
      # analysis it was built from.
      gate_phase: gate_phase,
      artifact: artifact_payload(Artifact.fetch(entry.issue_id, gate_phase)),
      artifacts: entry.issue_id |> Artifact.list() |> Enum.map(&artifact_payload/1),
      transcript: transcript_payload(entry.issue_id),
      feedback: feedback_payload(entry.issue_id),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      recent_events: recent_events_payload(entry),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  # Which phase's deliverable this gate is asking the operator to judge. The block
  # reason names it wherever a phase ended at a gate; anything else — Codex asked
  # for input, no tracker progress — is a stop inside a phase, so the current one
  # is what they are looking at.
  defp gate_phase(:awaiting_analysis_approval, _issue_id, _reviewed), do: :analysis
  defp gate_phase(:analysis_incomplete, _issue_id, _reviewed), do: :analysis
  defp gate_phase(:awaiting_merge, _issue_id, _reviewed), do: :summary
  defp gate_phase(:summary_incomplete, _issue_id, _reviewed), do: :summary

  # The review gate is reached twice, so a sign-off already on record means the
  # operator is looking at the summary, not at the implementation again. This
  # mirrors `Orchestrator.advance_decision/3`, which reads the same signal.
  defp gate_phase(:awaiting_human_review, _issue_id, true), do: :summary
  defp gate_phase(:awaiting_human_review, _issue_id, _reviewed), do: :implementation

  defp gate_phase(_block_reason, issue_id, _reviewed),
    do: SymphonyElixir.AgentRunner.phase_for(%{id: issue_id})

  # Only the metadata travels in the payload: the body can be a whole analysis
  # document, and this payload is rebuilt on every dashboard tick.
  # The transcript is what an operator falls back to when the gate has no artifact
  # to show, so the link only claims to exist once a run has actually recorded one.
  defp transcript_payload(issue_id) when is_binary(issue_id) do
    case CodexTranscript.runs(issue_id) do
      [] ->
        nil

      [latest | _rest] = runs ->
        %{
          path: "/transcripts/#{URI.encode(issue_id)}",
          runs: length(runs),
          bytes: latest.bytes,
          recorded_at: latest.recorded_at
        }
    end
  end

  defp transcript_payload(_issue_id), do: nil

  defp transcript_runs_payload(issue_id) when is_binary(issue_id) do
    Enum.map(CodexTranscript.runs(issue_id), fn run ->
      %{
        run: run.name,
        bytes: run.bytes,
        recorded_at: run.recorded_at,
        path: "/transcripts/#{URI.encode(issue_id)}?run=#{URI.encode(run.name)}"
      }
    end)
  end

  defp transcript_runs_payload(_issue_id), do: []

  defp artifact_payload(nil), do: nil

  defp artifact_payload(artifact) do
    %{
      phase: artifact.phase,
      title: artifact.title,
      format: artifact.format,
      bytes: artifact.bytes,
      published_at: artifact.published_at,
      path: "/artifacts/#{URI.encode(artifact.issue_id)}/#{artifact.phase}"
    }
  end

  # Feedback the operator already sent is what tells them whether their last
  # correction reached a run, so it travels with the blocked entry itself.
  defp feedback_payload(issue_id) do
    issue_id
    |> OperatorFeedback.notes()
    |> Enum.map(fn note ->
      %{
        note: note.note,
        phase: note.phase,
        requested_at: note.requested_at,
        requested_by: note.requested_by,
        delivered: not is_nil(note.delivered_at)
      }
    end)
  end

  defp tracker_payload(tracker, snapshot, gate_statuses, review_approved) when is_map(tracker) do
    runtime_statuses = tracker_runtime_statuses(snapshot)

    %{
      source: Map.get(tracker, :source),
      active_states: Map.get(tracker, :active_states, []),
      synced_at: iso8601(Map.get(tracker, :synced_at)),
      issues:
        tracker
        |> Map.get(:issues, [])
        |> Enum.map(&tracker_issue_payload(&1, runtime_statuses, gate_statuses, review_approved))
    }
  end

  defp tracker_payload(_tracker, _snapshot, _gate_statuses, _review_approved) do
    %{source: nil, active_states: [], synced_at: nil, issues: []}
  end

  defp tracker_runtime_statuses(snapshot) do
    [
      {Map.get(snapshot, :running, []), "running"},
      {Map.get(snapshot, :retrying, []), "retrying"},
      {Map.get(snapshot, :blocked, []), "blocked"}
    ]
    |> Enum.flat_map(fn {entries, status} ->
      Enum.map(entries, &{Map.get(&1, :issue_id), status})
    end)
    |> Map.new()
  end

  defp tracker_issue_payload(issue, runtime_statuses, gate_statuses, review_approved) do
    issue_id = Map.get(issue, :issue_id)
    run_status = run_status(gate_statuses, issue_id)
    reviewed? = MapSet.member?(review_approved, issue_id)
    block_reason = row_block_reason(issue_id, reviewed?)

    %{
      issue_id: issue_id,
      issue_identifier: Map.get(issue, :identifier),
      title: Map.get(issue, :title),
      state: Map.get(issue, :state),
      issue_url: Map.get(issue, :issue_url),
      priority: Map.get(issue, :priority),
      labels: Map.get(issue, :labels, []),
      assignee_id: Map.get(issue, :assignee_id),
      updated_at: iso8601(Map.get(issue, :updated_at)),
      run_status: run_status,
      review_approved: reviewed?,
      block_reason: block_reason,
      # What the orchestrator is doing with the item only matters once the operator
      # has released it; before that the row's own gate status is the honest answer.
      runtime_status: runtime_status(run_status, runtime_statuses, issue_id, block_reason, reviewed?)
    }
  end

  defp run_status(gate_statuses, issue_id), do: Map.get(gate_statuses, issue_id, :waiting)

  # The row carries the same button as the gate card, so it needs the same answer
  # about whether the summary phase delivered. A signed-off review with no summary
  # artifact is not at the finish gate, whatever the dispatch status says, and a
  # row that offered "确认完成" there would contradict the card right below it.
  defp row_block_reason(issue_id, true) do
    if Artifact.exists?(issue_id, :summary), do: nil, else: :summary_incomplete
  end

  defp row_block_reason(_issue_id, _reviewed), do: nil

  defp runtime_status(:waiting, _runtime_statuses, _issue_id, _block_reason, _reviewed), do: "waiting"
  defp runtime_status(:paused, _runtime_statuses, _issue_id, _block_reason, _reviewed), do: "paused"

  defp runtime_status(_run_status, _runtime_statuses, _issue_id, :summary_incomplete, _reviewed),
    do: "summary_missing"

  # The review gate is reached twice, and which side of the summary run an item is
  # on is the difference between "read this diff" and "merge it".
  defp runtime_status(:review, _runtime_statuses, _issue_id, _block_reason, true), do: "merge_pending"
  defp runtime_status(:review, _runtime_statuses, _issue_id, _block_reason, _reviewed), do: "review"

  defp runtime_status(:started, runtime_statuses, issue_id, _block_reason, _reviewed),
    do: Map.get(runtime_statuses, issue_id, "queued")

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, Workspace.workspace_key(issue_identifier))
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    case Map.get(entry, :codex_activity, []) do
      [] ->
        # This list drives the dashboard's activity column, so a message with no
        # timestamp is still worth showing.
        [
          %{
            at: iso8601(entry.last_codex_timestamp),
            event: entry.last_codex_event,
            message: summarize_message(entry.last_codex_message)
          }
        ]
        |> Enum.reject(&(is_nil(&1.at) and is_nil(&1.message) and is_nil(&1.event)))

      activity ->
        Enum.map(activity, fn event ->
          %{
            at: iso8601(Map.get(event, :at)),
            event: Map.get(event, :event),
            message: Map.get(event, :message)
          }
        end)
    end
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
