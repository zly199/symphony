# Personal Symphony Maintenance

This fork keeps the official Symphony history separate from long-lived personal
customizations.

## Primary development branch

`custom` is the primary development branch for this fork. The Backlog adapter and
all future personal changes are developed and maintained on this branch.

The active local development worktree is:

```bash
cd /Users/user/AI-base/symphony-custom
git branch --show-current
# custom
```

The `main` branch remains a clean synchronization baseline for the official
repository. It is maintained in a separate worktree and is not used for personal
development.

## Repository layout

| Item | Purpose |
| --- | --- |
| `upstream` | Official repository: `https://github.com/openai/symphony.git` |
| `origin` | Personal fork: `https://github.com/zly199/symphony.git` |
| `main` | Clean mirror of `upstream/main` |
| `custom` | Primary branch for the Backlog adapter and future personal changes |
| `/Users/user/symphony` | Local worktree for `main` |
| `/Users/user/AI-base/symphony-custom` | Local worktree for `custom` |

Keep personal development on `custom`. Use short-lived feature branches from
`custom` when a change needs isolated review.

## Sync the official repository

First update the clean `main` worktree:

```bash
git -C /Users/user/symphony fetch upstream
git -C /Users/user/symphony merge --ff-only upstream/main
git -C /Users/user/symphony push origin main
```

Then merge the official updates into the personal branch:

```bash
git -C /Users/user/AI-base/symphony-custom fetch upstream
git -C /Users/user/AI-base/symphony-custom merge upstream/main
git -C /Users/user/AI-base/symphony-custom push origin custom
```

Resolve any merge conflicts in the `custom` worktree, run the relevant tests,
and complete the merge commit before pushing.

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
cd /Users/user/AI-base/symphony-custom
git status
# edit and verify changes
git add <files>
git commit -m "<message>"
git push
```

The local Symphony dashboard remains available at
`http://127.0.0.1:4000` while the Backlog LaunchAgent is running.
