defmodule SymphonyElixirWeb.AnalysisDocController do
  @moduledoc """
  Serves a work item's analysis document from the shared knowledge base.

  Repository-backed worktree workflows store `ai-workspace` in the source
  checkout outside Git. The whole shared `ai-workspace/docs` tree is served
  under one prefix, which keeps the document's relative asset links working.
  """

  use Phoenix.Controller, formats: []

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.{AnalysisDoc, PathSafety, Workspace}

  @content_types %{
    ".html" => "text/html; charset=utf-8",
    ".css" => "text/css; charset=utf-8",
    ".js" => "text/javascript; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".svg" => "image/svg+xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @doc """
  Redirects the bare identifier to the ticket's own analysis page.
  """
  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"issue_identifier" => identifier}) do
    redirect(conn, to: doc_path(identifier))
  end

  @doc """
  Serves one file from the shared `ai-workspace/docs` tree.
  """
  @spec asset(Conn.t(), map()) :: Conn.t()
  def asset(conn, %{"workspace_key" => workspace_key, "path" => segments}) do
    with {:ok, file} <- locate(workspace_key, segments),
         {:ok, body} <- File.read(file) do
      conn
      |> put_resp_content_type(content_type(file))
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, body)
    else
      {:error, reason} ->
        Logger.debug("Analysis doc not served workspace_key=#{workspace_key} segments=#{inspect(segments)} reason=#{inspect(reason)}")

        send_resp(conn, 404, "Not Found")
    end
  end

  @doc """
  Returns the dashboard link for a work item's analysis document.
  """
  @spec doc_path(String.t()) :: String.t()
  def doc_path(identifier) when is_binary(identifier) do
    key = Workspace.workspace_key(identifier)

    "/analysis/#{URI.encode(key)}/tickets/#{URI.encode(identifier)}/index.html"
  end

  @doc """
  Returns true when the work item's analysis document exists on disk.
  """
  @spec doc_exists?(String.t() | nil) :: boolean()
  defdelegate doc_exists?(identifier), to: AnalysisDoc, as: :exists?

  # The source repository owns the shared knowledge base. The worktree remains
  # a compatibility fallback for workflows without shared repository docs.
  defp locate(workspace_key, segments) do
    with {:error, _repository_reason} <-
           locate_in(AnalysisDoc.repository_docs_root(), segments) do
      locate_in(AnalysisDoc.docs_root(workspace_key), segments)
    end
  end

  defp locate_in({:ok, docs_root}, segments), do: resolve_within(docs_root, segments)
  defp locate_in({:error, reason}, _segments), do: {:error, reason}

  # The path comes from a URL, so it is resolved and then re-checked against the
  # docs root rather than trusted after a textual filter.
  defp resolve_within(docs_root, segments) when is_list(segments) do
    with {:ok, candidate} <- PathSafety.canonicalize(Path.join([docs_root | segments])),
         true <- AnalysisDoc.within?(docs_root, candidate),
         true <- File.regular?(candidate) do
      {:ok, candidate}
    else
      false -> {:error, :not_a_readable_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_type(file) do
    Map.get(@content_types, file |> Path.extname() |> String.downcase(), "application/octet-stream")
  end
end
