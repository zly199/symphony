defmodule SymphonyElixir.AnalysisDoc do
  @moduledoc """
  Locates the shared analysis document a work item produces.

  The approval gate and the dashboard both need to know whether the deliverable
  actually exists, so the location rule lives here rather than in either caller.
  """

  alias SymphonyElixir.{Config, PathSafety, Workspace}

  @docs_subpath "ai-workspace/docs"

  @doc """
  Returns the legacy `ai-workspace/docs` root inside `identifier`'s workspace.

  The path is canonicalized and re-checked against the configured workspace
  root, so a crafted identifier cannot point outside it. This remains available
  as a fallback for workflows that do not configure a source repository.
  """
  @spec docs_root(String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def docs_root(workspace_key) when is_binary(workspace_key) do
    root = Config.local_workspace_root()

    with {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, docs_root} <-
           PathSafety.canonicalize(Path.join([canonical_root, workspace_key, @docs_subpath])),
         true <- within?(canonical_root, docs_root) do
      {:ok, docs_root}
    else
      false -> {:error, :outside_workspace_root}
      {:error, reason} -> {:error, reason}
    end
  end

  def docs_root(_workspace_key), do: {:error, :missing_workspace_key}

  @doc """
  Returns the source repository's shared docs root.

  Repository-backed worktree workflows keep `ai-workspace` outside Git so every
  ticket reads and updates the same knowledge base.
  """
  @spec repository_docs_root() :: {:ok, Path.t()} | {:error, term()}
  def repository_docs_root do
    case Config.workspace_repository() do
      repository when is_binary(repository) ->
        with {:ok, canonical_repository} <- PathSafety.canonicalize(repository),
             {:ok, docs_root} <-
               PathSafety.canonicalize(Path.join(canonical_repository, @docs_subpath)),
             true <- within?(canonical_repository, docs_root) do
          {:ok, docs_root}
        else
          false -> {:error, :outside_repository}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :repository_not_configured}
    end
  end

  @doc "Returns the analysis document path for `identifier`, if resolvable."
  @spec doc_file(String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def doc_file(identifier) when is_binary(identifier) do
    case repository_docs_root() do
      {:ok, docs_root} ->
        {:ok, Path.join([docs_root, "tickets", identifier, "index.html"])}

      {:error, _repository_reason} ->
        with {:ok, docs_root} <- identifier |> Workspace.workspace_key() |> docs_root() do
          {:ok, Path.join([docs_root, "tickets", identifier, "index.html"])}
        end
    end
  end

  def doc_file(_identifier), do: {:error, :missing_identifier}

  @doc "Returns true when `identifier`'s analysis document exists on disk."
  @spec exists?(String.t() | nil) :: boolean()
  def exists?(identifier) do
    case doc_file(identifier) do
      {:ok, file} -> File.regular?(file)
      {:error, _reason} -> false
    end
  end

  @doc "Returns true when `candidate` sits inside `root`."
  @spec within?(Path.t(), Path.t()) :: boolean()
  def within?(root, candidate) do
    candidate == root or String.starts_with?(candidate, root <> "/")
  end
end
