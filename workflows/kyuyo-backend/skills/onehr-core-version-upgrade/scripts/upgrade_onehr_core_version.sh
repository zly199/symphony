#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  upgrade_onehr_core_version.sh --version <onehr-core.version> --name <branch name source> [--base master] [--remote origin] [--pom pom.xml]

Description:
  1. Sync local <base> to latest <remote>/<base> (fast-forward only).
  2. Create a sanitized feature branch: feat/<sanitized-name>.
  3. Update <onehr-core.version> in pom.xml.
  4. Commit and push branch to remote.

Examples:
  ./scripts/upgrade_onehr_core_version.sh \
    --version 3.8.2.0 \
    --name 'KYUYO_NEW-4008 【backend】Coreバージョンは毎週アップグレードされます'
USAGE
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

sanitize_branch_name() {
  local raw="$1"
  local slug

  # Preserve Unicode letters (e.g. Japanese), remove only Git-invalid ref chars.
  slug="$(printf '%s' "$raw" | sed -E \
    -e 's/[[:space:]]+/-/g' \
    -e 's#/#-#g' \
    -e 's/[~^:?*\\\[]+/-/g' \
    -e 's/@\{/-/g' \
    -e 's/\.\.+/-/g' \
    -e 's/-+/-/g' \
    -e 's/^[.-]+//' \
    -e 's/[.-]+$//')"

  if [[ -z "$slug" ]]; then
    slug="core-version-upgrade-$(date +%Y%m%d%H%M%S)"
  fi

  if [[ "$slug" == *.lock ]]; then
    slug="${slug%.lock}-lock"
  fi

  printf 'feat/%s' "$slug"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

new_version=""
branch_source_name=""
base_branch="master"
remote_name="origin"
pom_file="pom.xml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "Missing value for --version"
      new_version="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || fail "Missing value for --name"
      branch_source_name="$2"
      shift 2
      ;;
    --base)
      [[ $# -ge 2 ]] || fail "Missing value for --base"
      base_branch="$2"
      shift 2
      ;;
    --remote)
      [[ $# -ge 2 ]] || fail "Missing value for --remote"
      remote_name="$2"
      shift 2
      ;;
    --pom)
      [[ $# -ge 2 ]] || fail "Missing value for --pom"
      pom_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$new_version" ]] || fail "--version is required"
[[ -n "$branch_source_name" ]] || fail "--name is required"
[[ -f "$pom_file" ]] || fail "POM file not found: $pom_file"

require_cmd git
require_cmd sed
require_cmd awk

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Current directory is not a git repository"

if [[ -n "$(git status --porcelain)" ]]; then
  fail "Working tree is not clean. Commit or stash changes first."
fi

feature_branch="$(sanitize_branch_name "$branch_source_name")"
git check-ref-format --branch "$feature_branch" >/dev/null 2>&1 || fail "Generated branch is invalid: $feature_branch"

echo "[INFO] Target branch: $feature_branch"
echo "[INFO] Target onehr-core.version: $new_version"

echo "[STEP] Fetching latest $remote_name/$base_branch"
git fetch "$remote_name" "$base_branch"

echo "[STEP] Switching to local $base_branch"
git switch "$base_branch" >/dev/null 2>&1 || git checkout "$base_branch"

echo "[STEP] Fast-forwarding local $base_branch"
git pull --ff-only "$remote_name" "$base_branch"

if git show-ref --verify --quiet "refs/heads/$feature_branch"; then
  fail "Local branch already exists: $feature_branch"
fi

if git ls-remote --heads "$remote_name" "$feature_branch" | grep -q .; then
  fail "Remote branch already exists: $feature_branch"
fi

echo "[STEP] Creating branch $feature_branch"
git switch -c "$feature_branch"

current_version="$(sed -n 's/.*<onehr-core.version>\([^<]*\)<\/onehr-core.version>.*/\1/p' "$pom_file" | head -n 1)"
[[ -n "$current_version" ]] || fail "Unable to find <onehr-core.version> in $pom_file"

echo "[INFO] Current onehr-core.version: $current_version"

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

awk -v version="$new_version" '
BEGIN { updated = 0 }
{
  if (updated == 0 && $0 ~ /<onehr-core\.version>[^<]*<\/onehr-core\.version>/) {
    sub(/<onehr-core\.version>[^<]*<\/onehr-core\.version>/, "<onehr-core.version>" version "</onehr-core.version>")
    updated = 1
  }
  print
}
END {
  if (updated == 0) {
    exit 2
  }
}
' "$pom_file" > "$tmp_file" || fail "Failed to update <onehr-core.version> in $pom_file"

mv "$tmp_file" "$pom_file"
trap - EXIT

git add "$pom_file"
if git diff --cached --quiet; then
  fail "No changes detected after version update."
fi

echo "[STEP] Committing changes"
git commit -m "chore: bump onehr-core.version to $new_version"

echo "[STEP] Pushing branch to $remote_name"
git push -u "$remote_name" "$feature_branch"

echo "[DONE] Branch pushed successfully: $feature_branch"
