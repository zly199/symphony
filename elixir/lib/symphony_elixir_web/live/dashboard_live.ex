defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony 可观测性
            </p>
            <h1 class="hero-title">
              运行监控台
            </h1>
            <p class="hero-copy">
              展示当前 Symphony 运行实例的状态、重试压力、令牌用量及编排健康情况。
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              实时
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              离线
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            无法获取状态快照
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>：</strong> <%= localized_error_message(@payload.error) %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label"><%= tracker_source_label(@payload.tracker.source) %> 当前票</p>
            <p class="metric-value numeric"><%= @payload.counts.tracker_active %></p>
            <p class="metric-detail">票源中符合活动状态的票数。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">运行中</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">当前运行实例中的活跃问题会话数。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">重试中</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">等待下一次重试的问题数。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">已阻塞</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">等待操作人员输入或批准的问题数。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">令牌总数</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              输入 <%= format_int(@payload.codex_totals.input_tokens) %> / 输出 <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">运行时长</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">已完成及活跃会话的 Codex 累计运行时长。</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= tracker_source_label(@payload.tracker.source) %> 当前票</h2>
              <p class="section-copy">
                直接展示票源返回的活动票；工作区安全门仅控制代理调度。
                <%= if @payload.tracker.synced_at do %>
                  最近同步：<span class="mono numeric"><%= @payload.tracker.synced_at %></span>
                <% end %>
              </p>
            </div>
          </div>

          <%= if @payload.tracker.issues == [] do %>
            <p class="empty-state">票源当前没有符合活动状态的票。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 900px;">
                <thead>
                  <tr>
                    <th>票号</th>
                    <th>标题</th>
                    <th>票状态</th>
                    <th>代理状态</th>
                    <th>分类</th>
                    <th>更新时间</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.tracker.issues}>
                    <td>
                      <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                    </td>
                    <td><%= entry.title || "暂无" %></td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state || "暂无" %>
                      </span>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.runtime_status)}>
                        <%= runtime_status_label(entry.runtime_status) %>
                      </span>
                    </td>
                    <td><%= format_labels(entry.labels) %></td>
                    <td class="mono numeric"><%= entry.updated_at || "暂无" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">速率限制</h2>
              <p class="section-copy">显示最近一次可用的上游速率限制快照。</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">运行中的会话</h2>
              <p class="section-copy">活跃问题、最近的智能体动态及令牌用量。</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">当前没有活跃会话。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>问题</th>
                    <th>状态</th>
                    <th>会话</th>
                    <th>运行时长 / 轮次</th>
                    <th>Codex 动态</th>
                    <th>令牌</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON 详情</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="复制 ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = '已复制'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            复制 ID
                          </button>
                        <% else %>
                          <span class="muted">暂无</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "暂无")}
                        ><%= entry.last_message || to_string(entry.last_event || "暂无") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "暂无" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>总计：<%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">输入 <%= format_int(entry.tokens.input_tokens) %> / 输出 <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">已阻塞的会话</h2>
              <p class="section-copy">Codex 请求操作人员输入或批准后暂停的问题。</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">当前没有已阻塞的会话。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>问题</th>
                    <th>状态</th>
                    <th>会话</th>
                    <th>阻塞时间</th>
                    <th>最近更新</th>
                    <th>错误</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON 详情</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "已阻塞" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="复制 ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = '已复制'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          复制 ID
                        </button>
                      <% else %>
                        <span class="muted">暂无</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "暂无" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "暂无")}
                        ><%= entry.last_message || to_string(entry.last_event || "暂无") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "暂无" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "暂无" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">重试队列</h2>
              <p class="section-copy">等待下一次重试的问题。</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">当前没有等待重试的问题。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>问题</th>
                    <th>尝试次数</th>
                    <th>计划时间</th>
                    <th>错误</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON 详情</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "暂无" %></td>
                    <td><%= entry.error || "暂无" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"在问题跟踪系统中打开 #{@identifier}"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}分 #{secs}秒"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "暂无"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry", "waiting"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp tracker_source_label("backlog"), do: "Backlog"
  defp tracker_source_label("linear"), do: "Linear"
  defp tracker_source_label("jira"), do: "Jira"
  defp tracker_source_label("github"), do: "GitHub"
  defp tracker_source_label("gitlab"), do: "GitLab"
  defp tracker_source_label(_source), do: "票源"

  defp runtime_status_label("running"), do: "运行中"
  defp runtime_status_label("retrying"), do: "重试中"
  defp runtime_status_label("blocked"), do: "已阻塞"
  defp runtime_status_label(_status), do: "等待调度"

  defp format_labels(labels) when is_list(labels) and labels != [], do: Enum.join(labels, "、")
  defp format_labels(_labels), do: "暂无"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp localized_error_message(%{code: "snapshot_timeout"}), do: "获取状态快照超时"
  defp localized_error_message(%{code: "snapshot_unavailable"}), do: "状态快照不可用"
  defp localized_error_message(%{message: message}), do: message

  defp pretty_value(nil), do: "暂无"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
