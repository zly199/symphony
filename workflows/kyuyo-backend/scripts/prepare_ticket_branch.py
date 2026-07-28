#!/usr/bin/env python3
"""Prepare a kyuyo-backend ticket branch from the latest origin/master."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


BASE_BRANCH = "master"
REMOTE = "origin"
MAX_COMPONENT_BYTES = 240
BUG_NATURES = {"bug", "バグ", "不具合", "障害"}
DOC_NATURES = {
    "ci",
    "ci/cd",
    "doc",
    "docs",
    "document",
    "documentation",
    "文档",
    "文書",
    "ドキュメント",
    "設計書",
}


class BranchPreparationError(RuntimeError):
    """Raised when the repository cannot be prepared safely."""


def normalize_nature(value: str) -> str:
    return re.sub(r"[\W_]+", "", value, flags=re.UNICODE).casefold()


def branch_scope(natures: list[str]) -> str:
    normalized = {normalize_nature(value) for value in natures if value.strip()}
    normalized_bug = {normalize_nature(value) for value in BUG_NATURES}
    normalized_doc = {normalize_nature(value) for value in DOC_NATURES}

    if normalized & normalized_bug:
        return "fix"
    if normalized & normalized_doc:
        return "doc"
    return "feat"


def truncate_utf8(value: str, max_bytes: int) -> str:
    encoded = value.encode("utf-8")
    if len(encoded) <= max_bytes:
        return value
    return encoded[:max_bytes].decode("utf-8", errors="ignore")


def sanitize_branch_component(value: str) -> str:
    component = re.sub(r"\s+", "-", value.strip())
    component = re.sub(r"[\x00-\x20\x7f~^:?*\\/\[\]]+", "-", component)
    component = component.replace("@{", "-")

    while ".." in component:
        component = component.replace("..", "-")

    component = re.sub(r"-+", "-", component)
    component = component.strip(".-")

    if component.casefold().endswith(".lock"):
        component = f"{component[:-5]}-lock"

    return component


def build_branch_name(ticket: str, title: str, natures: list[str]) -> str:
    safe_ticket = sanitize_branch_component(ticket)
    safe_title = sanitize_branch_component(title)
    if not safe_ticket:
        raise BranchPreparationError("Ticket identifier is empty after sanitization")

    component = safe_ticket if not safe_title else f"{safe_ticket}-{safe_title}"
    component = truncate_utf8(component, MAX_COMPONENT_BYTES).rstrip(".-")
    if not component:
        raise BranchPreparationError("Branch component is empty after sanitization")

    branch = f"{branch_scope(natures)}/{component}"
    validate = subprocess.run(
        ["git", "check-ref-format", "--branch", branch],
        text=True,
        capture_output=True,
        check=False,
    )
    if validate.returncode != 0:
        raise BranchPreparationError(f"Generated branch name is invalid: {branch}")
    return branch


def run_git(repo: Path, *args: str, capture: bool = False) -> str:
    command = ["git", "-C", str(repo), *args]
    result = subprocess.run(
        command,
        text=True,
        capture_output=capture,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() if capture else ""
        suffix = f": {detail}" if detail else ""
        raise BranchPreparationError(f"Git command failed: {' '.join(command)}{suffix}")
    return result.stdout.strip() if capture else ""


def ref_exists(repo: Path, ref: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), "show-ref", "--verify", "--quiet", ref],
        check=False,
    )
    return result.returncode == 0


def contains_ticket(branch: str, ticket: str) -> bool:
    pattern = rf"(?<![A-Z0-9_]){re.escape(ticket)}(?!\d)"
    return re.search(pattern, branch, flags=re.IGNORECASE) is not None


def prepare_branch(repo: Path, ticket: str, branch: str) -> str:
    if not repo.is_dir():
        raise BranchPreparationError(f"Repository directory does not exist: {repo}")

    inside_work_tree = run_git(repo, "rev-parse", "--is-inside-work-tree", capture=True)
    if inside_work_tree != "true":
        raise BranchPreparationError(f"Directory is not a Git worktree: {repo}")

    current_branch = run_git(repo, "branch", "--show-current", capture=True)
    if current_branch and contains_ticket(current_branch, ticket):
        return f"reuse:{current_branch}"

    if run_git(repo, "status", "--porcelain", capture=True):
        raise BranchPreparationError(
            "Working tree has local changes; preserve them before preparing another ticket branch"
        )

    run_git(repo, "fetch", REMOTE)

    local_ref = f"refs/heads/{branch}"
    remote_ref = f"refs/remotes/{REMOTE}/{branch}"
    if ref_exists(repo, local_ref):
        run_git(repo, "switch", branch)
        return f"reuse:{branch}"
    if ref_exists(repo, remote_ref):
        run_git(repo, "switch", "--track", "-c", branch, remote_ref)
        return f"reuse:{branch}"

    remote_base_ref = f"refs/remotes/{REMOTE}/{BASE_BRANCH}"
    if not ref_exists(repo, remote_base_ref):
        raise BranchPreparationError(f"Remote base branch is missing: {REMOTE}/{BASE_BRANCH}")

    # The ticket branch is created straight from the fetched remote baseline so the script stays
    # safe inside a git worktree, where `master` is checked out by another worktree.
    run_git(repo, "switch", "--no-track", "-c", branch, remote_base_ref)
    return f"created:{branch}"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create or reuse a ticket branch based on the latest origin/master."
    )
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--ticket", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument(
        "--nature",
        action="append",
        default=[],
        help="Issue type or category. Repeat for every applicable value.",
    )
    parser.add_argument(
        "--print-name",
        action="store_true",
        help="Print the generated branch name without changing the repository.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        branch = build_branch_name(args.ticket, args.title, args.nature)
        if args.print_name:
            print(branch)
            return 0

        result = prepare_branch(args.repo.resolve(), args.ticket, branch)
        print(result)
        return 0
    except BranchPreparationError as error:
        print(f"error:{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
