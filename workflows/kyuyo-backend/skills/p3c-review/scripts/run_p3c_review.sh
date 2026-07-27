#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run_p3c_review.sh [--paths <comma-separated-paths>] [--full] [--base-ref <git-ref>] [--mvn <mvn-cmd>]

Examples:
  run_p3c_review.sh
  run_p3c_review.sh --paths kyuyo-app/src/main/java,kyuyo-v1/src/main/java
  run_p3c_review.sh --base-ref origin/master
  run_p3c_review.sh --full
EOF
}

MVN_CMD="mvn"
TARGET_PATHS=""
FULL_SCAN="false"
BASE_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths)
      TARGET_PATHS="${2:-}"
      shift 2
      ;;
    --full)
      FULL_SCAN="true"
      shift
      ;;
    --base-ref)
      BASE_REF="${2:-}"
      shift 2
      ;;
    --mvn)
      MVN_CMD="${2:-mvn}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "pom.xml" ]]; then
  echo "[ERROR] pom.xml not found. Run this script from the Maven repository root." >&2
  exit 2
fi

if ! command -v "${MVN_CMD}" >/dev/null 2>&1; then
  echo "[ERROR] Maven command not found: ${MVN_CMD}" >&2
  exit 2
fi

if ! rg -n "ali-(comment|concurrent|constant|exception|flowcontrol|naming|ooh|orm|set|spring|unittest|other)" pom.xml >/dev/null 2>&1; then
  cat <<'EOF' >&2
[ERROR] Alibaba P3C PMD rules were not detected in pom.xml.
Please add a P3C-enabled PMD profile first (see references/p3c-maven-setup.md),
then re-run this script.
EOF
  exit 3
fi

collect_changed_java_files() {
  local merge_base
  local -a candidates
  local base="${BASE_REF}"

  if [[ -z "${base}" ]]; then
    if git rev-parse --abbrev-ref "@{upstream}" >/dev/null 2>&1; then
      base="$(git rev-parse --abbrev-ref "@{upstream}")"
    elif git show-ref --quiet refs/remotes/origin/master; then
      base="origin/master"
    elif git show-ref --quiet refs/remotes/origin/main; then
      base="origin/main"
    elif git show-ref --quiet refs/heads/master; then
      base="master"
    elif git show-ref --quiet refs/heads/main; then
      base="main"
    else
      base=""
    fi
  fi

  if [[ -n "${base}" ]]; then
    merge_base="$(git merge-base HEAD "${base}" 2>/dev/null || true)"
  else
    merge_base=""
  fi

  if [[ -n "${merge_base}" ]]; then
    mapfile -t candidates < <(
      {
        git diff --name-only --diff-filter=ACMR "${merge_base}"...HEAD
        git diff --name-only --cached --diff-filter=ACMR
        git diff --name-only --diff-filter=ACMR
      } | awk '/\.java$/ {print}' | sort -u
    )
    echo "[INFO] Auto scope: current branch changes (commits since ${base} + staged + unstaged)." >&2
  else
    mapfile -t candidates < <(
      {
        git diff --name-only --cached --diff-filter=ACMR
        git diff --name-only --diff-filter=ACMR
      } | awk '/\.java$/ {print}' | sort -u
    )
    echo "[WARN] Base branch not found; auto scope falls back to staged + unstaged changes only." >&2
  fi

  printf '%s\n' "${candidates[@]}"
}

if [[ -n "${TARGET_PATHS}" && "${FULL_SCAN}" == "false" ]]; then
  OLD_IFS="${IFS}"
  IFS=','
  read -r -a PATH_ARRAY <<< "${TARGET_PATHS}"
  IFS="${OLD_IFS}"
  INCLUDES=""
  for p in "${PATH_ARRAY[@]}"; do
    p_trimmed="$(echo "${p}" | sed 's#^[[:space:]]*##;s#[[:space:]]*$##')"
    if [[ -n "${p_trimmed}" ]]; then
      INCLUDES="${INCLUDES},${p_trimmed}/**/*.java"
    fi
  done
  INCLUDES="${INCLUDES#,}"
  PMD_ARGS=(-Dpmd.includes="${INCLUDES}")
elif [[ "${FULL_SCAN}" == "false" ]]; then
  mapfile -t CHANGED_JAVA_FILES < <(collect_changed_java_files)
  INCLUDES=""
  for f in "${CHANGED_JAVA_FILES[@]}"; do
    if [[ -n "${f}" ]]; then
      INCLUDES="${INCLUDES},${f}"
    fi
  done
  INCLUDES="${INCLUDES#,}"
  if [[ -z "${INCLUDES}" ]]; then
    echo "[INFO] No changed Java files found in current branch scope. Skip P3C scan."
    exit 0
  fi
  PMD_ARGS=(-Dpmd.includes="${INCLUDES}")
else
  PMD_ARGS=()
fi

echo "[INFO] Running Alibaba P3C PMD scan..."
echo "[INFO] Command: ${MVN_CMD} -DskipTests pmd:pmd pmd:check ${PMD_ARGS[*]:-}"

set +e
"${MVN_CMD}" -DskipTests pmd:pmd pmd:check "${PMD_ARGS[@]}"
EXIT_CODE=$?
set -e

REPORT_XML="$(find . -path "*/target/pmd.xml" | head -n 1 || true)"
REPORT_HTML="$(find . -path "*/target/site/pmd.html" | head -n 1 || true)"

if [[ -n "${REPORT_XML}" ]]; then
  echo "[INFO] XML report: ${REPORT_XML}"
fi
if [[ -n "${REPORT_HTML}" ]]; then
  echo "[INFO] HTML report: ${REPORT_HTML}"
fi

if [[ ${EXIT_CODE} -ne 0 ]]; then
  echo "[WARN] P3C scan found violations or build-level errors (exit=${EXIT_CODE})."
  echo "[WARN] Review reports above and prioritize priority 1/2 findings."
  exit ${EXIT_CODE}
fi

echo "[OK] P3C scan completed without blocking violations."
