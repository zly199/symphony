---
name: backlog-api
description: Connect to Nulab Backlog with API key authentication and run practical issue workflows such as listing projects, searching issues, and viewing issue details. Use when users ask to read Backlog project/task status, filter tickets by assignee or status, or prepare reports from Backlog data.
---

# Backlog API

Use this skill to execute repeatable Backlog read workflows through API key auth.

## Setup

Set environment variables before running scripts:

```bash
export BACKLOG_SPACE="your-space"         # e.g. myteam
export BACKLOG_API_KEY="xxxxxxxxxxxxxxxx"
```

Optional:

```bash
export BACKLOG_BASE_URL="https://your-space.backlog.com"
```

`BACKLOG_BASE_URL` overrides `BACKLOG_SPACE`.

If these environment variables are absent, the script automatically reads the
Backlog MCP environment from `~/.config/opencode/opencode.jsonc`.

## Script

Run `scripts/backlog_api.py` for common operations:

```bash
python3 scripts/backlog_api.py projects
python3 scripts/backlog_api.py issues --project-key APP --count 20
python3 scripts/backlog_api.py issues --project-key APP --updated-since 2026-07-09 --sort updated --order desc --count 100 --brief
python3 scripts/backlog_api.py issue --issue-key APP-123
python3 scripts/backlog_api.py comments --issue-key APP-123
python3 scripts/backlog_api.py comments --issue-key APP-123 --full
```

`comments` prints compact review-friendly fields by default. Use `--full` only
when notification details or raw changelog payloads are needed.

### Filters for issue search

- `--project-id` or `--project-key` (at least one is recommended; `--project-key` is
  resolved to a project id first, because `/issues` only accepts `projectId[]`)
- `--status-id` (repeatable)
- `--assignee-id`
- `--keyword`
- `--updated-since` / `--updated-until` / `--created-since` / `--created-until` (`yyyy-MM-dd`)
- `--sort` (`created` / `updated` / `issueType` / `status` / `priority` / `dueDate`) with `--order` (default `desc`)
- `--count` (default `20`, max `100`)
- `--offset` (default `0`)
- `--brief`: compact per-issue fields (key/summary/type/status/assignee/milestone/dates,
  description truncated at 400 chars). **Use it for any multi-issue sweep** — the raw payload
  is large enough to flood the context window.

## Workflow

1. Verify connectivity by calling `projects`.
2. Resolve target project key or project id.
3. Query issues with `issues` and narrow by status/assignee/keyword.
4. Fetch a single issue with `issue` for details when needed.

## Permission policy

- Treat `projects`, `issues`, `issue`, and other GET-only Backlog reads as safe read operations.
- Execute safe read operations directly without asking the user for extra permission when the request is only to inspect, search, or summarize Backlog data.
- Ask for explicit confirmation before any write or mutating action, including add/update/delete, status transitions, comments, attachments, or bulk changes.
- Keep new capabilities split by intent: add dedicated subcommands for write operations instead of overloading existing read commands.

## Output and Error Handling

- Script outputs pretty JSON to stdout.
- Missing environment variables fail fast with explicit guidance.
- HTTP non-2xx responses include status code and API error body.

## References

Read `references/backlog_api.md` when extending endpoints or adding parameters.
