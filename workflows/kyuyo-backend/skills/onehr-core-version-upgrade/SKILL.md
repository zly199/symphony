---
name: onehr-core-version-upgrade
description: Upgrade Maven onehr-core.version in kyuyo-backend with a repeatable git workflow. Use when the user provides a latest onehr-core.version and a branch title/name, and wants Codex to sync master, create a sanitized feat/* branch, update pom.xml, commit, and push to remote.
---

# Onehr Core Version Upgrade

Execute the script from the `kyuyo-backend` repository root:

```bash
/Users/user/symphony/workflows/kyuyo-backend/skills/onehr-core-version-upgrade/scripts/upgrade_onehr_core_version.sh \
  --version <latest-onehr-core.version> \
  --name '<branch title or ticket text>'
```

The script performs the following sequence:

1. Ensure git working tree is clean.
2. Fetch and fast-forward local `master` from `origin/master`.
3. Sanitize the user-provided name and create `feat/<sanitized-name>`.
4. Update `<onehr-core.version>` in `pom.xml`.
5. Commit with `chore: bump onehr-core.version to <version>`.
6. Push branch with upstream to `origin`.

## Parameters

- `--version` (required): New value for `<onehr-core.version>`.
- `--name` (required): Source text for branch name; spaces become , and only Git-invalid ref characters are removed.-`.
- `--base` (optional): Base branch, default `master`.
- `--remote` (optional): Remote name, default `origin`.
- `--pom` (optional): Target pom file, default `pom.xml`.

## Edge Cases and Safety

- Stop if working tree is dirty.
- Stop if `feat/<sanitized-name>` already exists locally or remotely.
- Stop if `<onehr-core.version>` is not found in the target pom.
- Stop if update yields no effective file change.
