defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil
  @default_repository_branches ["main", "master", "develop", "development"]
  @worktree_remote "origin"

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    case Config.settings!().workspace.mode do
      "existing" -> use_existing_workspace(worker_host)
      "worktree" -> create_worktree_workspace(issue_or_identifier, worker_host)
      _ -> create_per_issue_workspace(issue_or_identifier, worker_host)
    end
  end

  @spec dispatch_candidates([map()]) :: [map()]
  def dispatch_candidates(issues) when is_list(issues) do
    case Config.settings!().workspace.mode do
      "existing" -> existing_workspace_dispatch_candidates(issues)
      _ -> issues
    end
  end

  defp existing_workspace_dispatch_candidates(issues) do
    workspace = Config.local_workspace_root()

    with {branch, 0} <-
           System.cmd("git", ["-C", workspace, "branch", "--show-current"], stderr_to_stdout: true),
         branch <- String.trim(branch),
         {status, 0} <-
           System.cmd("git", ["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true) do
      select_candidates_for_existing_branch(issues, branch, String.trim(status))
    else
      {_output, status} ->
        Logger.warning("Existing workspace is not ready for dispatch path=#{workspace} git_status=#{status}")

        []
    end
  end

  defp select_candidates_for_existing_branch(issues, branch, status) do
    case Regex.run(~r/[A-Z][A-Z0-9_]*-\d+/, branch) do
      [identifier] ->
        matching_issues =
          Enum.filter(issues, fn
            %{identifier: issue_identifier} when is_binary(issue_identifier) ->
              String.upcase(issue_identifier) == String.upcase(identifier)

            _ ->
              false
          end)

        select_ticket_branch_candidates(issues, matching_issues, branch, status)

      nil when branch in @default_repository_branches and status == "" ->
        issues

      nil ->
        Logger.info("Existing workspace is occupied by branch=#{branch} dirty=#{status != ""}; skipping dispatch")

        []
    end
  end

  defp select_ticket_branch_candidates(issues, [], branch, "") do
    Logger.info("Existing workspace is clean and its ticket branch is no longer active branch=#{branch}; allowing the next ticket")
    issues
  end

  defp select_ticket_branch_candidates(_issues, [], branch, _status) do
    Logger.info("Existing workspace has local changes on a non-active ticket branch=#{branch}; skipping dispatch")
    []
  end

  defp select_ticket_branch_candidates(_issues, matching_issues, _branch, _status),
    do: matching_issues

  defp create_per_issue_workspace(issue_or_identifier, worker_host) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
          :ok ->
            {:ok, workspace}

          {:error, _reason} = error ->
            cleanup_failed_new_workspace(workspace, created?, worker_host)
            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")

        {:error, error}
    end
  end

  defp create_worktree_workspace(issue_or_identifier, nil) do
    with {:ok, repository} <- worktree_repository(),
         {:ok, workspace} <- workspace_path_for_issue(workspace_key(issue_or_identifier), nil),
         :ok <- validate_workspace_path(workspace, nil) do
      ensure_worktree(repository, workspace)
    end
  end

  defp create_worktree_workspace(_issue_or_identifier, worker_host) when is_binary(worker_host) do
    {:error, {:worktree_workspace_unsupported_worker, worker_host}}
  end

  defp worktree_repository do
    case Config.workspace_repository() do
      repository when is_binary(repository) ->
        case PathSafety.canonicalize(repository) do
          {:ok, canonical_repository} ->
            if File.exists?(Path.join(canonical_repository, ".git")) do
              {:ok, canonical_repository}
            else
              {:error, {:worktree_repository_missing, canonical_repository}}
            end

          {:error, {:path_canonicalize_failed, path, reason}} ->
            {:error, {:workspace_path_unreadable, path, reason}}
        end

      nil ->
        {:error, :worktree_repository_not_configured}
    end
  end

  defp ensure_worktree(repository, workspace) do
    run_git(repository, ["worktree", "prune"])

    if File.dir?(workspace) do
      reuse_worktree(workspace)
    else
      File.mkdir_p!(Path.dirname(workspace))
      add_worktree(repository, workspace)
    end
  end

  defp reuse_worktree(workspace) do
    case run_git(workspace, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, "true"} ->
        {:ok, workspace}

      _ ->
        {:error, {:worktree_path_occupied, workspace}}
    end
  end

  defp add_worktree(repository, workspace) do
    fetch_worktree_remote(repository)

    with {:ok, base_ref} <- worktree_base_ref(repository) do
      case run_git(repository, ["worktree", "add", "--detach", workspace, base_ref]) do
        {:ok, _output} ->
          Logger.info("Created git worktree repository=#{repository} workspace=#{workspace} base_ref=#{base_ref}")

          {:ok, workspace}

        {:error, {status, output}} ->
          {:error, {:worktree_add_failed, workspace, status, output}}
      end
    end
  end

  defp fetch_worktree_remote(repository) do
    case run_git(repository, ["fetch", @worktree_remote]) do
      {:ok, _output} ->
        :ok

      {:error, {status, output}} ->
        Logger.warning("Failed to fetch #{@worktree_remote} before creating a worktree repository=#{repository} status=#{status} output=#{inspect(output)}")

        :ok
    end
  end

  defp worktree_base_ref(repository) do
    case Config.settings!().workspace.base_ref do
      base_ref when is_binary(base_ref) and base_ref != "" ->
        if worktree_ref_exists?(repository, base_ref) do
          {:ok, base_ref}
        else
          {:error, {:worktree_base_ref_missing, repository, [base_ref]}}
        end

      _ ->
        default_worktree_base_ref(repository)
    end
  end

  defp default_worktree_base_ref(repository) do
    candidates =
      ["#{@worktree_remote}/HEAD" | Enum.map(@default_repository_branches, &"#{@worktree_remote}/#{&1}")]

    case Enum.find(candidates, &worktree_ref_exists?(repository, &1)) do
      nil -> {:error, {:worktree_base_ref_missing, repository, candidates}}
      base_ref -> {:ok, base_ref}
    end
  end

  defp worktree_ref_exists?(repository, ref) do
    match?({:ok, _commit}, run_git(repository, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]))
  end

  defp remove_worktree(workspace) do
    with true <- File.exists?(workspace),
         {:ok, repository} <- worktree_repository() do
      case run_git(repository, ["worktree", "remove", workspace]) do
        {:ok, _output} ->
          run_git(repository, ["worktree", "prune"])
          {:ok, []}

        {:error, {status, output}} ->
          Logger.warning("Keeping git worktree that still holds local state workspace=#{workspace} status=#{status} output=#{inspect(output)}")

          {:ok, []}
      end
    else
      false ->
        {:ok, []}

      {:error, reason} ->
        Logger.warning("Skipping worktree removal workspace=#{workspace} reason=#{inspect(reason)}")

        {:ok, []}
    end
  end

  defp run_git(directory, args) when is_binary(directory) and is_list(args) do
    {output, status} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)

    case status do
      0 -> {:ok, String.trim(output)}
      _ -> {:error, {status, String.trim(output)}}
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:git_unavailable, Exception.message(error)}}
  end

  defp use_existing_workspace(nil) do
    workspace = Config.local_workspace_root()

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         true <- File.dir?(canonical_workspace) do
      {:ok, canonical_workspace}
    else
      false ->
        {:error, {:existing_workspace_missing, Path.expand(workspace)}}

      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp use_existing_workspace(worker_host) when is_binary(worker_host) do
    {:error, {:existing_workspace_unsupported_worker, worker_host}}
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case workspace_mode() do
      "existing" ->
        {:ok, []}

      "worktree" ->
        maybe_run_before_remove_hook(workspace, nil)
        remove_worktree(workspace)

      _ ->
        remove_local_workspace_if_safe(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    if existing_workspace_mode?() do
      {:ok, []}
    else
      maybe_run_before_remove_hook(workspace, worker_host)

      script =
        [
          remote_shell_assign("workspace", workspace),
          "rm -rf \"$workspace\""
        ]
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
        {:ok, {_output, 0}} ->
          {:ok, []}

        {:ok, {output, status}} ->
          {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

        {:error, reason} ->
          {:error, reason, ""}
      end
    end
  end

  defp workspace_mode do
    Config.settings!().workspace.mode
  end

  defp existing_workspace_mode? do
    workspace_mode() == "existing"
  end

  defp remove_local_workspace_if_safe(workspace) do
    if File.exists?(workspace) do
      remove_validated_local_workspace(workspace)
    else
      File.rm_rf(workspace)
    end
  end

  defp remove_validated_local_workspace(workspace) do
    case validate_workspace_path(workspace, nil) do
      :ok ->
        remove_local_workspace(workspace)

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    cond do
      existing_workspace_mode?() ->
        {:ok, []}

      Path.type(workspace) != :absolute ->
        {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}

      workspace_mode() == "worktree" ->
        remove(workspace, nil)

      true ->
        remove_validated_recorded_workspace(workspace)
    end
  end

  def remove_recorded(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    remove(workspace, worker_host)
  end

  def remove_recorded(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  defp remove_validated_recorded_workspace(workspace) do
    case validate_recorded_workspace_path(workspace) do
      :ok ->
        remove_local_workspace(workspace)

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp remove_local_workspace(workspace) do
    maybe_run_before_remove_hook(workspace, nil)
    File.rm_rf(workspace)
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(issue), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host)
      when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(identifier), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.local_workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host)
       when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false, _worker_host), do: :ok

  defp cleanup_failed_new_workspace(workspace, true, nil) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, worker_host) when is_binary(worker_host) do
    script =
      [remote_shell_assign("workspace", workspace), "rm -rf \"$workspace\""] |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("Failed to remove partial workspace worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(result)}")
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host)
       when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(
           worker_host,
           "cd #{shell_escape(workspace)} && #{command}",
           timeout_ms
         ) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and
              timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
