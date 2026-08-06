defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Artifact,
    ApprovalStore,
    Config,
    DispatchGate,
    OperatorFeedback,
    StatusDashboard,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Consecutive continuation runs without tracker progress before the issue is
  # treated as waiting on an operator instead of being dispatched again.
  @max_idle_continuations 3
  # Per-issue ring of recent Codex activity kept for the dashboard.
  @codex_activity_limit 25
  # Bookkeeping traffic that says nothing about what the agent is doing. Keeping
  # it out of the activity log is what makes the log readable.
  @codex_activity_noise_methods [
    "account/rateLimits/updated",
    "account/updated",
    "account/chatgptAuthTokens/refresh",
    "thread/tokenUsage/updated",
    "item/reasoning/summaryPartAdded"
  ]
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @paused_error "paused by the operator; no further runs until it is resumed"
  @review_error "implementation gates passed; waiting for operator review"
  @summary_error "merge-request summary written; waiting for the operator to finish the ticket"
  @summary_missing_error "summary run ended without publishing a merge-request summary artifact"
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      continuations: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      tracker_issues: [],
      tracker_synced_at: nil
    ]
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil
        }

        run_terminal_workspace_cleanup()
        state = schedule_tick(state, 0)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    cond do
      DispatchGate.review?(issue_id) ->
        block_review_handoff_agent_down(state, issue_id, running_entry, session_id)

      DispatchGate.paused?(issue_id) ->
        block_paused_agent_down(state, issue_id, running_entry, session_id)

      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)

      not ApprovalStore.approved?(issue_id) ->
        block_awaiting_approval_agent_down(state, issue_id, running_entry, session_id)

      ApprovalStore.review_approved?(issue_id) ->
        block_summary_agent_down(state, issue_id, running_entry, session_id)

      true ->
        continue_or_block_agent_down(state, issue_id, running_entry, session_id)
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    cond do
      DispatchGate.review?(issue_id) ->
        block_review_handoff_agent_down(state, issue_id, running_entry, session_id)

      # A pause outranks the retry ladder: an exit that would normally be retried
      # is the operator's cue that this item is going nowhere.
      DispatchGate.paused?(issue_id) ->
        block_paused_agent_down(state, issue_id, running_entry, session_id)

      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)

      true ->
        retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  # The same handoff tool ends both the implementation run and the summary run, so
  # what the operator is being asked for is read from the review approval rather
  # than from the call: before it, "does this change look right"; after it, "the
  # description is written, the merge is yours".
  defp block_review_handoff_agent_down(state, issue_id, running_entry, session_id) do
    {error, reason} = review_gate_state(issue_id)

    Logger.info("Agent task handed off for review: issue_id=#{issue_id} issue_identifier=#{Map.get(running_entry, :identifier)} session_id=#{session_id} reason=#{reason}")

    block_issue_from_entry(state, issue_id, running_entry, error, reason)
  end

  # The summary phase ends at an operator gate, not at a tracker state change, so
  # a run that returns without handing off parks here rather than continuing on
  # the ticket still being active — its phase has nothing left to do with the
  # extra turns. Which gate it parks at is the artifact's question: the whole
  # point of this phase is the merge-request description, and a run that produced
  # none is parked as incomplete so the operator sends it back instead of being
  # asked to finish a ticket whose summary they cannot read.
  defp block_summary_agent_down(state, issue_id, running_entry, session_id) do
    if Artifact.exists?(issue_id, :summary) do
      # Handing off is what normally records this gate. A run that published its
      # summary and then ended without calling the tool is standing in the same
      # place, so the gate is recorded for it — otherwise a restart would find no
      # held item and dispatch the finished phase again.
      _ =
        DispatchGate.handoff_for_review(issue_id,
          identifier: Map.get(running_entry, :identifier),
          updated_by: "orchestrator-summary-complete"
        )
    end

    {error, reason} = review_gate_state(issue_id)

    Logger.info("Summary phase ended: issue_id=#{issue_id} issue_identifier=#{Map.get(running_entry, :identifier)} session_id=#{session_id} reason=#{reason}")

    block_issue_from_entry(state, issue_id, running_entry, error, reason)
  end

  # The same handoff ends both review gates, and both are rebuilt from the store
  # after a restart, so which gate an item is at — and whether the phase that led
  # to it actually delivered — is answered in one place.
  defp review_gate_state(issue_id) do
    cond do
      not ApprovalStore.review_approved?(issue_id) -> {@review_error, :awaiting_human_review}
      Artifact.exists?(issue_id, :summary) -> {@summary_error, :awaiting_merge}
      true -> {@summary_missing_error, :summary_incomplete}
    end
  end

  defp block_paused_agent_down(state, issue_id, running_entry, session_id) do
    Logger.info("Agent task parked for paused issue: issue_id=#{issue_id} issue_identifier=#{Map.get(running_entry, :identifier)} session_id=#{session_id}")

    state
    |> block_issue_from_entry(issue_id, running_entry, @paused_error, :operator_paused)
    |> stamp_gate_time(issue_id)
  end

  # The analysis phase ends at an operator decision, not at a tracker state
  # change, so the item parks here until the dashboard approves it. Approval is
  # only offered once the deliverable actually exists; a run that ended without
  # publishing one is parked as incomplete instead, so the operator is never asked
  # to approve something they cannot read.
  defp block_awaiting_approval_agent_down(state, issue_id, running_entry, session_id) do
    identifier = running_entry.identifier

    {error, reason} =
      if Artifact.exists?(issue_id, :analysis) do
        {"analysis complete; waiting for operator approval before implementation", :awaiting_analysis_approval}
      else
        {"analysis run ended without publishing an analysis artifact", :analysis_incomplete}
      end

    Logger.info("Issue blocked before implementation: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} reason=#{reason}")

    block_issue_from_entry(state, issue_id, running_entry, error, reason)
  end

  defp continue_or_block_agent_down(state, issue_id, running_entry, session_id) do
    continuation = bump_continuation(state, issue_id, running_entry)

    if continuation.idle >= @max_idle_continuations do
      block_idle_continuation_agent_down(state, issue_id, running_entry, session_id, continuation)
    else
      Logger.info(
        "Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check (streak #{continuation.streak}, idle #{continuation.idle}/#{@max_idle_continuations})"
      )

      state
      |> put_continuation(issue_id, continuation)
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        delay_type: :continuation,
        continuation_streak: continuation.streak,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp block_idle_continuation_agent_down(state, issue_id, running_entry, session_id, continuation) do
    error =
      "agent completed #{continuation.idle} consecutive runs without tracker progress; waiting for operator action"

    Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}; #{error}")

    state
    |> put_continuation(issue_id, continuation)
    |> block_issue_from_entry(issue_id, running_entry, error, :no_tracker_progress)
  end

  # Continuation bookkeeping. `streak` counts every consecutive continuation run
  # and drives the reschedule backoff; `idle` counts only the runs that left the
  # tracker item untouched and drives the operator block.
  defp bump_continuation(%State{} = state, issue_id, running_entry) do
    previous = Map.get(state.continuations, issue_id, %{streak: 0, idle: 0, updated_at: nil})
    updated_at = running_entry |> Map.get(:issue) |> issue_updated_at()

    idle =
      if tracker_progressed?(Map.get(previous, :updated_at), updated_at) do
        0
      else
        Map.get(previous, :idle, 0) + 1
      end

    %{streak: Map.get(previous, :streak, 0) + 1, idle: idle, updated_at: updated_at}
  end

  defp put_continuation(%State{} = state, issue_id, continuation) do
    %{state | continuations: Map.put(state.continuations, issue_id, continuation)}
  end

  defp issue_updated_at(%Issue{updated_at: updated_at}), do: updated_at
  defp issue_updated_at(_issue), do: nil

  # A first observation carries no baseline, so it never counts as progress.
  defp tracker_progressed?(nil, _current), do: false
  defp tracker_progressed?(_previous, nil), do: false

  defp tracker_progressed?(%DateTime{} = previous, %DateTime{} = current) do
    DateTime.compare(current, previous) == :gt
  end

  defp tracker_progressed?(previous, current), do: previous != current

  # An issue parked for lack of progress resumes as soon as the tracker item
  # actually moves; operator-input blocks stay put until the state changes.
  defp idle_block_released?(%{block_reason: :no_tracker_progress} = blocked_entry, %Issue{} = issue) do
    tracker_progressed?(Map.get(blocked_entry, :blocked_updated_at), issue.updated_at)
  end

  defp idle_block_released?(_blocked_entry, _issue), do: false

  @doc false
  @spec idle_block_released_for_test?(map(), Issue.t()) :: boolean()
  def idle_block_released_for_test?(blocked_entry, %Issue{} = issue),
    do: idle_block_released?(blocked_entry, issue)

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_intake_issues() do
      state = %{
        state
        | tracker_issues: issues,
          tracker_synced_at: DateTime.utc_now()
      }

      state = park_gated_issues(state, issues)

      if available_slots(state) > 0 do
        choose_issues(issues, state)
      else
        state
      end
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(state, terminal_state_set())
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(state, terminal_state_set())
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(
          Issue.t(),
          term(),
          String.t(),
          non_neg_integer(),
          map()
        ) ::
          term()
  def handle_retry_issue_lookup_for_test(
        %Issue{} = issue,
        %State{} = state,
        issue_id,
        attempt,
        metadata
      )
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} =
      handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)

    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, terminal_states),
      terminal_states
    )
  end

  # A run ends when the ticket is finished or is no longer ours. It does not end
  # because someone moved the ticket between open states: the operator's start,
  # pause, and the tracker's terminal states are the signals now, and treating a
  # column change as "stop" would kill runs the operator explicitly began.
  defp reconcile_issue_state(%Issue{} = issue, state, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        forget_dispatch_gate(issue.id)
        terminate_running_issue(state, issue.id, true)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      true ->
        refresh_running_issue_state(state, issue)
    end
  end

  defp reconcile_issue_state(_issue, state, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, terminal_states),
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")

        cleanup_issue_workspace(issue, Map.get(state.blocked, issue.id, %{}))
        forget_dispatch_gate(issue.id)
        release_issue_claim(state, issue.id)

      # Nothing but an explicit resume clears a pause, so the checks below that
      # release a block on their own do not get a say here.
      DispatchGate.paused?(issue.id) or DispatchGate.review?(issue.id) ->
        refresh_blocked_issue_state(state, issue)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")

        release_issue_claim(state, issue.id)

      idle_block_released?(Map.get(state.blocked, issue.id), issue) ->
        Logger.info("Blocked issue saw tracker progress: #{issue_context(issue)} updated_at=#{inspect(issue.updated_at)}; releasing block")

        release_issue_claim(state, issue.id)

      true ->
        refresh_blocked_issue_state(state, issue)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _terminal_states), do: state

  # A finished ticket keeps no start on record: if it is ever reopened it should
  # wait for a fresh decision instead of resuming on its own.
  defp forget_dispatch_gate(issue_id) do
    _ = DispatchGate.forget(issue_id)
    # The deliverables were for the gates this ticket has now passed through; a
    # finished ticket keeps them no more than it keeps its worktree.
    _ = Artifact.clear(issue_id)
    :ok
  end

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")

        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        stop_running_task(pid, ref, state.task_supervisor)

        if cleanup_workspace do
          cleanup_issue_workspace(Map.get(running_entry, :issue, identifier), running_entry)
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            continuations: Map.delete(state.continuations, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error =
          blocker_error(
            running_entry,
            "stalled for #{elapsed_ms}ms after Codex requested operator input"
          )

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: identifier,
          issue_url: running_entry.issue.url,
          error: "stalled for #{elapsed_ms}ms without codex activity"
        })
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] ->
        "codex turn requires operator input"

      :approval_required ->
        "codex turn requires approval"

      nil ->
        nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_running_task(pid, ref, task_supervisor) do
    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error, reason \\ :input_required) do
    stop_running_task(
      Map.get(running_entry, :pid),
      Map.get(running_entry, :ref),
      state.task_supervisor
    )

    block_issue_from_entry(state, issue_id, running_entry, error, reason)
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error, reason \\ :input_required) do
    issue = Map.get(running_entry, :issue)

    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: issue,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      error: error,
      block_reason: reason,
      blocked_updated_at: issue_updated_at(issue),
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp),
      codex_activity: Map.get(running_entry, :codex_activity, [])
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  # A gate has to survive a restart. The blocked entry is what carries the gate's
  # artifact, its feedback box, and its decision button, and it lives in memory —
  # so both held states are rebuilt from the store on every poll rather than only
  # when a run ends. Without this a restart leaves an item parked at the review
  # gate with nothing on screen to act on. Items already parked are left alone:
  # re-parking them each poll would reset the entry and repeat the log line.
  defp park_gated_issues(%State{} = state, issues) when is_list(issues) do
    gate_statuses = DispatchGate.statuses()

    if map_size(gate_statuses) == 0 do
      state
    else
      Enum.reduce(issues, state, &maybe_park_gated_issue(&2, &1, gate_statuses))
    end
  end

  defp maybe_park_gated_issue(%State{} = state, %Issue{id: issue_id}, gate_statuses)
       when is_binary(issue_id) do
    blocked_entry = Map.get(state.blocked, issue_id)

    case Map.get(gate_statuses, issue_id) do
      :paused ->
        if paused_block?(blocked_entry), do: state, else: park_paused_issue(state, issue_id)

      :review ->
        if review_block?(blocked_entry), do: state, else: park_review_issue(state, issue_id)

      _ ->
        state
    end
  end

  defp maybe_park_gated_issue(state, _issue, _gate_statuses), do: state

  # The agent's handoff parked this item while the previous orchestrator was
  # running; rebuilding it here is what keeps the gate usable across a restart.
  # Which of the two review gates it is comes from the review approval, exactly as
  # it does when the run ends.
  defp park_review_issue(%State{} = state, issue_id) do
    source =
      state.blocked
      |> Map.get(issue_id, %{})
      |> Map.merge(gated_issue_context(state, issue_id))

    {error, reason} = review_gate_state(issue_id)

    Logger.info("Parking issue held for review: issue_id=#{issue_id} issue_identifier=#{Map.get(source, :identifier)} reason=#{reason}")

    state
    |> block_issue_from_entry(issue_id, source, error, reason)
    |> stamp_gate_time(issue_id)
  end

  defp review_block?(blocked_entry) when is_map(blocked_entry),
    do:
      Map.get(blocked_entry, :block_reason) in [
        :awaiting_human_review,
        :awaiting_merge,
        :summary_incomplete
      ]

  defp review_block?(_blocked_entry), do: false

  # Every route into a pause — parked mid-run, parked at the next poll after a
  # restart, parked while the item waited at another block — lands in the same
  # entry shape, so the dashboard and the dispatch guards only have one state to
  # reason about.
  defp park_paused_issue(%State{} = state, issue_id, source \\ %{}) do
    state =
      case Map.get(state.running, issue_id) do
        nil ->
          block_paused_issue(state, issue_id, Map.merge(Map.get(state.blocked, issue_id, %{}), source))

        running_entry ->
          Logger.info("Stopping agent for paused issue: issue_id=#{issue_id} issue_identifier=#{Map.get(running_entry, :identifier)} session_id=#{running_entry_session_id(running_entry)}")

          state
          |> record_session_completion_totals(running_entry)
          |> stop_and_block_issue(issue_id, running_entry, @paused_error, :operator_paused)
      end

    stamp_gate_time(state, issue_id)
  end

  defp block_paused_issue(%State{} = state, issue_id, source) do
    source = Map.merge(source, gated_issue_context(state, issue_id))

    Logger.info("Parking paused issue: issue_id=#{issue_id} issue_identifier=#{Map.get(source, :identifier)}")

    block_issue_from_entry(state, issue_id, source, @paused_error, :operator_paused)
  end

  # The blocked entry carries the tracker item so the dashboard can link it, and
  # a pause recorded from the dashboard may be the first time this orchestrator
  # has seen the item at all.
  defp gated_issue_context(%State{} = state, issue_id) do
    case known_issue(state, issue_id) do
      %Issue{} = issue -> %{identifier: issue.identifier, issue: issue}
      nil -> %{}
    end
  end

  defp known_issue(%State{} = state, issue_id) do
    entry_issue(Map.get(state.running, issue_id)) || entry_issue(Map.get(state.blocked, issue_id)) ||
      Enum.find(state.tracker_issues, &match?(%Issue{id: ^issue_id}, &1))
  end

  defp entry_issue(%{issue: %Issue{} = issue}), do: issue
  defp entry_issue(_entry), do: nil

  # `blocked_at` would otherwise read as the moment the block was rebuilt, which
  # after a restart says nothing. The operator wants to know when the gate closed.
  defp stamp_gate_time(%State{} = state, issue_id) do
    with %{updated_at: paused_at} when is_binary(paused_at) <- DispatchGate.fetch(issue_id),
         {:ok, paused_at, _offset} <- DateTime.from_iso8601(paused_at),
         %{} = blocked_entry <- Map.get(state.blocked, issue_id) do
      %{state | blocked: Map.put(state.blocked, issue_id, %{blocked_entry | blocked_at: paused_at})}
    else
      _ -> state
    end
  end

  defp paused_block?(blocked_entry) when is_map(blocked_entry),
    do: Map.get(blocked_entry, :block_reason) == :operator_paused

  defp paused_block?(_blocked_entry), do: false

  # Starting a ticket should be visible to everyone looking at the board, not just
  # to whoever pressed the button, so the tracker item moves into the configured
  # start state as part of the click. It is reported back rather than enforced: the
  # local gate already authorized the run, and a tracker that refuses the write is
  # a board-accuracy problem, not a reason to withhold the work.
  defp move_started_issue_to_start_state(%State{} = state, issue_id) do
    with {:ok, state_name} <- configured_start_state(),
         %Issue{} = issue <- known_issue(state, issue_id) do
      if normalize_issue_state(issue.state) == normalize_issue_state(state_name) do
        {state, {:ok, issue.state}}
      else
        write_issue_state(state, issue, state_name)
      end
    else
      nil -> {state, {:error, :issue_not_found}}
      {:error, reason} -> {state, {:error, reason}}
    end
  end

  defp write_issue_state(%State{} = state, %Issue{} = issue, state_name) do
    case Tracker.update_issue_state(issue, state_name) do
      {:ok, %Issue{} = updated_issue} ->
        Logger.info("Moved tracker item to its start state: #{issue_context(issue)} state=#{updated_issue.state}")

        {refresh_tracker_issue(state, updated_issue), {:ok, updated_issue.state}}

      {:error, reason} ->
        Logger.warning("Failed to move tracker item to its start state: #{issue_context(issue)} state=#{state_name} reason=#{inspect(reason)}")

        {state, {:error, reason}}
    end
  end

  # The first configured active state is the one Symphony puts work into when it
  # starts; the rest of the list stays a plain intake fallback.
  defp configured_start_state do
    Config.settings!().tracker.active_states
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> {:error, :missing_start_state}
      state_name -> {:ok, state_name}
    end
  end

  defp refresh_tracker_issue(%State{} = state, %Issue{id: issue_id} = issue) do
    tracker_issues =
      Enum.map(state.tracker_issues, fn
        %Issue{id: ^issue_id} -> issue
        other -> other
      end)

    %{state | tracker_issues: tracker_issues}
  end

  defp poll_now_coalesced?(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)

    state.poll_check_in_progress == true or
      (is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms)
  end

  defp request_poll_now(%State{} = state) do
    if poll_now_coalesced?(state), do: state, else: schedule_tick(state, 0)
  end

  defp choose_issues(issues, state) do
    terminal_states = terminal_state_set()

    issues
    |> Workspace.dispatch_candidates()
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         terminal_states
       ) do
    # Intake is wide, dispatch is not: tracker state got the item onto the
    # board, and only the operator's start takes it off the board and into a
    # Codex run.
    candidate_issue?(issue, terminal_states) and
      DispatchGate.started?(issue.id) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, _reason} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp refresh_issue_for_dispatch(issue) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issues_by_ids/1,
           terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        {:ok, refreshed_issue}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")

        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_activity: [],
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
       when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata)
        {:noreply, release_issue_claim(state, issue_id)}

      # The pause landed while this retry was already on the clock; park the item
      # instead of starting the run the operator just called off.
      DispatchGate.paused?(issue_id) ->
        Logger.info("Retry cancelled for paused issue: #{issue_context(issue)}")

        {:noreply, park_paused_issue(state, issue_id, metadata)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        Workspace.remove_recorded(workspace_path, Map.get(metadata, :worker_host))

      _ ->
        cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
    end
  end

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      case refresh_issue_for_dispatch(issue) do
        {:ok, %Issue{} = refreshed_issue} ->
          {:noreply, do_dispatch_issue(state, refreshed_issue, attempt, metadata[:worker_host])}

        {:skip, :missing} ->
          {:noreply, release_issue_claim(state, issue.id)}

        {:skip, %Issue{} = refreshed_issue} ->
          handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

        {:error, reason} ->
          {:noreply,
           schedule_issue_retry(
             state,
             issue.id,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: "retry dispatch refresh failed: #{inspect(reason)}"
             })
           )}
      end
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  # Feedback normally arrives while the item sits at the approval gate, and
  # dropping the claim is what lets the next poll dispatch it again. An item that
  # is still running keeps its claim: the running agent owns it, and it will pick
  # the feedback up on its next dispatch anyway.
  defp release_for_revision(%State{} = state, issue_id) do
    state =
      if Map.has_key?(state.running, issue_id) do
        Logger.info("Analysis feedback recorded while the agent is running issue_id=#{issue_id}; the next dispatch carries it")

        state
      else
        release_issue_claim(state, issue_id)
      end

    notify_dashboard()

    state
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        continuations: Map.delete(state.continuations, issue_id)
    }
  end

  defp retry_delay(attempt, metadata)
       when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      continuation_retry_delay(metadata[:continuation_streak])
    else
      failure_retry_delay(attempt)
    end
  end

  defp continuation_retry_delay(streak) when is_integer(streak) and streak > 0 do
    max_delay_power = min(streak - 1, 10)

    min(
      @continuation_retry_delay_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  defp continuation_retry_delay(_streak), do: @continuation_retry_delay_ms

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host)
       when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @doc """
  Records operator approval for `issue_id` and releases its approval block so
  the next dispatch runs in the implementation phase.
  """
  @spec approve_analysis(String.t(), keyword()) :: {:ok, map()} | {:error, term()} | :unavailable
  def approve_analysis(issue_id, opts \\ []), do: approve_analysis(__MODULE__, issue_id, opts)

  @spec approve_analysis(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def approve_analysis(server, issue_id, opts) when is_binary(issue_id) do
    if is_pid(server) or Process.whereis(server) do
      GenServer.call(server, {:approve_analysis, issue_id, opts})
    else
      :unavailable
    end
  end

  @doc """
  Moves `issue_id` past whichever gate it is currently parked at.

  Every gate needs one control that means "this is fine, keep going", and which
  decision that is depends only on where the item stopped: start it, approve the
  analysis, approve the post-CI review so the summary phase runs, resume a pause,
  or simply re-dispatch a run that stopped for input. Giving each of those its own
  dashboard button made the operator work out the state machine; this works it out
  for them.
  """
  @spec advance_issue(String.t(), keyword()) :: {:ok, map()} | {:error, term()} | :unavailable
  def advance_issue(issue_id, opts \\ []), do: advance_issue(__MODULE__, issue_id, opts)

  @spec advance_issue(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def advance_issue(server, issue_id, opts) when is_binary(issue_id) do
    if is_pid(server) or Process.whereis(server) do
      GenServer.call(server, {:advance_issue, issue_id, opts})
    else
      :unavailable
    end
  end

  @typedoc "What `advance_issue/3` does for an item parked at a given gate."
  @type advance_decision ::
          :start | :resume | :approve_analysis | :approve_review | :finish | :redispatch

  @doc """
  Returns the decision `advance_issue/3` would take, given where an item stopped.

  Public and pure because the dashboard labels its button with it: a label derived
  separately from the action it triggers is a label that eventually lies about
  what pressing it does.
  """
  @spec advance_decision(DispatchGate.status(), atom() | nil, boolean()) :: advance_decision()
  def advance_decision(:waiting, _block_reason, _review_approved), do: :start
  def advance_decision(:paused, _block_reason, _review_approved), do: :resume

  # A summary phase that delivered nothing has not reached the finish gate, so the
  # button re-runs it instead of offering to close a ticket whose merge-request
  # description was never written.
  def advance_decision(_run_status, :summary_incomplete, _review_approved), do: :redispatch

  # The review gate is reached twice — once for the implementation, once for the
  # summary written after it — and the review approval is what tells them apart.
  def advance_decision(:review, _block_reason, true), do: :finish
  def advance_decision(:review, _block_reason, _review_approved), do: :approve_review

  def advance_decision(:started, :awaiting_analysis_approval, _review_approved),
    do: :approve_analysis

  def advance_decision(_run_status, _block_reason, _review_approved), do: :redispatch

  @doc """
  Records operator feedback on `issue_id` at whichever gate it is parked at, and
  sends it back for another pass of the phase that feedback belongs to.

  This is the counterpart to `advance_issue/3`, and the reason no gate is a
  dead end: an operator who disagrees with what the agent produced can always say
  why instead of only being able to approve it. A rejected analysis re-runs
  analysis; a review that found a problem in the merge request re-runs
  implementation without losing the analysis approval; a summary that reads badly
  re-runs the summary.
  """
  @spec submit_feedback(String.t(), keyword()) :: {:ok, map()} | {:error, term()} | :unavailable
  def submit_feedback(issue_id, opts \\ []), do: submit_feedback(__MODULE__, issue_id, opts)

  @spec submit_feedback(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def submit_feedback(server, issue_id, opts) when is_binary(issue_id) do
    if is_pid(server) or Process.whereis(server) do
      GenServer.call(server, {:submit_feedback, issue_id, opts})
    else
      :unavailable
    end
  end

  @doc """
  Records operator feedback on `issue_id`'s analysis and sends it back for
  another analysis pass.

  This is the counterpart to `approve_analysis/3`: the operator states what is
  wrong instead of accepting the document. Any earlier approval is withdrawn, so
  the item re-runs analysis with the feedback in its prompt rather than moving on
  to implementation.
  """
  @spec request_analysis_revision(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def request_analysis_revision(issue_id, opts \\ []),
    do: request_analysis_revision(__MODULE__, issue_id, opts)

  @spec request_analysis_revision(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def request_analysis_revision(server, issue_id, opts) when is_binary(issue_id) do
    if is_pid(server) or Process.whereis(server) do
      GenServer.call(server, {:request_analysis_revision, issue_id, opts})
    else
      :unavailable
    end
  end

  @doc """
  Releases `issue_id` for dispatch and moves the tracker item into its start
  state.

  Intake only puts a ticket on the board; this is the click that authorizes token
  spend on it. The tracker write is best effort and reported back in the reply —
  the local gate is what actually admits the item to dispatch, so a tracker that
  rejects the write leaves the run authorized rather than swallowing the start.
  """
  @spec start_issue(String.t(), keyword()) :: {:ok, map()} | {:error, term()} | :unavailable
  def start_issue(issue_id, opts \\ []), do: start_issue(__MODULE__, issue_id, opts)

  @spec start_issue(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def start_issue(server, issue_id, opts) when is_binary(issue_id) do
    if is_pid(server) or Process.whereis(server) do
      GenServer.call(server, {:start_issue, issue_id, opts})
    else
      :unavailable
    end
  end

  @doc """
  Pauses `issue_id` locally: stops any run in flight and holds the item in a
  block that only `resume_issue/3` clears.

  This is the operator's answer to a ticket that is going nowhere. Unlike the
  analysis gate, nothing about the item's own progress reopens it — tracker
  activity, a retry timer, and a fresh poll all leave it parked.
  """
  @spec pause_issue(String.t(), keyword()) :: {:ok, map()} | {:error, term()} | :unavailable
  def pause_issue(issue_id, opts \\ []), do: pause_issue(__MODULE__, issue_id, opts)

  @spec pause_issue(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def pause_issue(server, issue_id, opts) when is_binary(issue_id) do
    if is_pid(server) or Process.whereis(server) do
      GenServer.call(server, {:pause_issue, issue_id, opts})
    else
      :unavailable
    end
  end

  @doc """
  Clears the pause on `issue_id` so the next poll dispatches it again.

  The item returns to `started`, not to the queue: it was authorized once already,
  and asking for a second start would make a pause cost more than it should.
  """
  @spec resume_issue(String.t(), keyword()) :: {:ok, map()} | {:error, term()} | :unavailable
  def resume_issue(issue_id, opts \\ []), do: resume_issue(__MODULE__, issue_id, opts)

  @spec resume_issue(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def resume_issue(server, issue_id, opts) when is_binary(issue_id) do
    if is_pid(server) or Process.whereis(server) do
      GenServer.call(server, {:resume_issue, issue_id, opts})
    else
      :unavailable
    end
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          codex_activity: Map.get(metadata, :codex_activity, []),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          block_reason: Map.get(metadata, :block_reason, :input_required),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event),
          codex_activity: Map.get(metadata, :codex_activity, [])
        }
      end)

    tracker =
      %{
        source: Config.settings!().tracker.kind,
        active_states: Config.settings!().tracker.active_states,
        synced_at: state.tracker_synced_at,
        issues: Enum.map(state.tracker_issues, &tracker_issue_snapshot/1)
      }

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       tracker: tracker,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call({:approve_analysis, issue_id, opts}, _from, state) do
    apply_advance(state, issue_id, opts, :approve_analysis)
  end

  def handle_call({:request_analysis_revision, issue_id, opts}, _from, state) do
    record_feedback(state, issue_id, opts, :analysis)
  end

  def handle_call({:submit_feedback, issue_id, opts}, _from, state) do
    record_feedback(state, issue_id, opts, feedback_phase(state, issue_id))
  end

  def handle_call({:advance_issue, issue_id, opts}, _from, state) do
    advance_from_gate(state, issue_id, opts, decision_for(state, issue_id))
  end

  def handle_call({:start_issue, issue_id, opts}, _from, state) do
    apply_advance(state, issue_id, opts, :start)
  end

  def handle_call({:pause_issue, issue_id, opts}, _from, state) do
    case DispatchGate.pause(issue_id, opts) do
      {:ok, record} ->
        state = park_paused_issue(state, issue_id)
        notify_dashboard()

        {:reply, {:ok, record}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume_issue, issue_id, opts}, _from, state) do
    apply_advance(state, issue_id, opts, :resume)
  end

  def handle_call(:request_refresh, _from, state) do
    coalesced = poll_now_coalesced?(state)
    state = request_poll_now(state)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp decision_for(%State{} = state, issue_id) do
    advance_decision(
      DispatchGate.status(issue_id),
      blocked_reason(state, issue_id),
      ApprovalStore.review_approved?(issue_id)
    )
  end

  defp advance_from_gate(%State{} = state, issue_id, opts, decision) do
    {:reply, reply, state} = apply_advance(state, issue_id, opts, decision)
    {:reply, tag_decision(reply, decision), state}
  end

  defp tag_decision({:ok, record}, decision) when is_map(record),
    do: {:ok, Map.put(record, :decision, decision)}

  defp tag_decision(reply, _decision), do: reply

  defp apply_advance(%State{} = state, issue_id, opts, :start) do
    case DispatchGate.start(issue_id, opts) do
      {:ok, record} ->
        {state, tracker_state} = move_started_issue_to_start_state(state, issue_id)

        Logger.info("Dispatch released by operator: issue_id=#{issue_id} issue_identifier=#{record.identifier} tracker_state=#{inspect(tracker_state)}")

        # The operator is watching, so the run should begin now rather than at the
        # end of the current poll interval.
        state = request_poll_now(state)
        notify_dashboard()

        {:reply, {:ok, Map.put(record, :tracker_state, tracker_state)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_advance(%State{} = state, issue_id, opts, :resume) do
    case DispatchGate.resume(issue_id, opts) do
      {:ok, record} ->
        Logger.info("Released operator pause issue_id=#{issue_id}; the next poll dispatches it again")

        # Dropping the claim, and with it the paused block, is what lets the next
        # poll pick the item up.
        state = state |> release_issue_claim(issue_id) |> request_poll_now()
        notify_dashboard()

        {:reply, {:ok, record}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_advance(%State{} = state, issue_id, opts, :approve_analysis) do
    case ApprovalStore.approve(issue_id, opts) do
      {:ok, record} ->
        Logger.info("Releasing approval block issue_id=#{issue_id}; next dispatch runs in implementation phase")

        # Dropping the claim lets the next poll pick the item up again, this
        # time with the approval on record.
        state = release_issue_claim(state, issue_id)
        notify_dashboard()

        {:reply, {:ok, record}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_advance(%State{} = state, issue_id, opts, :approve_review) do
    case ApprovalStore.approve_review(issue_id, opts) do
      {:ok, record} ->
        # The handoff left the item at the review gate, which blocks dispatch;
        # returning it to `:started` is what lets the summary run happen.
        _ = DispatchGate.resume(issue_id, opts)

        Logger.info("Review approved by operator issue_id=#{issue_id}; next dispatch writes the merge-request summary")

        state = state |> release_issue_claim(issue_id) |> request_poll_now()
        notify_dashboard()

        {:reply, {:ok, record}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Nothing is left for Symphony once the summary exists: merging and closing the
  # ticket are the operator's, so finishing parks the item exactly as a pause
  # does, and the same resume brings it back if they change their mind.
  defp apply_advance(%State{} = state, issue_id, opts, :finish) do
    case DispatchGate.pause(issue_id, opts) do
      {:ok, record} ->
        Logger.info("Ticket finished by operator issue_id=#{issue_id}; no further dispatch until it is resumed")

        state = park_paused_issue(state, issue_id)
        notify_dashboard()

        {:reply, {:ok, record}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_advance(%State{} = state, issue_id, opts, :redispatch) do
    # An item held at the review gate is not dispatchable while the hold stands, so
    # releasing one has to lift it too — otherwise the button reports a redispatch
    # that the next poll quietly refuses. This is the summary phase that delivered
    # nothing: the operator is asking for another attempt at it.
    if DispatchGate.review?(issue_id) do
      _ = DispatchGate.resume(issue_id, opts)
    end

    Logger.info("Operator released a blocked issue_id=#{issue_id}; the next poll dispatches it again")

    state = state |> release_issue_claim(issue_id) |> request_poll_now()
    notify_dashboard()

    {:reply, {:ok, %{issue_id: issue_id}}, state}
  end

  # One feedback channel serves every gate, so the phase decides what the note
  # invalidates. Analysis feedback withdraws the approval that would otherwise
  # send the item straight to implementation; review and summary feedback leave it
  # in place, because the operator is correcting code or prose, not the plan.
  defp record_feedback(%State{} = state, issue_id, opts, phase) do
    case OperatorFeedback.add(issue_id, Keyword.get(opts, :note), Keyword.put(opts, :phase, phase)) do
      {:ok, note} ->
        if phase == :analysis do
          _ = ApprovalStore.revoke(issue_id)
        end

        # An item parked at the review gate stays there until something releases
        # it, and feedback is that release: it goes back to running the phase the
        # note was written against.
        if DispatchGate.review?(issue_id) do
          _ = DispatchGate.resume(issue_id, opts)
        end

        Logger.info("Recorded operator feedback issue_id=#{issue_id} identifier=#{inspect(note.identifier)} phase=#{phase}; next dispatch re-runs #{phase}")

        state = state |> release_for_revision(issue_id) |> request_poll_now()

        {:reply, {:ok, note}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Feedback belongs to the phase it is criticizing, which is the phase that is
  # about to re-run — not necessarily the one that produced the parked state.
  defp feedback_phase(%State{} = state, issue_id) do
    cond do
      blocked_reason(state, issue_id) in [:awaiting_analysis_approval, :analysis_incomplete] ->
        :analysis

      DispatchGate.review?(issue_id) and ApprovalStore.review_approved?(issue_id) ->
        :summary

      true ->
        AgentRunner.phase_for(%{id: issue_id})
    end
  end

  defp blocked_reason(%State{} = state, issue_id) do
    case Map.get(state.blocked, issue_id) do
      %{block_reason: reason} -> reason
      _ -> nil
    end
  end

  @doc false
  @spec feedback_phase_for_test(term(), String.t()) :: atom()
  def feedback_phase_for_test(%State{} = state, issue_id), do: feedback_phase(state, issue_id)

  defp tracker_issue_snapshot(%Issue{} = issue) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      issue_url: issue.url,
      priority: issue.priority,
      labels: issue.labels,
      assignee_id: issue.assignee_id,
      updated_at: issue.updated_at
    }
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        codex_activity: record_codex_activity(running_entry, update)
      }),
      token_delta
    }
  end

  # The single `last_codex_message` slot is overwritten by whatever arrived most
  # recently, which is usually rate-limit or token bookkeeping. The activity log
  # keeps the substantive events so an operator can see what the agent did.
  defp record_codex_activity(running_entry, update) do
    activity = Map.get(running_entry, :codex_activity, [])
    summarized = summarize_codex_update(update)

    if codex_activity_noise?(summarized) do
      activity
    else
      entry = %{
        at: update[:timestamp],
        event: update[:event],
        message: StatusDashboard.humanize_codex_message(summarized)
      }

      case activity do
        [%{message: previous} | _rest] when previous == entry.message -> activity
        _ -> Enum.take([entry | activity], @codex_activity_limit)
      end
    end
  end

  defp codex_activity_noise?(summarized) do
    case codex_message_method(summarized) do
      method when is_binary(method) ->
        method in @codex_activity_noise_methods or String.ends_with?(method, "Delta") or
          String.ends_with?(method, "/delta")

      _ ->
        false
    end
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
