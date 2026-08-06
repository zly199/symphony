defmodule SymphonyElixirWeb.ArtifactController do
  @moduledoc """
  Serves the deliverable a phase published for its gate.

  The body is read from Symphony's own state rather than from the workspace, so a
  document stays readable after the worktree is gone, and no request can be talked
  into reading a file the agent happened to leave somewhere.
  """

  use Phoenix.Controller, formats: []

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.Artifact

  @doc "Renders `issue_id`'s artifact for `phase`."
  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"issue_id" => issue_id, "phase" => phase}) do
    case Artifact.fetch(issue_id, phase) do
      nil ->
        Logger.debug("Artifact not found issue_id=#{issue_id} phase=#{phase}")
        send_resp(conn, 404, "Not Found")

      artifact ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, render_body(artifact))
    end
  end

  @doc "Returns the dashboard link for an artifact."
  @spec artifact_path(String.t(), String.t() | atom()) :: String.t()
  def artifact_path(issue_id, phase) when is_binary(issue_id) do
    "/artifacts/#{URI.encode(issue_id)}/#{phase}"
  end

  # An HTML artifact is a document in its own right and is served as authored.
  # Anything else is the agent's prose, so it is wrapped in the smallest page that
  # makes it readable rather than being reflowed into markup it did not ask for.
  defp render_body(%{format: "html", body: body}), do: body

  defp render_body(artifact) do
    """
    <!doctype html>
    <html lang="zh">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>#{escape(artifact.title)}</title>
    <style>
      :root { color-scheme: light dark; }
      body {
        margin: 0 auto;
        padding: 2.5rem 1.5rem 4rem;
        max-width: 54rem;
        font: 15px/1.7 ui-sans-serif, -apple-system, "Helvetica Neue", "PingFang SC", sans-serif;
      }
      header { border-bottom: 1px solid rgba(128,128,128,0.3); padding-bottom: 1rem; margin-bottom: 1.5rem; }
      h1 { font-size: 1.35rem; margin: 0 0 0.35rem; }
      .meta { font-size: 0.82rem; opacity: 0.65; }
      pre {
        white-space: pre-wrap;
        word-wrap: break-word;
        font: 13.5px/1.65 ui-monospace, SFMono-Regular, Menlo, monospace;
        margin: 0;
      }
    </style>
    </head>
    <body>
    <header>
      <h1>#{escape(artifact.title)}</h1>
      <p class="meta">#{escape(artifact.identifier || artifact.issue_id)} · #{escape(artifact.phase)} · #{escape(artifact.published_at)}</p>
    </header>
    <pre>#{escape(artifact.body)}</pre>
    </body>
    </html>
    """
  end

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(value), do: value |> to_string() |> escape()
end
