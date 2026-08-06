defmodule SymphonyElixirWeb.TranscriptController do
  @moduledoc """
  Serves the recorded Codex event stream of a run.

  The dashboard's activity column answers "what is it doing"; this answers "what
  did it do". They are different questions, and the second one is the one asked
  after a phase ends with nothing published — at which point the ring of
  one-liners has already rolled over the part that would explain it.

  The page renders the agent's own words: its messages, its reasoning, the
  commands it ran and how they exited, the tools it called and what came back.
  Anything the renderer does not recognise still shows up as its raw event, so a
  new app-server message can never make a run unreadable, and `?format=raw`
  hands back the whole JSONL for grepping.
  """

  use Phoenix.Controller, formats: []

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.CodexTranscript

  # Command output and reasoning can each run to megabytes. The page shows enough
  # to see what happened and points at the raw file for the rest.
  @max_entry_bytes 4_000

  # Bookkeeping that says nothing about the work, and streaming deltas whose text
  # the completed item already carries in full.
  @quiet_methods [
    "account/rateLimits/updated",
    "account/updated",
    "account/chatgptAuthTokens/refresh",
    "thread/tokenUsage/updated",
    "item/reasoning/summaryPartAdded",
    "item/started"
  ]

  @doc "Renders `issue_id`'s most recent transcript, or the run named by `run`."
  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"issue_id" => issue_id} = params) do
    case CodexTranscript.read(issue_id, Map.get(params, "run")) do
      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")

      {:ok, run_name, events} ->
        case Map.get(params, "format") do
          "raw" -> send_raw(conn, issue_id, run_name)
          _ -> send_page(conn, issue_id, run_name, events)
        end
    end
  end

  @doc "Returns the dashboard link for an issue's latest transcript."
  @spec transcript_path(String.t()) :: String.t()
  def transcript_path(issue_id) when is_binary(issue_id) do
    "/transcripts/#{URI.encode(issue_id)}"
  end

  defp send_raw(conn, issue_id, run_name) do
    case Enum.find(CodexTranscript.runs(issue_id), &(&1.name == run_name)) do
      nil ->
        send_resp(conn, 404, "Not Found")

      run ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-store")
        |> send_file(200, run.path)
    end
  end

  defp send_page(conn, issue_id, run_name, events) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, render_page(issue_id, run_name, events))
  end

  defp render_page(issue_id, run_name, events) do
    runs = CodexTranscript.runs(issue_id)
    rendered = events |> Enum.map(&render_entry/1) |> Enum.reject(&is_nil/1)

    """
    <!doctype html>
    <html lang="zh">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>#{escape(issue_id)} 运行记录</title>
    <style>
      :root { color-scheme: light dark; }
      body {
        margin: 0 auto;
        padding: 2.5rem 1.5rem 4rem;
        max-width: 62rem;
        font: 15px/1.7 ui-sans-serif, -apple-system, "Helvetica Neue", "PingFang SC", sans-serif;
      }
      header { border-bottom: 1px solid rgba(128,128,128,0.3); padding-bottom: 1rem; margin-bottom: 1.5rem; }
      h1 { font-size: 1.35rem; margin: 0 0 0.35rem; }
      .meta { font-size: 0.82rem; opacity: 0.65; }
      .runs { font-size: 0.82rem; margin-top: 0.6rem; }
      .runs a { margin-right: 0.75rem; }
      .entry { border-left: 3px solid rgba(128,128,128,0.35); padding: 0.15rem 0 0.15rem 0.9rem; margin: 0 0 1.1rem; }
      .entry.agent { border-left-color: #2f8f5b; }
      .entry.reasoning { border-left-color: #7a6ff0; }
      .entry.command { border-left-color: #b8860b; }
      .entry.tool { border-left-color: #2b7bb9; }
      .entry.error { border-left-color: #c0392b; }
      .kind { font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.7; }
      .at { font-size: 0.78rem; opacity: 0.5; margin-left: 0.5rem; font-variant-numeric: tabular-nums; }
      pre {
        white-space: pre-wrap;
        word-wrap: break-word;
        font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace;
        margin: 0.35rem 0 0;
      }
      .empty { opacity: 0.6; }
    </style>
    </head>
    <body>
    <header>
      <h1>#{escape(issue_id)} 运行记录</h1>
      <p class="meta">#{escape(run_name)} · #{length(rendered)} 条事件</p>
      <p class="runs">#{render_run_links(issue_id, runs, run_name)}</p>
      <p class="runs"><a href="#{transcript_path(issue_id)}?run=#{URI.encode(run_name)}&amp;format=raw">下载原始 JSONL ↗</a></p>
    </header>
    #{if rendered == [], do: ~s(<p class="empty">这次运行没有记录到任何事件。</p>), else: Enum.join(rendered, "\n")}
    </body>
    </html>
    """
  end

  defp render_run_links(issue_id, runs, current) do
    runs
    |> Enum.map(fn run ->
      label = escape(run.recorded_at || run.name)

      if run.name == current do
        "<strong>#{label}</strong>"
      else
        ~s(<a href="#{transcript_path(issue_id)}?run=#{URI.encode(run.name)}">#{label}</a>)
      end
    end)
    |> Enum.join("")
  end

  defp render_entry(%{"event" => event} = entry) do
    case describe(event, entry) do
      nil ->
        nil

      {kind, label, body} ->
        """
        <div class="entry #{kind}">
          <span class="kind">#{escape(label)}</span><span class="at">#{escape(Map.get(entry, "at") || "")}</span>
          <pre>#{escape(clip(body))}</pre>
        </div>
        """
    end
  end

  defp render_entry(_entry), do: nil

  defp describe("transcript_opened", entry) do
    details = Map.get(entry, "details") || %{}

    body =
      [
        {"phase", Map.get(details, "phase")},
        {"workspace", Map.get(details, "workspace")},
        {"worker_host", Map.get(details, "worker_host")}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{value}" end)

    {"", "运行开始", body}
  end

  defp describe("transcript_closed", entry) do
    {"", "运行结束", get_in(entry, ["details", "outcome"]) || ""}
  end

  defp describe(_event, entry) do
    payload = Map.get(entry, "payload") || %{}
    method = Map.get(payload, "method")
    describe_method(method, payload, entry)
  end

  defp describe_method("item/completed", payload, _entry) do
    item = get_in(payload, ["params", "item"]) || %{}

    case Map.get(item, "type") do
      "agentMessage" -> {"agent", "AGENT 回复", Map.get(item, "text") || ""}
      "reasoning" -> {"reasoning", "思考过程", reasoning_text(item)}
      "commandExecution" -> {"command", "执行命令", command_text(item)}
      "fileChange" -> {"", "文件变更", file_change_text(item)}
      "todoList" -> {"", "计划更新", Jason.encode!(Map.get(item, "items") || [], pretty: true)}
      type -> {"", "item completed: #{type}", Jason.encode!(item, pretty: true)}
    end
  end

  defp describe_method("item/tool/call", payload, _entry) do
    params = Map.get(payload, "params") || %{}
    tool = Map.get(params, "tool") || Map.get(params, "name") || "tool"
    {"tool", "工具调用 #{tool}", Jason.encode!(Map.get(params, "arguments") || %{}, pretty: true)}
  end

  defp describe_method("turn/failed", payload, _entry) do
    {"error", "TURN 失败", Jason.encode!(Map.get(payload, "params") || %{}, pretty: true)}
  end

  defp describe_method("turn/completed", payload, _entry) do
    {"", "TURN 完成", Jason.encode!(Map.get(payload, "params") || %{}, pretty: true)}
  end

  # A method this page has never seen still gets rendered, as its own raw line:
  # an app-server that grows a new event must not be able to make a run look empty.
  defp describe_method(method, payload, _entry) when is_binary(method) do
    if quiet_method?(method) do
      nil
    else
      {"", method, Jason.encode!(Map.get(payload, "params") || payload, pretty: true)}
    end
  end

  defp describe_method(_method, _payload, entry) do
    case Map.get(entry, "raw") do
      raw when is_binary(raw) -> {"", Map.get(entry, "event") || "event", raw}
      _ -> nil
    end
  end

  defp quiet_method?(method) do
    method in @quiet_methods or String.ends_with?(method, "Delta") or
      String.ends_with?(method, "/delta")
  end

  defp reasoning_text(item) do
    case Map.get(item, "summary") || Map.get(item, "text") do
      text when is_binary(text) ->
        text

      parts when is_list(parts) ->
        parts
        |> Enum.map(fn
          part when is_binary(part) -> part
          part when is_map(part) -> Map.get(part, "text")
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      _ ->
        ""
    end
  end

  defp command_text(item) do
    command =
      case Map.get(item, "command") do
        command when is_binary(command) -> command
        command when is_list(command) -> Enum.join(command, " ")
        _ -> ""
      end

    exit_code = Map.get(item, "exitCode")
    output = Map.get(item, "aggregatedOutput") || Map.get(item, "output") || ""

    header = if is_integer(exit_code), do: "$ #{command}\n(exit #{exit_code})", else: "$ #{command}"

    if output == "", do: header, else: "#{header}\n\n#{output}"
  end

  defp file_change_text(item) do
    case Map.get(item, "changes") do
      changes when is_list(changes) ->
        Enum.map_join(changes, "\n", fn
          change when is_map(change) -> "#{Map.get(change, "kind") || "change"} #{Map.get(change, "path")}"
          change -> inspect(change)
        end)

      _ ->
        Jason.encode!(item, pretty: true)
    end
  end

  defp clip(value) when is_binary(value) do
    if byte_size(value) > @max_entry_bytes do
      String.slice(value, 0, @max_entry_bytes) <> "\n…（已截断，完整内容见原始 JSONL）"
    else
      value
    end
  end

  defp clip(value), do: value |> to_string() |> clip()

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(value), do: value |> to_string() |> escape()
end
