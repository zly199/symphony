# Personal Symphony Maintenance

This fork keeps the official Symphony history separate from long-lived personal
customizations.

## Repository layout

| Item | Purpose |
| --- | --- |
| `upstream` | Official repository: `https://github.com/openai/symphony.git` |
| `origin` | Personal fork: `https://github.com/zly199/symphony.git` |
| `main` | Clean mirror of `upstream/main` |
| `custom` | Long-lived branch for the Backlog adapter and future personal changes |
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
