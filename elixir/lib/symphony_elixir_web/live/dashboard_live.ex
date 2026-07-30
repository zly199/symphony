defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{AnalysisDocController, Endpoint, ObservabilityPubSub, Presenter}
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
  def handle_event("approve_analysis", %{"issue-id" => issue_id, "identifier" => identifier}, socket) do
    socket =
      case Orchestrator.approve_analysis(issue_id, identifier: identifier, approved_by: "dashboard") do
        {:ok, _record} ->
          socket
          |> put_flash(:info, "已批准 #{identifier}，将进入编码阶段。")
          |> assign(:payload, load_payload())

        {:error, reason} ->
          put_flash(socket, :error, "批准 #{identifier} 失败：#{inspect(reason)}")

        :unavailable ->
          put_flash(socket, :error, "编排器未运行，无法批准 #{identifier}。")
      end

    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("request_analysis_revision", %{"issue-id" => issue_id, "identifier" => identifier} = params, socket) do
    note = Map.get(params, "note")

    socket =
      case Orchestrator.request_analysis_revision(issue_id,
             note: note,
             identifier: identifier,
             requested_by: "dashboard"
           ) do
        {:ok, _note} ->
          socket
          |> put_flash(:info, "已记录 #{identifier} 的修改意见，系分将带着它重跑。")
          |> assign(:payload, load_payload())

        {:error, :empty_note} ->
          put_flash(socket, :error, "请先填写需要修改的内容，再打回 #{identifier}。")

        {:error, reason} ->
          put_flash(socket, :error, "记录 #{identifier} 的修改意见失败：#{inspect(reason)}")

        :unavailable ->
          put_flash(socket, :error, "编排器未运行，无法打回 #{identifier}。")
      end

    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("start_issue", %{"issue-id" => issue_id, "identifier" => identifier}, socket) do
    socket =
      case Orchestrator.start_issue(issue_id, identifier: identifier, updated_by: "dashboard") do
        {:ok, record} ->
          socket
          |> put_flash(:info, start_flash(identifier, record))
          |> assign(:payload, load_payload())

        {:error, reason} ->
          put_flash(socket, :error, "开始调度 #{identifier} 失败：#{inspect(reason)}")

        :unavailable ->
          put_flash(socket, :error, "编排器未运行，无法调度 #{identifier}。")
      end

    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("pause_issue", %{"issue-id" => issue_id, "identifier" => identifier}, socket) do
    socket =
      case Orchestrator.pause_issue(issue_id, identifier: identifier, paused_by: "dashboard") do
        {:ok, _record} ->
          socket
          |> put_flash(:info, "已暂停 #{identifier}，在恢复之前不再派发。")
          |> assign(:payload, load_payload())

        {:error, reason} ->
          put_flash(socket, :error, "暂停 #{identifier} 失败：#{inspect(reason)}")

        :unavailable ->
          put_flash(socket, :error, "编排器未运行，无法暂停 #{identifier}。")
      end

    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("resume_issue", %{"issue-id" => issue_id, "identifier" => identifier}, socket) do
    socket =
      case Orchestrator.resume_issue(issue_id, identifier: identifier) do
        {:ok, _record} ->
          socket
          |> put_flash(:info, "已恢复 #{identifier}，下一轮轮询会重新派发。")
          |> assign(:payload, load_payload())

        {:error, reason} ->
          put_flash(socket, :error, "恢复 #{identifier} 失败：#{inspect(reason)}")

        :unavailable ->
          put_flash(socket, :error, "编排器未运行，无法恢复 #{identifier}。")
      end

    {:noreply, assign(socket, :now, DateTime.utc_now())}
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
            <p class="metric-label"><%= tracker_source_label(@payload.tracker.source) %> 待处理票</p>
            <p class="metric-value numeric"><%= @payload.counts.tracker_active %></p>
            <p class="metric-detail">票源中尚未关闭、已进入 Symphony 的票数。</p>
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
            <p class="metric-label">等待调度</p>
            <p class="metric-value numeric"><%= @payload.counts.waiting %></p>
            <p class="metric-detail">已进入 Symphony、等待手动开始的票数。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">已暂停</p>
            <p class="metric-value numeric"><%= @payload.counts.paused %></p>
            <p class="metric-detail">已手动暂停、恢复前不再派发的问题数。</p>
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
              <h2 class="section-title"><%= tracker_source_label(@payload.tracker.source) %> 待处理票</h2>
              <p class="section-copy">
                票源里所有未关闭的票都会进来，默认停在「等待调度」，不跑、不花 token。
                点「开始调度」才会真正派发，同时把票源状态改成 <%= start_state_label(@payload.tracker.active_states) %>。
                推进不下去的票可以「暂停推进」：会停掉正在跑的会话，并一直停在已阻塞区，直到手动「恢复推进」。
                <%= if @payload.tracker.synced_at do %>
                  最近同步：<span class="mono numeric"><%= @payload.tracker.synced_at %></span>
                <% end %>
              </p>
            </div>
          </div>

          <%= if @payload.tracker.issues == [] do %>
            <p class="empty-state">票源当前没有未关闭的票。</p>
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
                    <th>操作</th>
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
                    <td>
                      <.gate_actions
                        issue_id={entry.issue_id}
                        identifier={entry.issue_identifier}
                        run_status={entry.run_status}
                      />
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
                        <.analysis_doc_link identifier={entry.issue_identifier} />
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
                      <.codex_activity entry={entry} />
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
              <p class="section-copy">
                等待人工处理的问题：系分已产出待批准、Codex 请求输入、连续多轮无进展，或被手动暂停。
                系分文档可以直接批准，也可以写下修改意见打回；意见会随下一轮系分交给 Codex。
                已暂停的票会一直停在这里，只有点「恢复推进」才会重新排期。
              </p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">当前没有已阻塞的会话。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 1040px;">
                <thead>
                  <tr>
                    <th>问题</th>
                    <th>状态</th>
                    <th>会话</th>
                    <th>阻塞时间</th>
                    <th>最近更新</th>
                    <th>原因</th>
                    <th>操作</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <.analysis_doc_link identifier={entry.issue_identifier} />
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
                      <.codex_activity entry={entry} />
                    </td>
                    <td><%= entry.error || "暂无" %></td>
                    <td>
                      <div class="action-stack">
                        <.gate_actions
                          issue_id={entry.issue_id}
                          identifier={entry.issue_identifier}
                          run_status={entry.run_status}
                        />
                        <%= if entry.run_status != :paused do %>
                          <.analysis_gate_actions entry={entry} />
                        <% end %>
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

  attr(:identifier, :string, required: true)

  # The analysis document lives inside the ticket's worktree, so it is invisible
  # from the operator's own checkout until the branch merges. This link opens it
  # in place.
  defp analysis_doc_link(assigns) do
    assigns = assign(assigns, :exists, AnalysisDocController.doc_exists?(assigns.identifier))

    ~H"""
    <%= if @exists do %>
      <a
        class="issue-link doc-link"
        href={AnalysisDocController.doc_path(@identifier)}
        target="_blank"
        rel="noopener noreferrer"
      >系分文档 ↗</a>
    <% end %>
    """
  end

  attr(:issue_id, :string, required: true)
  attr(:identifier, :string, required: true)
  attr(:run_status, :atom, default: :waiting)

  # One control per row, showing the only move that makes sense for where the item
  # is: start it, pause it, or pick it back up. Every row carries it, because a
  # ticket stops being worth pushing at any point in its run — including after a
  # restart, which is why a paused row still offers the way back out.
  defp gate_actions(assigns) do
    ~H"""
    <%= if @run_status == :waiting do %>
      <button
        type="button"
        class="start-button"
        phx-click="start_issue"
        phx-value-issue-id={@issue_id}
        phx-value-identifier={@identifier}
        data-confirm={"开始调度 #{@identifier}？Codex 会开始跑并消耗 token。"}
      >
        开始调度
      </button>
    <% end %>

    <%= if @run_status == :paused do %>
      <button
        type="button"
        class="resume-button"
        phx-click="resume_issue"
        phx-value-issue-id={@issue_id}
        phx-value-identifier={@identifier}
      >
        恢复推进
      </button>
    <% end %>

    <%= if @run_status == :started do %>
      <button
        type="button"
        class="pause-button"
        phx-click="pause_issue"
        phx-value-issue-id={@issue_id}
        phx-value-identifier={@identifier}
        data-confirm={"暂停 #{@identifier}？正在跑的会话会被停掉，恢复前不再派发。"}
      >
        暂停推进
      </button>
    <% end %>
    """
  end

  attr(:entry, :map, required: true)

  # A gated analysis needs both answers, not just "approve": rejecting it without
  # saying what is wrong would send the same document back for another pass. The
  # note travels into the next run's prompt, so this form is the operator's way of
  # talking to the agent.
  defp analysis_gate_actions(assigns) do
    assigns =
      assigns
      |> assign(:gated, assigns.entry.block_reason in [:awaiting_analysis_approval, :analysis_incomplete])
      |> assign(:approvable, assigns.entry.block_reason == :awaiting_analysis_approval)
      |> assign(:feedback, Map.get(assigns.entry, :analysis_feedback, []))

    ~H"""
    <%= if @gated do %>
      <div class="action-stack">
        <%= if @approvable do %>
          <button
            type="button"
            class="approve-button"
            phx-click="approve_analysis"
            phx-value-issue-id={@entry.issue_id}
            phx-value-identifier={@entry.issue_identifier}
            data-confirm={"批准 #{@entry.issue_identifier} 进入编码阶段？"}
          >
            批准继续
          </button>
        <% end %>

        <form class="revision-form" phx-submit="request_analysis_revision">
          <input type="hidden" name="issue-id" value={@entry.issue_id} />
          <input type="hidden" name="identifier" value={@entry.issue_identifier} />
          <textarea
            class="revision-input"
            name="note"
            rows="3"
            required
            placeholder="写下系分文档需要修正的地方，将随下一轮系分交给 Codex"
          ></textarea>
          <button type="submit" class="revision-button">打回修改</button>
        </form>

        <%= if @feedback != [] do %>
          <details class="feedback-history">
            <summary>已提交意见 <%= length(@feedback) %> 条</summary>
            <ol class="feedback-list">
              <li :for={note <- @feedback}>
                <span class="event-text"><%= note.note %></span>
                <span class="muted event-meta mono numeric">
                  <%= note.requested_at %> · <%= if note.delivered, do: "已交给系分", else: "待下一轮系分" %>
                </span>
              </li>
            </ol>
          </details>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr(:entry, :map, required: true)

  # The last raw event is almost always rate-limit or token bookkeeping, so the
  # trail of substantive events is what tells an operator what the agent did.
  defp codex_activity(assigns) do
    assigns = assign(assigns, :events, Enum.take(Map.get(assigns.entry, :recent_events, []), 6))

    ~H"""
    <div class="detail-stack">
      <%= if @events == [] do %>
        <span class="event-text muted">暂无动态</span>
      <% else %>
        <ol class="activity-trail">
          <li :for={event <- @events}>
            <span class="event-text" title={event.message || to_string(event.event || "")}><%= event.message || to_string(event.event || "暂无") %></span>
            <%= if event.at do %>
              <span class="muted event-meta mono numeric"><%= event.at %></span>
            <% end %>
          </li>
        </ol>
      <% end %>
    </div>
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

      String.contains?(normalized, ["todo", "queued", "pending", "retry", "waiting", "paused"]) ->
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
  defp runtime_status_label("paused"), do: "已暂停"
  defp runtime_status_label("queued"), do: "排队中"
  defp runtime_status_label(_status), do: "等待调度"

  # The tracker write can fail while the start itself holds, so the flash says which
  # of the two happened instead of a flat "done".
  defp start_flash(identifier, %{tracker_state: {:ok, state_name}}) do
    "已开始调度 #{identifier}，票源状态已改为 #{state_name}。"
  end

  defp start_flash(identifier, %{tracker_state: {:error, reason}}) do
    "已开始调度 #{identifier}，但票源状态未能更新（#{inspect(reason)}），请手动确认。"
  end

  defp start_state_label(active_states) when is_list(active_states) do
    Enum.find(active_states, "进行中", &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp start_state_label(_active_states), do: "进行中"

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
