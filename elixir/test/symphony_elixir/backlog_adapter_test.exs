defmodule SymphonyElixir.Backlog.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Backlog.Adapter, as: BacklogAdapter
  alias SymphonyElixir.Backlog.AgentTool, as: BacklogAgentTool
  alias SymphonyElixir.Backlog.Client, as: BacklogClient
  alias SymphonyElixir.{Config, Tracker, Workflow}

  defmodule FakeBacklogClient do
    def fetch_issues_by_states(states) do
      send(self(), {:backlog_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:backlog_ids_called, ids})
      {:ok, ids}
    end

    def fetch_open_issues(terminal_states) do
      send(self(), {:backlog_open_called, terminal_states})
      {:ok, terminal_states}
    end

    def update_issue_state(issue, state_name) do
      send(self(), {:backlog_state_write_called, issue.identifier, state_name})
      {:ok, %{issue | state: state_name}}
    end
  end

  setup do
    backlog_client_module = Application.get_env(:symphony_elixir, :backlog_client_module)

    on_exit(fn ->
      if is_nil(backlog_client_module) do
        Application.delete_env(:symphony_elixir, :backlog_client_module)
      else
        Application.put_env(:symphony_elixir, :backlog_client_module, backlog_client_module)
      end
    end)

    :ok
  end

  test "adapter validates Backlog config, delegates reads, and advertises backlog_api" do
    settings = tracker_settings()

    assert :ok = BacklogAdapter.validate_config(settings)
    assert :ok = BacklogAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :missing_backlog_active_states} =
             BacklogAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_backlog_terminal_states} =
             BacklogAdapter.validate_config(%{settings | terminal_states: nil})

    assert {:error, :invalid_backlog_states} =
             BacklogAdapter.validate_config(%{settings | active_states: [" "]})

    assert {:error, :invalid_backlog_states} =
             BacklogAdapter.validate_config(%{settings | terminal_states: [42]})

    Application.put_env(:symphony_elixir, :backlog_client_module, FakeBacklogClient)

    assert {:ok, ["Open"]} = BacklogAdapter.fetch_issues_by_states(["Open"])
    assert_receive {:backlog_states_called, ["Open"]}

    assert {:ok, ["42"]} = BacklogAdapter.fetch_issues_by_ids(["42"])
    assert_receive {:backlog_ids_called, ["42"]}

    assert {:ok, ["Closed"]} = BacklogAdapter.fetch_open_issues(["Closed"])
    assert_receive {:backlog_open_called, ["Closed"]}

    assert {:ok, %{state: "In Progress"}} =
             BacklogAdapter.update_issue_state(
               %SymphonyElixir.Tracker.Issue{id: "42", identifier: "TEST-42", state: "Open"},
               "In Progress"
             )

    assert_receive {:backlog_state_write_called, "TEST-42", "In Progress"}

    assert [%{"name" => "backlog_api"}] = BacklogAdapter.agent_tool_specs()

    assert BacklogAdapter.execute_agent_tool(
             "backlog_api",
             %{"method" => "GET", "path" => "/users/myself"},
             backlog_client: fn _method, _path, _query, _form, _opts ->
               {:ok, %{status: 200, body: %{"id" => 99}}}
             end
           )["success"]
  end

  test "client validates provider settings and declares token environments" do
    assert :ok = BacklogClient.validate_settings(tracker_settings())

    assert :ok =
             BacklogClient.validate_settings(tracker_settings(%{"base_url" => "https://space.backlog.com/api/v2/"}))

    assert {:error, :invalid_backlog_base_url} =
             BacklogClient.validate_settings(tracker_settings(%{"base_url" => "http://space.backlog.com"}))

    assert {:error, :invalid_backlog_base_url} =
             BacklogClient.validate_settings(tracker_settings(%{"base_url" => "https://space.backlog.com/custom"}))

    assert {:error, :missing_backlog_api_key} =
             BacklogClient.validate_settings(tracker_settings(%{"api_key" => 123}))

    assert {:error, :missing_backlog_project_key} =
             BacklogClient.validate_settings(tracker_settings(%{"project_key" => 123}))

    assert {:error, :invalid_backlog_project_key} =
             BacklogClient.validate_settings(tracker_settings(%{"project_key" => "bad key"}))

    assert {:error, :invalid_backlog_assignee_id} =
             BacklogClient.validate_settings(tracker_settings(%{"assignee_id" => "unknown"}))

    assert :ok =
             BacklogClient.validate_settings(tracker_settings(%{"assignee_id" => 99}))

    assert BacklogClient.secret_environment_names(tracker_settings(%{"api_key" => "$SYMPHONY_BACKLOG_TOKEN"})) == ["BACKLOG_API_KEY", "SYMPHONY_BACKLOG_TOKEN"]
  end

  test "client normalizes Backlog issues and maps categories to labels" do
    issue = BacklogClient.normalize_issue_for_test(raw_issue(42), tracker_settings())

    assert issue.id == "42"
    assert issue.identifier == "TEST-42"

    assert issue.native_ref == %{
             "id" => 42,
             "issue_key" => "TEST-42",
             "key_id" => 42,
             "project_id" => 7,
             "issue_type_id" => 11,
             "status_id" => 1
           }

    assert issue.title == "Issue 42"
    assert issue.description == "Body 42"
    assert issue.priority == 3
    assert issue.state == "Open"
    assert issue.url == "https://space.backlog.com/view/TEST-42"
    assert issue.assignee_id == "99"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    refute BacklogClient.normalize_issue_for_test(
             raw_issue(43),
             tracker_settings(%{"assignee_id" => "100"})
           ).dispatchable

    assert BacklogClient.normalize_issue_for_test(
             raw_issue(44) |> Map.put("issueKey", "OTHER-44"),
             tracker_settings()
           ) == nil

    assert BacklogClient.normalize_issue_for_test(
             raw_issue(45) |> Map.put("summary", " "),
             tracker_settings()
           ) == nil
  end

  test "client resolves status names and pages project-scoped issue reads" do
    first_page =
      Enum.map(1..98, &raw_issue/1) ++
        [
          raw_issue(99) |> put_in(["status", "name"], "Closed"),
          raw_issue(100) |> Map.put("summary", "")
        ]

    request_fun = fn
      "GET", "/projects/TEST", %{}, nil, settings ->
        send(self(), {:backlog_project, settings})
        {:ok, %{status: 200, body: %{"id" => 7, "projectKey" => "TEST"}}}

      "GET", "/projects/TEST/statuses", %{}, nil, settings ->
        send(self(), {:backlog_statuses, settings})

        {:ok,
         %{
           status: 200,
           body: [
             %{"id" => 1, "name" => "Open"},
             %{"id" => 2, "name" => "In Progress"},
             %{"id" => 4, "name" => "Closed"}
           ]
         }}

      "GET", "/issues", query, nil, settings ->
        send(self(), {:backlog_page, query, settings})

        body =
          case query["offset"] do
            0 -> first_page
            100 -> [raw_issue(101)]
          end

        {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 BacklogClient.fetch_issues_by_states_for_test(
                   [" OPEN "],
                   tracker_settings(%{"assignee_id" => "99"}),
                   request_fun
                 )

        assert length(issues) == 99
        assert hd(issues).id == "1"
        assert List.last(issues).id == "101"
        refute Enum.any?(issues, &(&1.id == "99"))
      end)

    assert log =~ "Dropping malformed Backlog issue records count=1"
    assert_receive {:backlog_project, %{project_key: "TEST", assignee_id: 99}}
    assert_receive {:backlog_statuses, %{project_key: "TEST"}}

    assert_receive {:backlog_page,
                    %{
                      "projectId[]" => 7,
                      "statusId[]" => [1],
                      "assigneeId[]" => 99,
                      "count" => 100,
                      "offset" => 0,
                      "sort" => "created",
                      "order" => "asc"
                    }, %{api_key: "test-token"}}

    assert_receive {:backlog_page, %{"offset" => 100}, %{project_key: "TEST"}}
  end

  test "client reads every non-terminal Backlog status for intake" do
    request_fun = fn
      "GET", "/projects/TEST", %{}, nil, _settings ->
        {:ok, %{status: 200, body: %{"id" => 7, "projectKey" => "TEST"}}}

      "GET", "/projects/TEST/statuses", %{}, nil, _settings ->
        {:ok,
         %{
           status: 200,
           body: [
             %{"id" => 1, "name" => "Open"},
             %{"id" => 2, "name" => "In Progress"},
             %{"id" => 3, "name" => "Resolved"},
             %{"id" => 4, "name" => "Closed"}
           ]
         }}

      "GET", "/issues", query, nil, _settings ->
        send(self(), {:backlog_open_page, query})

        {:ok,
         %{
           status: 200,
           body: [raw_issue(1), raw_issue(2) |> put_in(["status", "name"], "In Progress")]
         }}
    end

    assert {:ok, issues} =
             BacklogClient.fetch_open_issues_for_test(
               ["Resolved", "Closed"],
               tracker_settings(),
               request_fun
             )

    # Intake covers the whole open board, so a ticket nobody has moved into an
    # active column still shows up for the operator to start.
    assert Enum.map(issues, & &1.state) == ["Open", "In Progress"]
    assert_receive {:backlog_open_page, %{"statusId[]" => [1, 2]}}
  end

  test "client moves a Backlog issue into the requested status" do
    issue = BacklogClient.normalize_issue_for_test(raw_issue(42), tracker_settings())

    request_fun = fn
      "GET", "/projects/TEST/statuses", %{}, nil, _settings ->
        {:ok,
         %{
           status: 200,
           body: [%{"id" => 1, "name" => "Open"}, %{"id" => 2, "name" => "In Progress"}]
         }}

      "PATCH", path, %{}, form, _settings ->
        send(self(), {:backlog_patch, path, form})

        {:ok, %{status: 200, body: raw_issue(42) |> put_in(["status", "name"], "In Progress")}}
    end

    assert {:ok, updated} =
             BacklogClient.update_issue_state_for_test(
               issue,
               "in progress",
               tracker_settings(),
               request_fun
             )

    assert updated.state == "In Progress"
    assert_receive {:backlog_patch, "/issues/TEST-42", %{"statusId" => 2}}

    assert {:error, {:backlog_unknown_status, "Shipped"}} =
             BacklogClient.update_issue_state_for_test(
               issue,
               "Shipped",
               tracker_settings(),
               request_fun
             )
  end

  test "client skips issue queries when requested Backlog states do not exist" do
    request_fun = fn
      "GET", "/projects/TEST", %{}, nil, _settings ->
        {:ok, %{status: 200, body: %{"id" => 7}}}

      "GET", "/projects/TEST/statuses", %{}, nil, _settings ->
        {:ok, %{status: 200, body: [%{"id" => 1, "name" => "Open"}]}}

      _method, "/issues", _query, _form, _settings ->
        flunk("unknown Backlog states should not query issues")
    end

    assert {:ok, []} =
             BacklogClient.fetch_issues_by_states_for_test(
               ["Waiting for release"],
               tracker_settings(),
               request_fun
             )

    assert {:ok, []} =
             BacklogClient.fetch_issues_by_states_for_test(
               [],
               tracker_settings(),
               fn _method, _path, _query, _form, _settings ->
                 flunk("empty Backlog states should not make an HTTP request")
               end
             )
  end

  test "client refreshes issue IDs in order, omits 404s and out-of-project records" do
    request_fun = fn "GET", path, %{}, nil, _settings ->
      send(self(), {:backlog_id_path, path})

      case path do
        "/issues/2" -> {:ok, %{status: 200, body: raw_issue(2)}}
        "/issues/1" -> {:ok, %{status: 200, body: raw_issue(1)}}
        "/issues/404" -> {:ok, %{status: 404, body: [%{"message" => "Not found"}]}}
        "/issues/3" -> {:ok, %{status: 200, body: Map.put(raw_issue(3), "issueKey", "OTHER-3")}}
      end
    end

    assert {:ok, issues} =
             BacklogClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "3", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]
    assert_receive {:backlog_id_path, "/issues/2"}
    assert_receive {:backlog_id_path, "/issues/1"}
    assert_receive {:backlog_id_path, "/issues/404"}
    assert_receive {:backlog_id_path, "/issues/3"}
    refute_receive {:backlog_id_path, "/issues/2"}

    assert {:error, :invalid_backlog_issue_id} =
             BacklogClient.fetch_issues_by_ids_for_test(
               ["TEST-1"],
               tracker_settings(),
               request_fun
             )

    assert {:error, :backlog_unknown_payload} =
             BacklogClient.fetch_issues_by_ids_for_test(
               ["4"],
               tracker_settings(),
               fn _method, _path, _query, _form, _settings ->
                 {:ok, %{status: 200, body: Map.put(raw_issue(4), "summary", "")}}
               end
             )
  end

  test "backlog_api preserves REST responses and rejects unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      BacklogAgentTool.execute(
        "backlog_api",
        %{
          "method" => "patch",
          "path" => " /issues/TEST-42 ",
          "query" => %{"notify" => false},
          "form" => %{"statusId" => 4, "comment" => "done"}
        },
        tracker_settings: tracker_settings,
        backlog_client: fn method, path, query, form, opts ->
          send(test_pid, {:backlog_tool_called, method, path, query, form, opts})
          {:ok, %{status: 200, body: raw_issue(42)}}
        end
      )

    assert_received {:backlog_tool_called, "PATCH", "/issues/TEST-42", query, form, opts}
    assert query == %{"notify" => false}
    assert form == %{"statusId" => 4, "comment" => "done"}
    assert opts == [tracker_settings: tracker_settings]
    assert response["success"] == true
    assert Jason.decode!(response["output"])["status"] == 200
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    failure =
      BacklogAgentTool.execute(
        "backlog_api",
        %{"method" => "GET", "path" => "/issues/TEST-404"},
        backlog_client: fn _method, _path, _query, _form, _opts ->
          {:ok, %{status: 404, body: [%{"message" => "Not found"}]}}
        end
      )

    refute failure["success"]

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://space.backlog.com/api/v2/issues"},
        %{"method" => "GET", "path" => "//other.example/issues"},
        %{"method" => "GET", "path" => "/issues/../users/myself"},
        %{"method" => "PUT", "path" => "/issues/TEST-1"},
        %{"method" => "GET", "path" => "/issues", "query" => false},
        %{"method" => "POST", "path" => "/issues", "form" => false},
        %{"method" => "GET", "path" => "/issues", "query" => %{"apiKey" => "secret"}},
        %{"path" => "/users/myself"}
      ],
      fn arguments ->
        invalid =
          BacklogAgentTool.execute(
            "backlog_api",
            arguments,
            backlog_client: fn _method, _path, _query, _form, _opts ->
              flunk("invalid backlog_api arguments should not call the client")
            end
          )

        refute invalid["success"]
      end
    )
  end

  test "backlog_api hides transport details and tracker binds token environments" do
    transport_failure =
      BacklogAgentTool.execute(
        "backlog_api",
        %{"method" => "GET", "path" => "/users/myself"},
        backlog_client: fn _method, _path, _query, _form, _opts ->
          {:error, {:backlog_api_request, "https://space.backlog.com?apiKey=secret"}}
        end
      )

    refute transport_failure["success"]
    refute transport_failure["output"] =~ "secret"

    token_env = "SYMPHONY_BACKLOG_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_backlog_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == BacklogAdapter
    assert binding.secret_environment_names == ["BACKLOG_API_KEY", token_env]
    assert [%{"name" => "backlog_api"}] = binding.tool_specs
    assert :ok = Config.validate!()
  end

  test "backlog_api reports unsupported tools, malformed calls, and client failures" do
    unsupported = BacklogAgentTool.execute("not_backlog_api", %{}, [])
    refute unsupported["success"]
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["backlog_api"]

    Enum.each(
      ["not-an-object", %{"method" => "GET", "path" => 123}],
      fn arguments ->
        invalid =
          BacklogAgentTool.execute(
            "backlog_api",
            arguments,
            backlog_client: fn _method, _path, _query, _form, _opts ->
              flunk("malformed backlog_api arguments should not call the client")
            end
          )

        refute invalid["success"]
      end
    )

    malformed_response =
      BacklogAgentTool.execute(
        "backlog_api",
        %{"method" => "GET", "path" => "/users/myself"},
        backlog_client: fn _method, _path, _query, _form, _opts ->
          {:ok, %{status: "not-an-integer", body: %{}}}
        end
      )

    refute malformed_response["success"]

    Enum.each(
      [:missing_backlog_api_key, :unexpected_failure],
      fn reason ->
        failure =
          BacklogAgentTool.execute(
            "backlog_api",
            %{"method" => "GET", "path" => "/users/myself"},
            backlog_client: fn _method, _path, _query, _form, _opts ->
              {:error, reason}
            end
          )

        refute failure["success"]
        assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
        assert is_binary(message)
      end
    )

    non_json_body =
      BacklogAgentTool.execute(
        "backlog_api",
        %{"method" => "GET", "path" => "/users/myself"},
        backlog_client: fn _method, _path, _query, _form, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "backlog",
      provider:
        Map.merge(
          %{
            "base_url" => "https://space.backlog.com",
            "project_key" => "TEST",
            "api_key" => "test-token"
          },
          provider_overrides
        ),
      active_states: ["Open", "In Progress"],
      terminal_states: ["Closed"]
    }
  end

  defp raw_issue(id) do
    %{
      "id" => id,
      "projectId" => 7,
      "issueKey" => "TEST-#{id}",
      "keyId" => id,
      "issueType" => %{"id" => 11, "name" => "Task"},
      "summary" => "Issue #{id}",
      "description" => " Body #{id} ",
      "priority" => %{"id" => 3, "name" => "Normal"},
      "status" => %{"id" => 1, "name" => "Open"},
      "assignee" => %{"id" => 99, "userId" => "octocat"},
      "category" => [
        %{"id" => 1, "name" => " Bug "},
        %{"id" => 2, "name" => "bug"},
        %{"id" => 3, "name" => "Platform"}
      ],
      "created" => "2026-01-01T00:00:00Z",
      "updated" => "2026-01-02T00:00:00Z"
    }
  end

  defp write_backlog_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: backlog
        provider:
          base_url: "https://space.backlog.com"
          project_key: "TEST"
          api_key: #{Jason.encode!(token)}
        active_states: ["Open"]
        terminal_states: ["Closed"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
