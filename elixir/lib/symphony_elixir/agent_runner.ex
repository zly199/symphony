defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.{
    ApprovalStore,
    Config,
    DispatchGate,
    OperatorFeedback,
    PromptBuilder,
    ResumeState,
    Tracker,
    Workspace
  }

  # Analysis is a bounded deliverable, so it gets far fewer turns than
  # implementation. The cap also stops an unapproved ticket from spending a full
  # run's budget before it reaches the operator.
  @analysis_max_turns 3
  # The summary phase reads a finished branch and writes a merge-request
  # description. Nothing about it should take a long run, and a cap keeps a
  # confused agent from re-opening implementation work under a summary prompt.
  @summary_max_turns 3
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    phase = phase_for(issue)
    configured_max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    max_turns = phase_max_turns(phase, configured_max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    opts =
      opts
      |> put_resume_state(workspace, issue)
      |> put_review_feedback(issue)
      |> Keyword.put(:phase, phase)

    Logger.info("Running #{issue_context(issue)} in #{phase} phase with max_turns=#{max_turns}")

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      # The feedback is already in this run's opening prompt, so the session
      # starting is the point where it counts as answered by a run.
      mark_review_feedback_delivered(issue)

      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  @doc """
  Returns the phase a work item runs in, which is decided entirely by the operator
  gates it has passed: `:analysis` until the analysis is approved,
  `:implementation` until the post-CI review is approved, `:summary` afterwards.
  """
  @spec phase_for(Issue.t() | map()) :: :analysis | :implementation | :summary
  def phase_for(%{id: issue_id}) do
    cond do
      not ApprovalStore.approved?(issue_id) -> :analysis
      ApprovalStore.review_approved?(issue_id) -> :summary
      true -> :implementation
    end
  end

  def phase_for(_issue), do: :analysis

  defp phase_max_turns(:analysis, configured), do: min(configured, @analysis_max_turns)
  defp phase_max_turns(:summary, configured), do: min(configured, @summary_max_turns)
  defp phase_max_turns(_phase, configured), do: configured

  # A restarted orchestrator dispatches turn 1 again with no memory of prior
  # runs, so the opening prompt carries the workspace's own account of what is
  # already done.
  defp put_resume_state(opts, workspace, issue) do
    resume = ResumeState.inspect_workspace(workspace, issue)

    if resume.started do
      Logger.info(
        "Resuming existing work for #{issue_context(issue)} branch=#{resume.branch} commits_ahead=#{resume.commits_ahead} dirty_files=#{resume.dirty_files} remote_synced=#{resume.remote_synced}"
      )
    end

    Keyword.put(opts, :resume, resume)
  end

  # An operator who sent work back wrote down what is wrong with it, and that
  # text is the highest-priority input for the next run, so it travels in the
  # opening prompt rather than waiting for a human to repeat it.
  defp put_review_feedback(opts, %{id: issue_id}) when is_binary(issue_id) do
    notes = OperatorFeedback.notes(issue_id)
    pending = Enum.count(notes, &is_nil(&1.delivered_at))

    if notes != [] do
      Logger.info("Carrying operator feedback into prompt issue_id=#{issue_id} notes=#{length(notes)} pending=#{pending}")
    end

    Keyword.put(opts, :feedback, notes)
  end

  defp put_review_feedback(opts, _issue), do: Keyword.put(opts, :feedback, [])

  defp mark_review_feedback_delivered(%{id: issue_id}) when is_binary(issue_id) do
    OperatorFeedback.mark_delivered(issue_id)
  end

  defp mark_review_feedback_delivered(_issue), do: :ok

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    if DispatchGate.review?(issue_id) do
      {:done, issue}
    else
      continue_with_refreshed_issue(issue, issue_state_fetcher.([issue_id]))
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp continue_with_refreshed_issue(_issue, {:ok, [%Issue{} = refreshed_issue | _]}) do
    if open_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
      {:continue, refreshed_issue}
    else
      {:done, refreshed_issue}
    end
  end

  defp continue_with_refreshed_issue(issue, {:ok, []}), do: {:done, issue}

  defp continue_with_refreshed_issue(_issue, {:error, reason}),
    do: {:error, {:issue_state_refresh_failed, reason}}

  # Turns keep coming until the ticket is finished. Which open column it sits in
  # is not the runner's business: the operator's start released this work, and only
  # a terminal state or the dashboard takes it back.
  defp open_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.terminal_states
    |> Enum.all?(fn terminal_state -> normalize_issue_state(terminal_state) != normalized_state end)
  end

  defp open_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
