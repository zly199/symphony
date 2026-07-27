# kyuyo-backend Workflow Assets

This directory is the source of truth for kyuyo-backend agent execution policy.

## Ownership

- `../../WORKFLOW.backlog.md`: runtime configuration and the unattended Backlog ticket prompt.
- `AGENT_WORKFLOW.md`: ticket execution, memory, documentation, review, release, and retrospective workflow.
- `skills/`: kyuyo-specific executable workflows.
- `evals/`: workflow behavior regression cases.
- `memory/`: durable-memory ingestion procedures.
- `retro_history.md`: workflow-governance audit history.

The kyuyo-backend repository owns product knowledge and code rules:

- `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/governance/KYUYO_DOMAIN.md`
- `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/governance/CODING_RULES.md`
- `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/docs/`

Ticket execution runs in the existing repository at
`/Users/user/IdeaProjects/kyuyo-backend`. Symphony must preserve that directory during terminal
ticket cleanup.
