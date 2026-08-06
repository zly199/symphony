# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for open work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Lists it on the dashboard as `waiting`, where an operator starts the ones worth running
3. Creates a workspace per started issue
4. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
5. Sends a workflow prompt to Codex
6. Keeps Codex working on the issue until the work is done

During app-server sessions, the selected tracker adapter may advertise provider-native tools.
Linear serves `linear_graphql`, Backlog serves `backlog_api`, GitHub Issues serves `github_api`,
Jira Cloud serves `jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony
executes those tools with configured host-side auth and removes declared tracker-token environment
variables from the Codex child, so the agent does not need a second tracker login.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue, cleans up matching workspaces, and clears the issue's
dispatch gate record.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

### Intake, dispatch, and the operator gate

Intake and dispatch are separate decisions. Intake is every issue the tracker has not finished with —
anything outside `terminal_states` — so the dashboard shows the whole open board, not just the states
an agent may run in. Dispatch waits for the operator: each issue carries a gate status in
`dispatch_gate.json` in the state dir, and only `started` issues are dispatched.

- `waiting` (default, including issues Symphony has never seen): listed, never dispatched, no tokens
  spent.
- `started`: the dashboard's start action recorded a release. It also moves the tracker issue into the
  first entry of `active_states`, so the board reflects what is being worked on. That write is best
  effort and reported back to the operator; a tracker that refuses it leaves the run authorized.
- `paused`: the run in flight is stopped and the issue is held in a blocked entry with reason
  `operator_paused`. Tracker updates, retry timers, and restarts all leave it parked. Resuming returns
  it to `started` — not to `waiting` — because the work was already authorized.

Reaching a terminal state deletes the gate record, so a reopened issue waits for a fresh decision.

Because the operator's start and pause are the run signals, moving an issue between open tracker
states no longer stops an active run; only a terminal state, a routing change (assignee or required
labels), or a pause does.

Trackers that can express "not closed" natively answer intake directly (Backlog derives it from the
project's own status list; GitHub and GitLab are already scoped to open issues). Other adapters fall
back to reading the configured `active_states`, so on Linear, Jira, and Asana intake stays as narrow
as that list until their adapters gain a native open-issue read. `active_states` keeps two jobs
everywhere: its first entry is the state a started issue is moved into, and the whole list is the
intake fallback.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a credential for the selected tracker. For Linear, create a personal token via
   Settings → Security & access → Personal API keys and export `LINEAR_API_KEY`. For Backlog,
   create an API key under Personal Settings → API and export `BACKLOG_API_KEY`.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- `workspace.mode` defaults to `per_issue`, which creates
  `<workspace.root>/<workspace_key>`. The optional `existing` mode runs Codex directly in
  `workspace.root`, requires `agent.max_concurrent_agents: 1`, rejects SSH workers and
  `hooks.after_create`, and preserves that directory during terminal cleanup.
- The optional `worktree` mode gives every issue its own Git worktree at
  `<workspace.root>/<workspace_key>`, created from `workspace.repository`. It requires
  `workspace.repository`, rejects SSH workers, and leaves the source checkout untouched so it stays
  available for manual work. New worktrees are added detached at `workspace.base_ref`, which
  defaults to the first existing ref among `origin/HEAD`, `origin/main`, `origin/master`,
  `origin/develop`, and `origin/development`. Terminal cleanup runs `git worktree remove`, which
  keeps any worktree that still holds uncommitted work.
- Existing-workspace dispatch follows the ticket identifier in the current Git branch. A clean
  `main`, `master`, `develop`, or `development` branch can accept a new ticket. A ticket branch
  dispatches its matching active ticket. When that ticket leaves the active set, a clean branch
  can accept the next ticket while a branch with local changes pauses dispatch.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- For the Backlog adapter, `tracker.provider.api_key` reads from `BACKLOG_API_KEY` when unset or
  when value is `$BACKLOG_API_KEY`. Keep API keys in the host environment because Backlog
  authenticates API requests with an `apiKey` query parameter.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### Backlog adapter

- Config: use `tracker.kind: backlog` with required `tracker.provider.project_key`, explicit
  `active_states` and `terminal_states`, and one Backlog location:
  - `base_url` such as `https://example.backlog.com` or
    `https://example.backlog.com/api/v2`; it defaults to `BACKLOG_BASE_URL`.
  - `space` such as `example`; it defaults to `BACKLOG_SPACE` and resolves to
    `https://example.backlog.com/api/v2`.
  - `domain` such as `example.backlogtool.com`; it defaults to `BACKLOG_DOMAIN`.
  `api_key` defaults to `BACKLOG_API_KEY` and accepts `$VAR`. Optional `assignee_id` defaults to
  `BACKLOG_ASSIGNEE_ID` and limits candidates to that numeric Backlog user ID.
