# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

## 本地启停（macOS LaunchAgent）

本机的 Backlog 编排进程由 LaunchAgent `com.openai.symphony.backlog` 托管
（plist 在 `~/Library/LaunchAgents/`，配置了 `KeepAlive`，所以直接 `kill` 进程会被自动拉起，
必须用下面的 `launchctl` 命令来启停）。

**启动：**

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openai.symphony.backlog.plist
```

**关闭：**

```bash
launchctl bootout gui/$(id -u)/com.openai.symphony.backlog
```

**源码更新后重新编译：**

```bash
./compile_symphony_backlog.sh
```

编译完成后，重新启动 LaunchAgent：

```bash
launchctl bootout gui/$(id -u)/com.openai.symphony.backlog 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openai.symphony.backlog.plist
```

**查看是否在跑**（有输出即在跑，第一列是 PID）：

```bash
launchctl list | grep symphony
```

说明：

- 启动后 dashboard 在 <http://127.0.0.1:4000>；确认端口是否被占用：`lsof -nP -iTCP:4000 -sTCP:LISTEN`
- **调度是手动的**：票源里所有未关闭（不在 `terminal_states` 里）的票都会进入 Symphony，默认停在「等待调度」——
  不派发、不起 Codex、不花 token。在 dashboard 的票列表点「开始调度」才会真正开跑，同时把票源状态改成
  `active_states` 的第一项（Backlog 配置里是 `In Progress`）。票源状态改失败不影响本地开跑，dashboard 会提示。
  决定持久化在 `var/dispatch_gate.json`，编排重启后仍然有效；票进入终态后记录会被清掉，重新打开的票会回到「等待调度」。
- **每个停下来的关口都有两个出口**：一个向前推进的按钮，一个写意见打回的输入框。意见持久化在
  `var/operator_feedback.json`，并随下一轮提示词交给 Codex，重跑的是这一关对应的阶段。
  票在「已阻塞」区依次经过这些关口：
  - 系分产出后 → 点「批准继续」进入编码；或写意见打回，重跑系分。
  - 编码完成、CI 变绿、MR 已开后（Codex 调用 `symphony_handoff_for_review`）→ 点「Review 通过，生成 MR 总结」，
    Codex 会用 `git-mr-summary` skill 生成固定两段式中文 MR 描述（设计思想段末尾带 MR 地址）并写回 MR；
    或写意见打回，回到编码阶段改代码、amend、重推、重跑 CI，**系分批准不会因此作废**。
  - MR 总结产出后 → 点「确认完成」，Symphony 不再推进，合并 MR 与关票由人工完成；或写意见打回，重新生成总结。
  - Codex 请求输入、连续多轮无进展等其他阻塞，同样是「继续推进」加意见框，重跑当前阶段。
  阶段决定持久化在 `var/approvals.json`（系分批准与 review 批准各记一次）。
- 推进不下去的票可以点「暂停推进」（票列表和已阻塞区都有）：正在跑的会话会被立刻停掉，票一直停在「已阻塞」区，
  票源里再有更新、重试到点、编排重启都不会把它放出来，只有点「恢复推进」才会重新排期（恢复后不需要再点一次「开始调度」）。
  工作区（worktree）保持原样不删。
- 日志：`var/launchd.stdout.log`、`var/launchd.stderr.log`
- `bootout` 只对当前登录会话生效。plist 带 `RunAtLoad`，**重启或重新登录后仍会自动启动**。
  想彻底禁用（之后需用 `launchctl enable` 才能再启动）：
  `launchctl disable gui/$(id -u)/com.openai.symphony.backlog`
- 编排进程会派生 codex 子进程树，`bootout` 会把整棵树一起收掉。

---

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

### Maintaining this personal fork

See [CUSTOMIZATION.md](CUSTOMIZATION.md) for the branch model, local worktree layout, and commands
for syncing updates from the official Symphony repository.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
