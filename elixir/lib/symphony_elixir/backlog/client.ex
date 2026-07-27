defmodule SymphonyElixir.Backlog.Client do
  @moduledoc """
  Thin Backlog REST client for project-scoped issue polling.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @page_size 100

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    ["BACKLOG_API_KEY" | env_reference_names([provider["api_key"]])]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, Config.settings!().tracker, &perform_request/5)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids) when is_list(ids) do
    fetch_issues_by_ids(ids, Config.settings!().tracker, &perform_request/5)
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, query, form, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(query) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, backlog_settings} <- settings(tracker_settings) do
      request_fun.(method, path, query, form, backlog_settings)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, tracker_settings)
      when is_map(issue) and is_map(tracker_settings) do
    case settings(tracker_settings) do
      {:ok, backlog_settings} -> normalize_issue(issue, backlog_settings)
      _ -> nil
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, tracker_settings, request_fun)
      when is_list(states) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(states, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(ids, tracker_settings, request_fun)
      when is_list(ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(ids, tracker_settings, request_fun)
  end

  defp fetch_issues_by_states([], _tracker_settings, _request_fun), do: {:ok, []}

  defp fetch_issues_by_states(states, tracker_settings, request_fun) do
    requested_states = states |> Enum.map(&normalize_state/1) |> MapSet.new()

    with {:ok, backlog_settings} <- settings(tracker_settings),
         {:ok, project} <- fetch_project(backlog_settings, request_fun),
         {:ok, statuses} <- fetch_statuses(backlog_settings, request_fun),
         {:ok, status_ids} <- matching_status_ids(statuses, requested_states) do
      case status_ids do
        [] ->
          {:ok, []}

        ids ->
          fetch_issue_pages(
            backlog_settings,
            project["id"],
            ids,
            requested_states,
            0,
            request_fun,
            []
          )
      end
    end
  end

  defp fetch_project(settings, request_fun) do
    request_with_settings(
      "GET",
      "/projects/#{encoded(settings.project_key)}",
      %{},
      nil,
      settings,
      request_fun,
      false
    )
    |> require_project()
  end

  defp require_project({:ok, %{"id" => id} = project}) when is_integer(id) and id > 0,
    do: {:ok, project}

  defp require_project({:ok, _payload}), do: {:error, :backlog_unknown_payload}
  defp require_project({:error, reason}), do: {:error, reason}

  defp fetch_statuses(settings, request_fun) do
    request_with_settings(
      "GET",
      "/projects/#{encoded(settings.project_key)}/statuses",
      %{},
      nil,
      settings,
      request_fun,
      false
    )
    |> require_statuses()
  end

  defp require_statuses({:ok, statuses}) when is_list(statuses), do: {:ok, statuses}
  defp require_statuses({:ok, _payload}), do: {:error, :backlog_unknown_payload}
  defp require_statuses({:error, reason}), do: {:error, reason}

  defp matching_status_ids(statuses, requested_states) do
    Enum.reduce_while(statuses, {:ok, []}, fn status, {:ok, ids} ->
      case matching_status_id(status, requested_states) do
        {:ok, nil} -> {:cont, {:ok, ids}}
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matching_status_id(
         %{"id" => id, "name" => name},
         requested_states
       )
       when is_integer(id) and id > 0 and is_binary(name) do
    if MapSet.member?(requested_states, normalize_state(name)), do: {:ok, id}, else: {:ok, nil}
  end

  defp matching_status_id(_status, _requested_states), do: {:error, :backlog_unknown_payload}

  defp fetch_issue_pages(
         settings,
         project_id,
         status_ids,
         requested_states,
         offset,
         request_fun,
         pages
       ) do
    query =
      %{
        "projectId[]" => project_id,
        "statusId[]" => status_ids,
        "count" => @page_size,
        "offset" => offset,
        "sort" => "created",
        "order" => "asc"
      }
      |> maybe_put("assigneeId[]", settings.assignee_id)

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             "/issues",
             query,
             nil,
             settings,
             request_fun,
             false
           ),
         true <- is_list(payload) or {:error, :backlog_unknown_payload} do
      issues = normalize_candidate_page(payload, settings, requested_states)
      updated_pages = [issues | pages]

      if length(payload) < @page_size do
        {:ok, updated_pages |> Enum.reverse() |> List.flatten()}
      else
        fetch_issue_pages(
          settings,
          project_id,
          status_ids,
          requested_states,
          offset + @page_size,
          request_fun,
          updated_pages
        )
      end
    end
  end

  defp fetch_issues_by_ids([], _tracker_settings, _request_fun), do: {:ok, []}

  defp fetch_issues_by_ids(ids, tracker_settings, request_fun) do
    with {:ok, backlog_settings} <- settings(tracker_settings) do
      ids
      |> Enum.uniq()
      |> fetch_issue_ids(backlog_settings, request_fun, [])
    end
  end

  defp fetch_issue_ids([], _settings, _request_fun, issues), do: {:ok, Enum.reverse(issues)}

  defp fetch_issue_ids([id | rest], settings, request_fun, issues) do
    with {:ok, issue_id} <- parse_issue_id(id),
         {:ok, payload} <-
           request_with_settings(
             "GET",
             "/issues/#{issue_id}",
             %{},
             nil,
             settings,
             request_fun,
             true
           ) do
      continue_issue_id_fetch(payload, rest, settings, request_fun, issues)
    end
  end

  defp continue_issue_id_fetch(:not_found, rest, settings, request_fun, issues) do
    fetch_issue_ids(rest, settings, request_fun, issues)
  end

  defp continue_issue_id_fetch(%{} = raw_issue, rest, settings, request_fun, issues) do
    if issue_in_project?(raw_issue, settings.project_key) do
      case normalize_issue(raw_issue, settings) do
        %Issue{} = issue -> fetch_issue_ids(rest, settings, request_fun, [issue | issues])
        nil -> {:error, :backlog_unknown_payload}
      end
    else
      fetch_issue_ids(rest, settings, request_fun, issues)
    end
  end

  defp continue_issue_id_fetch(_payload, _rest, _settings, _request_fun, _issues) do
    {:error, :backlog_unknown_payload}
  end

  defp normalize_candidate_page(raw_issues, settings, requested_states) do
    issues = Enum.map(raw_issues, &normalize_issue(&1, settings))
    malformed_count = Enum.count(issues, &is_nil/1)

    if malformed_count > 0 do
      Logger.warning("Dropping malformed Backlog issue records count=#{malformed_count}")
    end

    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))
  end

  defp normalize_issue(
         %{
           "id" => id,
           "issueKey" => issue_key,
           "summary" => title,
           "status" => %{"name" => state}
         } = issue,
         settings
       )
       when is_integer(id) and id > 0 and is_binary(issue_key) and is_binary(title) and
              is_binary(state) do
    if issue_in_project?(issue, settings.project_key) and present_string?(title) and
         present_string?(state) do
      %Issue{
        id: Integer.to_string(id),
        native_ref: native_ref(issue),
        identifier: issue_key,
        title: title,
        description: blank_to_nil(issue["description"]),
        priority: priority_id(issue["priority"]),
        state: state,
        branch_name: nil,
        url: "#{settings.web_url}/view/#{encoded(issue_key)}",
        assignee_id: assignee_id(issue["assignee"]),
        labels: extract_labels(issue["category"]),
        blocked_by: [],
        dispatchable: matches_assignee?(issue["assignee"], settings.assignee_id),
        created_at: parse_datetime(issue["created"]),
        updated_at: parse_datetime(issue["updated"])
      }
    end
  end

  defp normalize_issue(_issue, _settings), do: nil

  defp native_ref(issue) do
    %{
      "id" => issue["id"],
      "issue_key" => issue["issueKey"],
      "key_id" => issue["keyId"],
      "project_id" => issue["projectId"],
      "issue_type_id" => get_in(issue, ["issueType", "id"]),
      "status_id" => get_in(issue, ["status", "id"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp issue_in_project?(%{"issueKey" => issue_key}, project_key)
       when is_binary(issue_key) and is_binary(project_key) do
    String.starts_with?(
      String.upcase(issue_key),
      String.upcase(project_key) <> "-"
    )
  end

  defp issue_in_project?(_issue, _project_key), do: false

  defp priority_id(%{"id" => id}) when is_integer(id), do: id
  defp priority_id(_priority), do: nil

  defp assignee_id(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp assignee_id(_assignee), do: nil

  defp matches_assignee?(_assignee, nil), do: true

  defp matches_assignee?(%{"id" => id}, assignee_id) when is_integer(id) do
    id == assignee_id
  end

  defp matches_assignee?(_assignee, _assignee_id), do: false

  defp extract_labels(categories) when is_list(categories) do
    categories
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_categories), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp request_with_settings(method, path, query, form, settings, request_fun, allow_not_found) do
    case request_fun.(method, path, query, form, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: 404}} when allow_not_found ->
        {:ok, :not_found}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("Backlog API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:backlog_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :backlog_unknown_payload}
    end
  end

  defp perform_request(method, path, query, form, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: [{"Accept", "application/json"}],
        params: query_pairs(Map.put(query, "apiKey", settings.api_key)),
        connect_options: [timeout: 30_000]
      ]

      request_opts =
        if is_map(form) and map_size(form) > 0 do
          Keyword.put(request_opts, :form, query_pairs(form))
        else
          request_opts
        end

      case Req.request(request_opts) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:backlog_api_request, reason}}
      end
    end
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = resolve_api_url(provider)
    api_key = resolve_setting(provider["api_key"], System.get_env("BACKLOG_API_KEY"))
    project_key = resolve_setting(provider["project_key"], System.get_env("BACKLOG_PROJECT_KEY"))

    assignee_id =
      resolve_assignee_id(provider["assignee_id"], System.get_env("BACKLOG_ASSIGNEE_ID"))

    cond do
      not valid_api_url?(api_url) ->
        {:error, :invalid_backlog_base_url}

      not present_string?(api_key) ->
        {:error, :missing_backlog_api_key}

      not present_string?(project_key) ->
        {:error, :missing_backlog_project_key}

      not valid_project_key?(project_key) ->
        {:error, :invalid_backlog_project_key}

      assignee_id == :error ->
        {:error, :invalid_backlog_assignee_id}

      true ->
        {:ok,
         %{
           api_url: api_url,
           web_url: String.replace_suffix(api_url, "/api/v2", ""),
           api_key: api_key,
           project_key: project_key,
           assignee_id: assignee_id
         }}
    end
  end

  defp resolve_api_url(provider) do
    base_url = resolve_setting(provider["base_url"], System.get_env("BACKLOG_BASE_URL"))
    space = resolve_setting(provider["space"], System.get_env("BACKLOG_SPACE"))
    domain = resolve_setting(provider["domain"], System.get_env("BACKLOG_DOMAIN"))

    cond do
      present_string?(base_url) -> normalize_api_url(base_url)
      present_string?(space) -> normalize_api_url("https://#{space}.backlog.com")
      present_string?(domain) -> normalize_api_url("https://#{domain}")
      true -> nil
    end
  end

  defp normalize_api_url(value) when is_binary(value) do
    url = value |> String.trim() |> String.trim_trailing("/")
    if String.ends_with?(url, "/api/v2"), do: url, else: url <> "/api/v2"
  end

  defp normalize_api_url(_value), do: nil

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || fallback)
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp resolve_assignee_id(nil, fallback), do: parse_optional_positive_integer(fallback)

  defp resolve_assignee_id("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      parse_optional_positive_integer(System.get_env(env_name) || fallback)
    else
      :error
    end
  end

  defp resolve_assignee_id(value, _fallback), do: parse_optional_positive_integer(value)

  defp parse_optional_positive_integer(nil), do: nil

  defp parse_optional_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_optional_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> :error
    end
  end

  defp parse_optional_positive_integer(_value), do: :error

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name when is_binary(env_name) -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_api_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: "/api/v2"} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_api_url?(_value), do: false

  defp valid_project_key?(value) when is_binary(value) do
    String.match?(value, ~r/^[A-Za-z][A-Za-z0-9_]*$/)
  end

  defp valid_project_key?(_value), do: false

  defp parse_issue_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_backlog_issue_id}
    end
  end

  defp parse_issue_id(_value), do: {:error, :invalid_backlog_issue_id}

  defp query_pairs(query) when is_map(query) do
    Enum.flat_map(query, fn
      {_key, nil} -> []
      {key, values} when is_list(values) -> Enum.map(values, &{key, &1})
      {key, value} -> [{key, value}]
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encoded(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PATCH"), do: {:ok, :patch}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_backlog_method}

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
