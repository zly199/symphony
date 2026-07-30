defmodule SymphonyElixir.ResumeState do
  @moduledoc """
  Inspects a work item's workspace so a prompt can state what already exists.

  The orchestrator loses its in-memory progress on restart, and a fresh Codex
  session has no memory of earlier runs. Reading the workspace directly gives
  both of them the same ground truth: which branch is checked out, whether the
  ticket already carries a commit, and whether that commit reached `origin`.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @remote "origin"

  @type t :: %{
          available: boolean(),
          workspace: String.t() | nil,
          base_ref: String.t() | nil,
          branch: String.t() | nil,
          ticket_branch: boolean(),
          commits_ahead: non_neg_integer(),
          head_commit: String.t() | nil,
          head_subject: String.t() | nil,
          dirty_files: non_neg_integer(),
          remote_branch: String.t() | nil,
          remote_synced: boolean(),
          started: boolean()
        }

  @empty %{
    available: false,
    workspace: nil,
    base_ref: nil,
    branch: nil,
    ticket_branch: false,
    commits_ahead: 0,
    head_commit: nil,
    head_subject: nil,
    dirty_files: 0,
    remote_branch: nil,
    remote_synced: false,
    started: false
  }

  @doc """
  Returns what the workspace shows about prior work on `issue`.

  Always returns a map. A workspace that is missing, unreadable, or not a git
  checkout yields `available: false` so callers never have to special-case it.
  """
  @spec inspect_workspace(String.t() | nil, Issue.t() | map()) :: t()
  def inspect_workspace(workspace, issue) when is_binary(workspace) do
    if git_workspace?(workspace) do
      collect(workspace, issue)
    else
      @empty
    end
  end

  def inspect_workspace(_workspace, _issue), do: @empty

  @doc false
  @spec empty() :: t()
  def empty, do: @empty

  defp git_workspace?(workspace) do
    File.dir?(workspace) and match?({:ok, "true"}, run_git(workspace, ["rev-parse", "--is-inside-work-tree"]))
  end

  defp collect(workspace, issue) do
    base_ref = base_ref(workspace)
    branch = current_branch(workspace)
    identifier = identifier(issue)
    commits_ahead = commits_ahead(workspace, base_ref)
    remote_branch = remote_branch(workspace, branch)

    %{
      @empty
      | available: true,
        workspace: workspace,
        base_ref: base_ref,
        branch: branch,
        ticket_branch: ticket_branch?(branch, identifier),
        commits_ahead: commits_ahead,
        head_commit: head_commit(workspace),
        head_subject: head_subject(workspace),
        dirty_files: dirty_files(workspace),
        remote_branch: remote_branch,
        remote_synced: remote_synced?(workspace, remote_branch),
        started: commits_ahead > 0 or ticket_branch?(branch, identifier)
    }
  end

  defp identifier(%Issue{identifier: identifier}), do: identifier
  defp identifier(%{identifier: identifier}), do: identifier
  defp identifier(_issue), do: nil

  defp base_ref(workspace) do
    case Config.settings!().workspace.base_ref do
      base_ref when is_binary(base_ref) and base_ref != "" ->
        base_ref

      _ ->
        if ref_exists?(workspace, "#{@remote}/master"), do: "#{@remote}/master", else: "#{@remote}/HEAD"
    end
  end

  # A worktree created with `--detach` reports an empty branch until the ticket
  # branch is prepared, so an empty result means "no branch yet", not an error.
  defp current_branch(workspace) do
    case run_git(workspace, ["branch", "--show-current"]) do
      {:ok, ""} -> nil
      {:ok, branch} -> branch
      {:error, _reason} -> nil
    end
  end

  defp ticket_branch?(branch, identifier) when is_binary(branch) and is_binary(identifier) do
    String.contains?(branch, identifier)
  end

  defp ticket_branch?(_branch, _identifier), do: false

  defp commits_ahead(workspace, base_ref) when is_binary(base_ref) do
    case run_git(workspace, ["rev-list", "--count", "#{base_ref}..HEAD"]) do
      {:ok, count} ->
        case Integer.parse(count) do
          {parsed, _rest} -> parsed
          :error -> 0
        end

      {:error, _reason} ->
        0
    end
  end

  defp commits_ahead(_workspace, _base_ref), do: 0

  defp head_commit(workspace) do
    case run_git(workspace, ["rev-parse", "--short", "HEAD"]) do
      {:ok, commit} -> commit
      {:error, _reason} -> nil
    end
  end

  defp head_subject(workspace) do
    case run_git(workspace, ["log", "-1", "--pretty=%s"]) do
      {:ok, ""} -> nil
      {:ok, subject} -> subject
      {:error, _reason} -> nil
    end
  end

  defp dirty_files(workspace) do
    case run_git(workspace, ["status", "--porcelain"]) do
      {:ok, ""} ->
        0

      {:ok, output} ->
        output |> String.split("\n", trim: true) |> length()

      {:error, _reason} ->
        0
    end
  end

  defp remote_branch(workspace, branch) when is_binary(branch) do
    remote_ref = "#{@remote}/#{branch}"

    if ref_exists?(workspace, remote_ref), do: remote_ref, else: nil
  end

  defp remote_branch(_workspace, _branch), do: nil

  defp remote_synced?(workspace, remote_ref) when is_binary(remote_ref) do
    case {run_git(workspace, ["rev-parse", "HEAD"]), run_git(workspace, ["rev-parse", remote_ref])} do
      {{:ok, head}, {:ok, remote}} -> head == remote
      _ -> false
    end
  end

  defp remote_synced?(_workspace, _remote_ref), do: false

  defp ref_exists?(workspace, ref) do
    match?({:ok, _commit}, run_git(workspace, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]))
  end

  defp run_git(directory, args) do
    {output, status} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)

    case status do
      0 -> {:ok, String.trim(output)}
      _ -> {:error, {status, String.trim(output)}}
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      Logger.debug("Resume-state git call failed directory=#{directory} args=#{inspect(args)}: #{Exception.message(error)}")

      {:error, {:git_unavailable, Exception.message(error)}}
  end
end
