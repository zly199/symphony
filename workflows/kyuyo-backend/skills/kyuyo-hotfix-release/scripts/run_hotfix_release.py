#!/usr/bin/env python3
"""Create kyuyo-backend hotfix branch and verify deployment via versions APIs."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ModeConfig:
    source_versions_url: str
    target_versions_url: str
    branch_prefix: str


MODE_CONFIG = {
    "staging-hotfix": ModeConfig(
        source_versions_url="https://kyuyo-staging.onehr.dev/kyuyo/api/versions",
        target_versions_url="https://kyuyo-staging-hotfix.onehr.dev/kyuyo/api/versions",
        branch_prefix="staging-hotfix",
    ),
    "hotfix": ModeConfig(
        source_versions_url="https://customer.onehr.tech/kyuyo/api/versions",
        target_versions_url="https://kyuyo-hotfix.onehr.dev/kyuyo/api/versions",
        branch_prefix="hotfix",
    ),
}


class HotfixError(RuntimeError):
    pass


def log(msg: str) -> None:
    print(msg, flush=True)


def run_git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    cmd = ["git", *args]
    proc = subprocess.run(
        cmd,
        cwd=str(repo),
        text=True,
        capture_output=True,
        check=False,
    )
    if check and proc.returncode != 0:
        raise HotfixError(
            f"git command failed: {' '.join(cmd)}\nstdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return proc


def fetch_versions(url: str, timeout: int) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.URLError as exc:
        raise HotfixError(f"Failed to call versions API {url}: {exc}") from exc

    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise HotfixError(f"Invalid JSON from {url}: {exc}") from exc

    product = payload.get("PRODUCT")
    if not isinstance(product, dict):
        raise HotfixError(f"Missing PRODUCT object in {url}")

    if not product.get("build"):
        raise HotfixError(f"Missing PRODUCT.build in {url}")
    if not product.get("branch"):
        raise HotfixError(f"Missing PRODUCT.branch in {url}")

    return payload


def build_branch_name(prefix: str, date_yyyymmdd: str | None) -> str:
    if date_yyyymmdd:
        try:
            dt.datetime.strptime(date_yyyymmdd, "%Y%m%d")
        except ValueError as exc:
            raise HotfixError(f"Invalid --date value: {date_yyyymmdd} (expected YYYYMMDD)") from exc
        date_text = date_yyyymmdd
    else:
        date_text = dt.datetime.now().strftime("%Y%m%d")
    return f"{prefix}-{date_text}"


def branch_exists_remote(repo: Path, branch: str) -> bool:
    proc = run_git(repo, "ls-remote", "--heads", "origin", branch, check=False)
    return proc.returncode == 0 and bool(proc.stdout.strip())


def create_remote_branch(repo: Path, commit_hash: str, branch: str) -> None:
    log(f"Creating remote branch origin/{branch} from commit {commit_hash}...")
    run_git(repo, "push", "origin", f"{commit_hash}:refs/heads/{branch}")


def wait_for_deploy(
    target_url: str,
    expected_build: str,
    expected_branch: str,
    timeout_sec: int,
    interval_sec: int,
    request_timeout_sec: int,
) -> None:
    deadline = time.time() + timeout_sec
    attempt = 0

    while time.time() <= deadline:
        attempt += 1
        payload = fetch_versions(target_url, timeout=request_timeout_sec)
        product = payload["PRODUCT"]
        actual_build = str(product.get("build", ""))
        actual_branch = str(product.get("branch", ""))

        log(
            "poll #{attempt}: target PRODUCT.build={build}, PRODUCT.branch={branch}".format(
                attempt=attempt,
                build=actual_build,
                branch=actual_branch,
            )
        )

        if actual_build == expected_build and actual_branch == expected_branch:
            log("Deployment verification succeeded.")
            return

        time.sleep(interval_sec)

    raise HotfixError(
        "Deployment verification timed out after {timeout}s. expected build={build}, branch={branch}".format(
            timeout=timeout_sec,
            build=expected_build,
            branch=expected_branch,
        )
    )


def validate_repo(repo: Path) -> None:
    if not repo.exists():
        raise HotfixError(f"Repository path does not exist: {repo}")
    if not (repo / ".git").exists():
        raise HotfixError(f"Not a git repository: {repo}")
    run_git(repo, "rev-parse", "--is-inside-work-tree")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create kyuyo-backend hotfix branch from source versions API build hash, "
            "then poll target environment until PRODUCT.build/branch matches."
        )
    )
    parser.add_argument(
        "--mode",
        required=True,
        choices=sorted(MODE_CONFIG.keys()),
        help="Release mode: staging-hotfix or hotfix.",
    )
    parser.add_argument(
        "--repo",
        default=".",
        help="Path to kyuyo-backend git repository. Default: current directory.",
    )
    parser.add_argument(
        "--date",
        help="Branch date in YYYYMMDD. Default: today in local timezone.",
    )
    parser.add_argument(
        "--timeout-sec",
        type=int,
        default=900,
        help="Max wait time for deployment verification. Default: 900.",
    )
    parser.add_argument(
        "--interval-sec",
        type=int,
        default=60,
        help="Polling interval for target versions API. Default: 60.",
    )
    parser.add_argument(
        "--request-timeout-sec",
        type=int,
        default=20,
        help="HTTP timeout per versions API request. Default: 20.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = Path(args.repo).resolve()

    try:
        validate_repo(repo)
        config = MODE_CONFIG[args.mode]
        branch_name = build_branch_name(config.branch_prefix, args.date)

        source_payload = fetch_versions(config.source_versions_url, timeout=args.request_timeout_sec)
        source_product = source_payload["PRODUCT"]
        base_hash = str(source_product["build"])

        log(
            "Source versions: PRODUCT.build={build}, PRODUCT.branch={branch}".format(
                build=source_product.get("build", ""),
                branch=source_product.get("branch", ""),
            )
        )
        log(f"Target branch name: {branch_name}")

        # Idempotent fast path: target env already has desired build and branch.
        target_payload = fetch_versions(config.target_versions_url, timeout=args.request_timeout_sec)
        target_product = target_payload["PRODUCT"]
        if (
            str(target_product.get("build", "")) == base_hash
            and str(target_product.get("branch", "")) == branch_name
        ):
            log(
                "Target environment already matches desired state; "
                "skip branch creation and pipeline waiting."
            )
            return 0

        log("Fetching latest refs from origin...")
        run_git(repo, "fetch", "origin", "--tags")

        # Ensure the commit hash exists locally before creating branch on remote.
        exists = run_git(repo, "cat-file", "-e", f"{base_hash}^{{commit}}", check=False)
        if exists.returncode != 0:
            raise HotfixError(
                f"Base commit {base_hash} not found after fetch. "
                "Check PRODUCT.build and repository remotes."
            )

        if branch_exists_remote(repo, branch_name):
            log(f"Remote branch origin/{branch_name} already exists; skip creation.")
        else:
            create_remote_branch(repo, base_hash, branch_name)
            log("Branch push finished; pipeline should be triggered by git push.")

        wait_for_deploy(
            target_url=config.target_versions_url,
            expected_build=base_hash,
            expected_branch=branch_name,
            timeout_sec=args.timeout_sec,
            interval_sec=args.interval_sec,
            request_timeout_sec=args.request_timeout_sec,
        )
        return 0
    except HotfixError as exc:
        log(f"[ERROR] {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
