defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.ApprovalStore
  alias SymphonyElixir.Artifact
  alias SymphonyElixir.OperatorFeedback
  alias SymphonyElixir.DispatchGate
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(issue_ids) do
      send(self(), {:fetch_issues_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Second prompt",
      poll_interval_ms: 45_000
    )

    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    good_settings = Config.settings!()
    assert good_settings.polling.interval_ms == 45_000

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    File.write!(
      Workflow.workflow_file_path(),
      "---\npolling:\n  interval_ms: nope\n---\nTyped-invalid prompt\n"
    )

    assert {:error, {:invalid_workflow_config, message}} = WorkflowStore.force_reload()
    assert message =~ "polling.interval_ms"
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil,
      prompt: "Semantic-invalid prompt"
    )

    assert {:error, :missing_linear_project_slug} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, :missing_linear_project_slug} = Config.validate!()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert {:ok, settings} = WorkflowStore.settings()
    assert settings.polling.interval_ms == 30_000
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.settings()

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    assert :ok = GenServer.stop(manual_pid)

    Workflow.set_workflow_file_path(existing_path)

    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    assert :ok = WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_ids(["issue-1"])

    binding = SymphonyElixir.Tracker.bind_agent_tools()
    assert binding.adapter == Memory
    assert binding.tool_specs == []
    assert binding.secret_environment_names == []

    assert SymphonyElixir.Tracker.execute_bound_agent_tool(binding, "not_a_memory_tool", %{})[
             "success"
           ] == false

    assert {:error, {:unsupported_tracker_kind, "future-tracker"}} =
             SymphonyElixir.Tracker.adapter_for_kind("future-tracker")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
    assert SymphonyElixir.Tracker.bind_agent_tools().secret_environment_names == ["LINEAR_API_KEY"]
  end

  test "intake asks the adapter for open work and says so when a state write is unsupported" do
    open_issue = %Issue{id: "issue-open", identifier: "MT-OPEN", state: "Open"}
    closed_issue = %Issue{id: "issue-closed", identifier: "MT-CLOSED", state: "Closed"}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [open_issue, closed_issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Closed"]
    )

    # Intake is not the active-state list: an "Open" ticket enters, a closed one
    # does not, without either name appearing in `active_states`.
    assert {:ok, [^open_issue]} = SymphonyElixir.Tracker.fetch_intake_issues()

    assert {:ok, %Issue{state: "In Progress"}} =
             SymphonyElixir.Tracker.update_issue_state(open_issue, "In Progress")

    assert {:ok, [%Issue{state: "In Progress"}, %Issue{state: "Closed"}]} =
             SymphonyElixir.Tracker.fetch_issues_by_ids(["issue-open", "issue-closed"])

    # A tracker with no native open-issue read falls back to the configured states,
    # and one with no state write says which tracker refused instead of pretending.
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert {:ok, ["Todo", "In Progress"]} = SymphonyElixir.Tracker.fetch_intake_issues()
    assert_receive {:fetch_issues_by_states_called, ["Todo", "In Progress"]}

    assert {:error, {:unsupported_tracker_state_write, "linear"}} =
             SymphonyElixir.Tracker.update_issue_state(open_issue, "In Progress")
  end

  test "linear adapter delegates reads and advertises its native agent tool" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issues_by_ids(["issue-1"])
    assert_receive {:fetch_issues_by_ids_called, ["issue-1"]}

    assert [%{"name" => "linear_graphql"}] = Adapter.agent_tool_specs()
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{
               "tracker_active" => 1,
               "running" => 1,
               "retrying" => 1,
               "blocked" => 1,
               "waiting" => 1,
               "paused" => 0
             },
             "tracker" => %{
               "source" => "backlog",
               "active_states" => ["In Progress"],
               "synced_at" => state_payload["tracker"]["synced_at"],
               "issues" => [
                 %{
                   "issue_id" => "issue-tracked",
                   "issue_identifier" => "MT-TRACKED",
                   "title" => "Backlog tracked issue",
                   "state" => "In Progress",
                   "issue_url" => "https://example.org/issues/MT-TRACKED",
                   "priority" => 3,
                   "labels" => ["backend"],
                   "assignee_id" => "user-1",
                   "updated_at" =>
                     state_payload["tracker"]["issues"]
                     |> List.first()
                     |> Map.fetch!("updated_at"),
                   "run_status" => "waiting",
                   "review_approved" => false,
                   "block_reason" => nil,
                   "runtime_status" => "waiting"
                 }
               ]
             },
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "issue_url" => "https://example.org/issues/MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "recent_events" => [
                   %{"at" => nil, "event" => "notification", "message" => "rendered"}
                 ],
                 "artifacts" => [],
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "issue_url" => "https://example.org/issues/MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "issue_url" => "https://example.org/issues/MT-BLOCKED",
                 "state" => "In Progress",
                 "error" => "codex turn requires operator input",
                 "block_reason" => "input_required",
                 "run_status" => "waiting",
                 "review_approved" => false,
                 "gate_phase" => "analysis",
                 "artifact" => nil,
                 "artifacts" => [],
                 "feedback" => [],
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "session_id" => "thread-blocked",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "recent_events" => [
                   %{
                     "at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at"),
                     "event" => "turn_input_required",
                     "message" => "turn blocked: waiting for user input"
                   }
                 ],
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [
               %{"at" => nil, "event" => "notification", "message" => "rendered"}
             ],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "codex turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "error" => "codex turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~s(<html lang="zh-CN">)
    assert html =~ "<title>Symphony 可观测性</title>"
    assert html =~ ~r|/dashboard\.css\?v=[0-9a-f]{12}|

    assert html =~
             ~r|<link rel="icon" type="image/png" sizes="128x128" href="/favicon\.png\?v=[0-9a-f]{12}">|

    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "text-decoration-thickness: 1px"

    favicon_conn = get(build_conn(), "/favicon.png")
    assert response(favicon_conn, 200) == File.read!("priv/static/favicon.png")
    assert Plug.Conn.get_resp_header(favicon_conn, "content-type") == ["image/png; charset=utf-8"]

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "运行监控台"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-TRACKED"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ ~s(href="https://example.org/issues/MT-HTTP")
    assert html =~ ~s(href="https://example.org/issues/MT-RETRY")
    assert html =~ ~s(href="https://example.org/issues/MT-BLOCKED")
    assert html =~ ~s(aria-label="在问题跟踪系统中打开 MT-HTTP")
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "运行时长"
    assert html =~ "实时"
    assert html =~ "离线"
    assert html =~ "复制 ID"
    assert html =~ "Codex 动态"
    assert html =~ "速率限制"
    assert html =~ "重试队列"
    assert html =~ "Backlog 待处理票"
    assert html =~ "Backlog tracked issue"
    assert html =~ "等待调度"
    assert html =~ "开始调度"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "javascript:alert('nope')",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)

    refute render(view) =~ "javascript:alert"
  end

  test "dashboard liveview offers both answers at the analysis gate" do
    orchestrator_name = Module.concat(__MODULE__, :AnalysisGateDashboardOrchestrator)
    snapshot = static_snapshot()

    gated_snapshot =
      put_in(snapshot.blocked, [
        snapshot.blocked
        |> List.first()
        |> Map.merge(%{
          error: "analysis complete; waiting for operator approval before implementation",
          block_reason: :awaiting_analysis_approval
        })
      ])

    # An item only reaches this gate by having been started, and the gate status
    # is what tells the dashboard the pending decision is an approval.
    {:ok, _record} = DispatchGate.start("issue-blocked", identifier: "MT-BLOCKED")

    {:ok, _pid} =
      StaticOrchestrator.start_link(name: orchestrator_name, snapshot: gated_snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "批准继续"
    assert html =~ "提交意见并重跑"
    assert html =~ ~s(name="note")

    html = submit_revision(view, "第 3 节缺少数据流")

    assert html =~ "已记录 MT-BLOCKED 的修改意见"

    assert [%{note: "第 3 节缺少数据流", identifier: "MT-BLOCKED", phase: "analysis"}] =
             OperatorFeedback.notes("issue-blocked")

    assert submit_revision(view, "   ") =~ "请先填写需要修改的内容"
    assert length(OperatorFeedback.notes("issue-blocked")) == 1
  end

  test "dashboard liveview offers both answers at the review and summary gates" do
    orchestrator_name = Module.concat(__MODULE__, :ReviewGateDashboardOrchestrator)
    snapshot = static_snapshot()
    on_exit(fn -> Artifact.clear("issue-blocked") end)

    review_snapshot =
      put_in(snapshot.blocked, [
        snapshot.blocked
        |> List.first()
        |> Map.merge(%{
          error: "implementation gates passed; waiting for operator review",
          block_reason: :awaiting_human_review
        })
      ])

    {:ok, _record} = DispatchGate.handoff_for_review("issue-blocked", identifier: "MT-BLOCKED")
    {:ok, _approval} = ApprovalStore.approve("issue-blocked", identifier: "MT-BLOCKED")

    {:ok, _pid} =
      StaticOrchestrator.start_link(name: orchestrator_name, snapshot: review_snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    # Before the review is signed off, continuing means "write the summary" and
    # feedback means "go back and change the code".
    assert html =~ "Review 通过，生成 MR 总结"
    assert html =~ "回到编码阶段"

    # The gate has to show what it is asking about. Nothing was published, so it
    # says so rather than presenting a bare approve button.
    assert html =~ "这一轮没有产出可确认的产物"

    {:ok, _artifact} =
      Artifact.put("issue-blocked", :implementation, %{
        identifier: "MT-BLOCKED",
        title: "MT-BLOCKED 实现与 CI",
        format: "markdown",
        body: "## 变更\npipeline 123 succeeded"
      })

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "MT-BLOCKED 实现与 CI"
    assert html =~ "/artifacts/issue-blocked/implementation"
    assert html =~ "点开查看这一关的产物"
    refute html =~ "这一轮没有产出可确认的产物"

    assert submit_revision(view, "空指针分支没覆盖") =~ "会回到编码阶段修改并重跑 CI"

    assert [%{phase: "implementation"}] = OperatorFeedback.notes("issue-blocked")
    # Review feedback corrects code, so the analysis approval survives it.
    assert ApprovalStore.approved?("issue-blocked")
    assert DispatchGate.started?("issue-blocked")

    # After the sign-off the same two controls mean "regenerate the summary" and
    # "this ticket is done".
    {:ok, _approval} = ApprovalStore.approve_review("issue-blocked", identifier: "MT-BLOCKED")
    {:ok, _record} = DispatchGate.handoff_for_review("issue-blocked", identifier: "MT-BLOCKED")

    {:ok, _artifact} =
      Artifact.put("issue-blocked", :summary, %{
        identifier: "MT-BLOCKED",
        title: "MT-BLOCKED MR 总结",
        format: "markdown",
        body: "## 1. 设计思想\n1. 改了 FooService"
      })

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "确认完成"
    assert html =~ "重新生成总结"

    # The gate moved on, so the artifact it shows moves with it — and the earlier
    # phase stays reachable from the row.
    assert html =~ "MT-BLOCKED MR 总结"
    assert html =~ "/artifacts/issue-blocked/summary"
    assert html =~ "/artifacts/issue-blocked/implementation"

    assert submit_revision(view, "第一段太长，压到三句") =~ "会重新生成 MR 总结"
    assert [%{phase: "implementation"}, %{phase: "summary"}] = OperatorFeedback.notes("issue-blocked")
    assert ApprovalStore.review_approved?("issue-blocked")
  end

  test "dashboard liveview walks a ticket from waiting through started and paused" do
    orchestrator_name = Module.concat(__MODULE__, :GateDashboardOrchestrator)
    snapshot = static_snapshot()

    # Park the ticket at the analysis gate: this is where an operator decides the
    # thing is going nowhere, so it is where pausing has to work.
    gated_snapshot =
      put_in(snapshot.blocked, [
        snapshot.blocked
        |> List.first()
        |> Map.put(:block_reason, :awaiting_analysis_approval)
      ])

    {:ok, _pid} =
      StaticOrchestrator.start_link(name: orchestrator_name, snapshot: gated_snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    # Whatever the state, the row offers both a way forward and a way to say what
    # is wrong; only the label on the forward button changes.
    assert has_element?(view, "form.revision-form")
    assert has_element?(view, gate_button("advance_issue", "issue-tracked"))
    assert has_element?(view, gate_button("advance_issue", "issue-blocked"))

    # Nothing has been released yet, so no row offers a way to stop something that
    # is not running.
    refute has_element?(view, gate_button("pause_issue", "issue-blocked"))
    assert render(view) =~ "开始调度"

    html = click_advance(view)

    assert html =~ "已开始调度 MT-BLOCKED"
    assert DispatchGate.started?("issue-blocked")
    assert has_element?(view, gate_button("pause_issue", "issue-blocked"))
    assert render(view) =~ "批准继续"

    html = view |> element(gate_button("pause_issue", "issue-blocked")) |> render_click()

    assert html =~ "已暂停 MT-BLOCKED"
    assert DispatchGate.paused?("issue-blocked")
    refute has_element?(view, gate_button("pause_issue", "issue-blocked"))
    assert render(view) =~ "恢复推进"

    # A paused ticket still takes feedback: the operator's note is what the run
    # picks up when they resume it.
    assert has_element?(view, "form.revision-form")

    html = click_advance(view)

    assert html =~ "已恢复 MT-BLOCKED"
    assert DispatchGate.started?("issue-blocked")
    assert has_element?(view, gate_button("pause_issue", "issue-blocked"))
  end

  defp gate_button(event, issue_id) do
    "button[phx-click=#{event}][phx-value-issue-id=#{issue_id}]"
  end

  defp click_advance(view) do
    view
    |> element(gate_button("advance_issue", "issue-blocked"))
    |> render_click()
  end

  defp submit_revision(view, note) do
    view
    |> element("form.revision-form")
    |> render_submit(%{"issue-id" => "issue-blocked", "identifier" => "MT-BLOCKED", "note" => note})
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "无法获取状态快照"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200

    assert response.body["counts"] == %{
             "tracker_active" => 1,
             "running" => 1,
             "retrying" => 1,
             "blocked" => 1,
             "waiting" => 1,
             "paused" => 0
           }

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      tracker: %{
        source: "backlog",
        active_states: ["In Progress"],
        synced_at: DateTime.utc_now(),
        issues: [
          %{
            issue_id: "issue-tracked",
            identifier: "MT-TRACKED",
            title: "Backlog tracked issue",
            state: "In Progress",
            issue_url: "https://example.org/issues/MT-TRACKED",
            priority: 3,
            labels: ["backend"],
            assignee_id: "user-1",
            updated_at: DateTime.utc_now()
          }
        ]
      },
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          issue_url: "https://example.org/issues/MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          issue_url: "https://example.org/issues/MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_codex_timestamp: DateTime.utc_now()
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  describe "artifact route" do
    setup do
      start_test_endpoint([])
      on_exit(fn -> Artifact.clear("issue-artifact") end)
      :ok
    end

    test "serves an html artifact as authored" do
      {:ok, _artifact} =
        Artifact.put("issue-artifact", :analysis, %{
          identifier: "MT-DOC",
          title: "MT-DOC 系分",
          format: "html",
          body: "<h1>系分 MT-DOC</h1>"
        })

      conn = get(build_conn(), "/artifacts/issue-artifact/analysis")

      assert response(conn, 200) == "<h1>系分 MT-DOC</h1>"
      assert response_content_type(conn, :html) =~ "text/html"
    end

    test "wraps a markdown artifact in a readable page and escapes its body" do
      {:ok, _artifact} =
        Artifact.put("issue-artifact", :implementation, %{
          identifier: "MT-DOC",
          title: "MT-DOC 实现与 CI",
          format: "markdown",
          body: "## 变更\n<script>alert(1)</script>"
        })

      body = response(get(build_conn(), "/artifacts/issue-artifact/implementation"), 200)

      assert body =~ "MT-DOC 实现与 CI"
      assert body =~ "## 变更"
      # The body is the agent's prose, not markup to execute.
      assert body =~ "&lt;script&gt;"
      refute body =~ "<script>alert(1)</script>"
    end

    test "returns 404 for an unpublished phase and an unknown phase name" do
      assert response(get(build_conn(), "/artifacts/issue-artifact/summary"), 404)
      assert response(get(build_conn(), "/artifacts/issue-artifact/nonsense"), 404)
    end

    # Ids come from the tracker, so a crafted one must not reach outside the
    # artifacts directory.
    test "a traversing issue id cannot read another file" do
      assert response(get(build_conn(), "/artifacts/..%2F..%2Fapprovals/analysis"), 404)
    end
  end
end
