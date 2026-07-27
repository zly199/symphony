# Backlog API Reference (Minimal)

## Authentication

- Use API key query parameter: `apiKey=...`
- Preferred base URL: `https://<space>.backlog.com/api/v2`

## Endpoints used by this skill

- `GET /projects`
  - List projects visible to the API key user.

- `GET /issues`
  - Common query parameters:
  - `projectId[]`
  - `projectKey[]`
  - `statusId[]`
  - `assigneeId[]`
  - `keyword`
  - `count` (1..100)
  - `offset` (>= 0)

- `GET /issues/{issueKey}`
  - Fetch one issue by key (example `APP-123`).

## Notes for extension

- Keep GET-only read operations default and safe; do not require an extra permission prompt when the user is only asking to inspect or summarize Backlog data.
- To support write operations, add dedicated subcommands and require explicit confirmation before mutating data.
- Do not mix read and write semantics in one subcommand.
