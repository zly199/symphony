# Personal Symphony Maintenance

This fork keeps the official Symphony history separate from long-lived personal
customizations.

## Primary development branch

`custom` is the primary development branch for this fork. The Backlog adapter and
all future personal changes are developed and maintained on this branch.

The active local development worktree is:

```bash
cd /Users/user/symphony
git branch --show-current
# custom
```

The `main` branch remains a synchronization baseline for the official repository.
It does not need a separate local worktree because the official commit can be
pushed directly from `upstream/main` to `origin/main`.

## Repository layout

| Item | Purpose |
| --- | --- |
| `upstream` | Official repository: `https://github.com/openai/symphony.git` |
| `origin` | Personal fork: `https://github.com/zly199/symphony.git` |
| `main` | Clean mirror of `upstream/main` |
| `custom` | Primary branch for the Backlog adapter and future personal changes |
| `/Users/user/symphony` | The only local worktree, checked out on `custom` |
| `workflows/kyuyo-backend/` | Versioned kyuyo ticket workflow, skills, evals, and memory procedures |
| `/Users/user/IdeaProjects/kyuyo-backend` | Existing repository used by the Backlog workflow |

Keep personal development on `custom`. Use short-lived feature branches from
`custom` when a change needs isolated review.

## Sync the official repository

Fetch both repositories and update the fork's clean `main` reference:

```bash
cd /Users/user/symphony
git fetch upstream main
git fetch origin main custom
git merge-base --is-ancestor origin/main upstream/main
git push origin upstream/main:main
```

Then merge the official updates into the primary branch:

```bash
git merge upstream/main
git push origin custom
```

Resolve any merge conflicts, run the relevant tests, and complete the merge
commit before pushing.

## Weekly automatic synchronization

The Codex task `Weekly Symphony upstream sync` runs every Monday at 09:00
Asia/Tokyo.

Each run:

1. Verifies that the `custom` worktree is clean and matches `origin/custom`.
2. Fetches the latest branches from `upstream` and `origin`.
3. Verifies that `origin/main` can fast-forward to `upstream/main`.
4. Pushes the official `upstream/main` commit directly to `origin/main`.
5. Merges `upstream/main` into the primary `custom` branch.
6. Runs the relevant Elixir formatting and test checks.
7. Pushes a successful update to `origin/custom`.

The task stops and reports the problem when it finds local changes, merge
conflicts, or failed validation. It never force-pushes and does not discard local
work.

## Daily development

```bash
cd /Users/user/symphony
git status
# edit and verify changes
git add <files>
git commit -m "<message>"
git push
```

The local Symphony dashboard remains available at
`http://127.0.0.1:4000` while the Backlog LaunchAgent is running.

The Backlog workflow uses `workspace.mode: worktree`. Each ticket runs in its own Git worktree
under `/Users/user/IdeaProjects/kyuyo-worktrees`, created from `origin/master` of
`/Users/user/IdeaProjects/kyuyo-backend`. The source checkout keeps its own branch and working tree,
so it stays free for manual work while an agent runs. A worktree is removed only when its ticket
reaches a terminal state and it holds no uncommitted work.