- Scope and paging: candidate reads resolve the configured project and project status list, map
  configured state names to Backlog status IDs, then page `/issues` in batches of 100. State
  matching ignores case and surrounding whitespace. ID refreshes use Backlog's immutable numeric
  issue ID, omit `404` records, and reject issues outside the configured project.
- Intake and state writes: the adapter answers intake natively by taking every project status that is
  not in `terminal_states`, so a new Backlog status enters Symphony without a config change. Starting
  an issue `PATCH`es `/issues/{issueKey}` with the status ID matching the first `active_states` entry;
  an unknown name fails with `{:backlog_unknown_status, name}`.
- Identity and normalization: `issue.id` is the numeric Backlog issue ID as a string and
  `issue.identifier` is the native issue key such as `PROJECT-123`. Category names become
  normalized Symphony labels, Backlog priority IDs remain integer priorities, and malformed
  timestamps become `nil`. Backlog does not expose a generic issue-dependency relation, so
  `blocked_by` remains empty.
- Tool and auth: `backlog_api` accepts `GET`, `POST`, `PATCH`, or `DELETE`, a relative API v2
  `path`, optional `query`, and optional form-encoded `form` fields. Symphony appends the API key
  host-side, rejects caller-supplied `apiKey` values, strips `BACKLOG_API_KEY` and configured
  `$VAR` token names from the Codex child, and keeps transport errors from echoing credential-bearing
  URLs. The raw tool can access any Backlog API resource allowed by the configured key, so use a
  dedicated least-privilege account in a trusted environment.
- Errors: configuration failures use `:invalid_backlog_base_url`, `:missing_backlog_api_key`,
  `:missing_backlog_project_key`, `:invalid_backlog_project_key`, or
  `:invalid_backlog_assignee_id`. Request failures use `{:backlog_api_status, status}` or
  `{:backlog_api_request, reason}`; malformed responses use `:backlog_unknown_payload`.

Example:

```yaml
tracker:
  kind: backlog
  provider:
    base_url: $BACKLOG_BASE_URL
    project_key: "PROJECT"
    api_key: $BACKLOG_API_KEY
    assignee_id: $BACKLOG_ASSIGNEE_ID
  required_labels: ["symphony"]
  active_states: ["Open", "In Progress"]
  terminal_states: ["Closed"]
```

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, strips `GITHUB_TOKEN` and
  configured `$VAR` token names from the Codex child, and leaves raw tool access limited by that
  token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps GitLab token env vars
  out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

### Run transcripts

Every Codex message of a run is appended to `<state_dir>/transcripts/<issue_id>/<timestamp>.jsonl`,
and the dashboard links it as 运行记录 on both the running and the blocked rows.

The activity column is a 25-entry ring of one-liners, which is the right shape for watching a run
and the wrong shape for explaining one. When a phase ends without publishing an artifact, the
transcript is what says whether the agent answered in prose instead of calling
`symphony_publish_artifact`, hit a failing command, or ran out of turns mid-thought.

- `/transcripts/<issue_id>` renders the newest run: agent messages, reasoning, commands and their
  exit codes, tool calls. Token and rate-limit bookkeeping is left out; unrecognised events are
  still shown raw, so a new app-server message can never make a run look empty.
- `/transcripts/<issue_id>?run=<name>` opens an earlier run; the 20 most recent are kept per issue.
- `/transcripts/<issue_id>?run=<name>&format=raw` returns the JSONL itself for grepping.
- `/api/v1/<issue_identifier>` lists every recorded run under `logs.codex_session_logs`.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
