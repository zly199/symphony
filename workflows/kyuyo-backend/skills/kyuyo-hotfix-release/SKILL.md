---
name: kyuyo-hotfix-release
description: Create kyuyo-backend hotfix release branches from PRODUCT.build returned by versions APIs, push branch to trigger CI/CD pipeline, and verify deployment by polling target versions APIs until PRODUCT.build and PRODUCT.branch match expectations. Use when the user asks to run staging hotfix (staging cp) or production hotfix (本番 cp) branch/deploy workflows.
---

# Kyuyo Hotfix Release

Automate branch creation and deployment verification for `kyuyo-backend` hotfix flows.

## Communication Language

- Always respond to the user in Chinese (Simplified).
- If the user includes Japanese terms (for example `本番 cp`), keep those terms as-is when needed, but all explanations and status updates must be in Chinese.

## Workflow

1. Determine mode:
- `staging-hotfix` (aka `staging cp`)
- `hotfix` (aka production / 本番 cp)

2. Read source versions API and extract `PRODUCT.build` as the base commit hash.

3. Build branch name:
- `staging-hotfix-YYYYMMDD` for `staging-hotfix`
- `hotfix-YYYYMMDD` for `hotfix`

4. Check target environment first:
- If target `PRODUCT.build` already equals expected hash **and** target `PRODUCT.branch` already equals expected branch name, log that it is already deployed and exit success.

5. Create branch on `origin` from the hash (push `hash -> refs/heads/<branch>`). This triggers pipeline.

6. Poll target versions API until both fields match or timeout:
- `PRODUCT.build == expected hash`
- `PRODUCT.branch == expected branch name`

## Script

Use `scripts/run_hotfix_release.py`.

```bash
python3 scripts/run_hotfix_release.py --mode staging-hotfix --repo /path/to/kyuyo-backend
python3 scripts/run_hotfix_release.py --mode hotfix --repo /path/to/kyuyo-backend
```

Options:
- `--date YYYYMMDD`: override branch date (default: local today)
- `--timeout-sec`: deployment wait timeout (default `900`)
- `--interval-sec`: poll interval (default `60`, recommended not lower than `60` to avoid API/security rate limiting)
- `--request-timeout-sec`: API timeout per request (default `20`)

## Endpoint Mapping

`staging-hotfix`:
- source: `https://kyuyo-staging.onehr.dev/kyuyo/api/versions`
- target: `https://kyuyo-staging-hotfix.onehr.dev/kyuyo/api/versions`
- branch prefix: `staging-hotfix`

`hotfix`:
- source: `https://customer.onehr.tech/kyuyo/api/versions`
- target: `https://kyuyo-hotfix.onehr.dev/kyuyo/api/versions`
- branch prefix: `hotfix`

## Execution Notes

- Run in an environment with git access to `kyuyo-backend` remote.
- Keep operation idempotent: if branch already exists or target already matches, do not fail.
- If a third hotfix type is needed later, extend `MODE_CONFIG` in `scripts/run_hotfix_release.py` with its source URL, target URL, and branch prefix.
