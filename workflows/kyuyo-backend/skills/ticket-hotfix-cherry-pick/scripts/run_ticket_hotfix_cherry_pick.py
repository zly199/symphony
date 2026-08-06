#!/usr/bin/env python3
"""Create a ticket-based hotfix cherry-pick branch and MR for kyuyo-backend."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.parse
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path


GENERATED_SOURCE_PREFIXES = (
    "staging-cherry-pick/",
    "test-cherry-pick/",
    "customer-cherry-pick/",
    "production-cherry-pick/",
    "cherry-pick-",
)
GENERATED_TITLE_PREFIXES = (
    "staging-cherry-pick:",
    "test-cherry-pick:",
    "customer-cherry-pick:",
    "production-cherry-pick:",
    "test-cherry-pick/",
)
PREPARE_STATE_DIR = "ticket-hotfix-cherry-pick-state"


@dataclass(frozen=True)
class ModeConfig:
    base_branch_prefix: str | None
    base_branch_name: str | None
    new_branch_prefix: str
    mr_title_prefix: str


MODE_CONFIG = {
    "staging-hotfix": ModeConfig(
        base_branch_prefix="staging-hotfix-",
        base_branch_name=None,
        new_branch_prefix="staging-cherry-pick",
        mr_title_prefix="staging-cherry-pick",
    ),
    "test-hotfix": ModeConfig(
        base_branch_prefix=None,
        base_branch_name="production",
        new_branch_prefix="test-cherry-pick",
        mr_title_prefix="test-cherry-pick",
    ),
    "production-hotfix": ModeConfig(
        base_branch_prefix="hotfix-",
        base_branch_name=None,
        new_branch_prefix="customer-cherry-pick",
        mr_title_prefix="customer-cherry-pick",
    ),
}


@dataclass(frozen=True)
class CommitInfo:
    sha: str
    title: str


@dataclass(frozen=True)
class MergeRequestInfo:
    iid: int
    title: str
    web_url: str
    source_branch: str
    target_branch: str
    merged_at: str
    merge_commit_sha: str
    commits: list[CommitInfo]

    @property
    def branch_fragment(self) -> str:
        return preferred_branch_fragment(self.source_branch, self.title)


class CherryPickError(RuntimeError):
    pass


@contextmanager
def repo_lock(repo: Path):
    lock_path = repo / ".git" / "ticket-hotfix-cherry-pick.lock"
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as error:
        raise CherryPickError(
            f"Another ticket hotfix cherry-pick process is already running: {lock_path}"
        ) from error

    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))
        yield
    finally:
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass


def run(
    *args: str,
    cwd: Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        list(args),
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=True,
        check=False,
    )
    if check and proc.returncode != 0:
        raise CherryPickError(
            f"command failed: {' '.join(args)}\nstdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return proc


def validate_repo(repo: Path) -> None:
    if not repo.exists():
        raise CherryPickError(f"Repository path does not exist: {repo}")
    if not (repo / ".git").exists():
        raise CherryPickError(f"Not a git repository: {repo}")
    run("git", "rev-parse", "--is-inside-work-tree", cwd=repo)


def ensure_clean_worktree(repo: Path) -> None:
    proc = run("git", "status", "--short", cwd=repo)
    if proc.stdout.strip():
        raise CherryPickError("Working tree is not clean. Commit, stash, or discard changes first.")


def infer_project_from_remote(repo: Path) -> str:
    remote = run("git", "remote", "get-url", "origin", cwd=repo).stdout.strip()
    if remote.startswith("http://") or remote.startswith("https://"):
        path = urllib.parse.urlparse(remote).path
    elif ":" in remote:
        path = remote.split(":", 1)[1]
    else:
        path = remote
    project = path.lstrip("/").removesuffix(".git")
    if not project:
        raise CherryPickError(f"Cannot infer GitLab project from remote URL: {remote}")
    return project


def encode_project(project: str) -> str:
    return urllib.parse.quote(project, safe="")


def list_latest_base_branch(repo: Path, prefix: str) -> str:
    proc = run("git", "branch", "-r", "--list", f"origin/{prefix}*", cwd=repo)
    branches = []
    for raw in proc.stdout.splitlines():
        branch = raw.strip()
        if not branch:
            continue
        name = branch.removeprefix("origin/")
        match = re.fullmatch(rf"{re.escape(prefix)}(\d{{8}})", name)
        if match:
            branches.append((match.group(1), name))
    if not branches:
        raise CherryPickError(f"No remote branch found for prefix origin/{prefix}*")
    branches.sort(key=lambda item: item[0], reverse=True)
    return branches[0][1]


def require_remote_branch(repo: Path, branch_name: str) -> str:
    proc = run("git", "branch", "-r", "--list", f"origin/{branch_name}", cwd=repo)
    if not proc.stdout.strip():
        raise CherryPickError(f"No remote branch found for origin/{branch_name}")
    return branch_name


def resolve_required_staging_branch(repo: Path, base_date: str | None) -> str:
    date_text = base_date or dt.datetime.now().strftime("%Y%m%d")
    try:
        dt.datetime.strptime(date_text, "%Y%m%d")
    except ValueError as error:
        raise CherryPickError(f"Invalid --base-date value: {date_text} (expected YYYYMMDD)") from error

    branch_name = f"staging-hotfix-{date_text}"
    proc = run("git", "branch", "-r", "--list", f"origin/{branch_name}", cwd=repo)
    if proc.stdout.strip():
        return branch_name

    raise CherryPickError(
        f"Required staging base branch origin/{branch_name} was not found. "
        "Run kyuyo-hotfix-release --mode staging-hotfix first, then rerun this cherry-pick."
    )


def resolve_base_branch(repo: Path, mode: str, config: ModeConfig, base_date: str | None) -> str:
    if mode == "staging-hotfix":
        return resolve_required_staging_branch(repo, base_date)

    if config.base_branch_name:
        return require_remote_branch(repo, config.base_branch_name)

    if not config.base_branch_prefix:
        raise CherryPickError("ModeConfig must define either base_branch_name or base_branch_prefix.")
    return list_latest_base_branch(repo, config.base_branch_prefix)


def list_ticket_merge_requests(repo: Path, ticket: str, project: str) -> list[MergeRequestInfo]:
    project_id = encode_project(project)
    result: list[MergeRequestInfo] = []
    seen_iids: set[int] = set()
    ticket_lower = ticket.lower()
    keywords = ticket_keywords(ticket)

    for item in search_ticket_merge_request_candidates(repo, ticket):
        title = str(item.get("title", ""))
        source_branch = str(item.get("source_branch", ""))
        description = str(item.get("description", ""))
        haystack = "\n".join((title, source_branch, description)).lower()
        if not title_matches_ticket_keywords(title, keywords) and ticket_lower not in haystack:
            continue
        if is_generated_mr(title, source_branch):
            continue
        # glab --merged still returns closed MRs, so keep only actually merged ones.
        if not item.get("merged_at"):
            continue

        iid = int(item["iid"])
        if iid in seen_iids:
            continue
        seen_iids.add(iid)
        commits = fetch_mr_commits(repo, project_id, iid)
        result.append(
            MergeRequestInfo(
                iid=iid,
                title=title,
                web_url=str(item.get("web_url", "")),
                source_branch=source_branch,
                target_branch=str(item.get("target_branch", "")),
                merged_at=str(item.get("merged_at", "")),
                merge_commit_sha=str(item.get("merge_commit_sha", "")),
                commits=commits,
            )
        )

    result.sort(key=lambda mr: (mr.merged_at, mr.iid))
    return result


def search_ticket_merge_request_candidates(repo: Path, ticket: str) -> list[dict]:
    items: list[dict] = []
    for search_term in ticket_search_terms(ticket):
        proc = run(
            "glab",
            "mr",
            "list",
            "--all",
            "--merged",
            "--search",
            search_term,
            "--output",
            "json",
            "--per-page",
            "100",
            cwd=repo,
        )
        items.extend(json.loads(proc.stdout or "[]"))
    return items


def ticket_search_terms(ticket: str) -> list[str]:
    keywords = ticket_keywords(ticket)
    keyword_text = " ".join(keywords)
    search_terms = [
        keyword_text,
        keyword_text.upper(),
        ticket,
        ticket.casefold(),
        ticket.upper(),
    ]
    numeric_keywords = [keyword for keyword in keywords if keyword.isdigit()]
    if numeric_keywords:
        search_terms.append(numeric_keywords[-1])
    elif keywords:
        search_terms.append(max(keywords, key=len))
    return unique_non_empty(search_terms)


def ticket_keywords(ticket: str) -> list[str]:
    return unique_non_empty(part.casefold() for part in re.split(r"[^A-Za-z0-9]+", ticket))


def unique_non_empty(values) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for raw in values:
        value = str(raw).strip()
        if not value or value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def title_matches_ticket_keywords(title: str, keywords: list[str]) -> bool:
    if not keywords:
        return False
    compact_title = re.sub(r"[^a-z0-9]+", "", title.casefold())
    return all(keyword in compact_title for keyword in keywords)


def fetch_mr_commits(repo: Path, project_id: str, iid: int) -> list[CommitInfo]:
    proc = run(
        "glab",
        "api",
        f"projects/{project_id}/merge_requests/{iid}/commits",
        cwd=repo,
    )
    data = json.loads(proc.stdout or "[]")
    commits = [CommitInfo(sha=str(item["id"]), title=str(item.get("title", ""))) for item in data]
    if not commits:
        raise CherryPickError(f"MR !{iid} has no commits.")
    return commits


def is_generated_mr(title: str, source_branch: str) -> bool:
    return source_branch.startswith(GENERATED_SOURCE_PREFIXES) or title.startswith(
        GENERATED_TITLE_PREFIXES
    )


def sanitize_branch_fragment(text: str) -> str:
    normalized = text.strip().replace(":", "-")
    normalized = re.sub(r"^(feat|fix|test|hotfix|staging-hotfix|production-hotfix)-?", "", normalized)
    normalized = re.sub(r"[\\/\s~^?\[*\]]+", "-", normalized)
    normalized = normalized.replace("..", "-")
    normalized = normalized.replace("@{", "-")
    normalized = normalized.strip(".-")
    normalized = re.sub(r"-{2,}", "-", normalized)
    if not normalized:
        raise CherryPickError(f"Cannot build branch fragment from title: {text}")
    return normalized


def preferred_branch_fragment(source_branch: str, title: str) -> str:
    branch_like = source_branch.strip()
    if branch_like and not branch_like.startswith(GENERATED_SOURCE_PREFIXES):
        return sanitize_branch_fragment(branch_like)
    return sanitize_branch_fragment(title)


def build_branch_name(mode: ModeConfig, mrs: list[MergeRequestInfo]) -> str:
    first = mrs[0].branch_fragment
    if len(mrs) == 1:
        suffix = first
    else:
        suffix = first + "".join(f"+{index}" for index in range(2, len(mrs) + 1))
    return f"{mode.new_branch_prefix}/{suffix}"


def build_mr_title(mode: ModeConfig, mrs: list[MergeRequestInfo]) -> str:
    first = mrs[0].title
    if len(mrs) == 1:
        suffix = first
    else:
        suffix = first + "".join(f"+{index}" for index in range(2, len(mrs) + 1))
    return f"{mode.mr_title_prefix}: {suffix}"


def branch_exists(repo: Path, branch_name: str) -> bool:
    local = run("git", "show-ref", "--verify", f"refs/heads/{branch_name}", cwd=repo, check=False)
    if local.returncode == 0:
        return True
    remote = run("git", "ls-remote", "--heads", "origin", branch_name, cwd=repo, check=False)
    return bool(remote.stdout.strip())


def remote_branch_exists(repo: Path, branch_name: str) -> bool:
    proc = run("git", "ls-remote", "--heads", "origin", branch_name, cwd=repo, check=False)
    return bool(proc.stdout.strip())


def get_shortstat(repo: Path, rev: str) -> str:
    proc = run("git", "show", "--shortstat", "--format=", rev, cwd=repo)
    return normalize_shortstat(proc.stdout)


def normalize_shortstat(text: str) -> str:
    return " ".join(line.strip() for line in text.splitlines() if line.strip())


def checkout_base_branch(repo: Path, base_branch: str, new_branch: str) -> None:
    run("git", "fetch", "origin", cwd=repo)
    run("git", "checkout", "-b", new_branch, f"origin/{base_branch}", cwd=repo)


def cherry_pick_commit(repo: Path, mr: MergeRequestInfo, commit: CommitInfo) -> dict:
    expected = get_shortstat(repo, commit.sha)
    proc = run("git", "cherry-pick", commit.sha, cwd=repo, check=False)
    if proc.returncode != 0:
        raise CherryPickError(
            "Cherry-pick failed.\n"
            f"MR: !{mr.iid} {mr.title}\n"
            f"Commit: {commit.sha}\n"
            f"stdout: {proc.stdout}\n"
            f"stderr: {proc.stderr}"
        )
    actual = get_shortstat(repo, "HEAD")
    return {
        "mr_iid": mr.iid,
        "mr_title": mr.title,
        "original_commit": commit.sha,
        "new_commit": run("git", "rev-parse", "HEAD", cwd=repo).stdout.strip(),
        "original_shortstat": expected,
        "replayed_shortstat": actual,
        "shortstat_matches": expected == actual,
        "semantic_review_required": True,
    }


def current_branch(repo: Path) -> str:
    return run("git", "branch", "--show-current", cwd=repo).stdout.strip()


def git_lines(repo: Path, *args: str) -> list[str]:
    return [line.strip() for line in run("git", *args, cwd=repo).stdout.splitlines() if line.strip()]


def prepare_state_path(repo: Path, branch_name: str) -> Path:
    raw_dir = run("git", "rev-parse", "--git-path", PREPARE_STATE_DIR, cwd=repo).stdout.strip()
    state_dir = Path(raw_dir)
    if not state_dir.is_absolute():
        state_dir = repo / state_dir
    branch_key = hashlib.sha256(branch_name.encode("utf-8")).hexdigest()
    return state_dir / f"{branch_key}.json"


def clear_prepare_state(repo: Path, branch_name: str) -> None:
    prepare_state_path(repo, branch_name).unlink(missing_ok=True)


def branch_commits(repo: Path, base_branch: str) -> list[str]:
    return git_lines(repo, "rev-list", "--reverse", f"origin/{base_branch}..HEAD")


def branch_changed_files(repo: Path, base_branch: str) -> list[str]:
    return sorted(git_lines(repo, "diff", "--name-only", f"origin/{base_branch}..HEAD"))


def commit_changed_files(repo: Path, revision: str) -> list[str]:
    return sorted(
        git_lines(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", revision)
    )


def diff_fingerprint(repo: Path, base_branch: str) -> str:
    diff = run("git", "diff", "--binary", f"origin/{base_branch}..HEAD", cwd=repo).stdout
    return hashlib.sha256(diff.encode("utf-8")).hexdigest()


def planned_commit_shas(mrs: list[MergeRequestInfo]) -> list[str]:
    return [commit.sha for mr in mrs for commit in mr.commits]


def validate_branch_matches_plan(repo: Path, base_branch: str, mrs: list[MergeRequestInfo]) -> None:
    commits = branch_commits(repo, base_branch)
    planned_commits = planned_commit_shas(mrs)
    if len(commits) != len(planned_commits):
        raise CherryPickError(
            "Reviewed branch commit count does not match the original MR plan. "
            f"Expected {len(planned_commits)}, found {len(commits)}. Extra verification, test, refactor, "
            "formatting, documentation, or fix commits are forbidden on a cherry-pick branch."
        )

    for index, (replayed_commit, original_commit) in enumerate(
        zip(commits, planned_commits, strict=True), start=1
    ):
        actual_files = commit_changed_files(repo, replayed_commit)
        planned_files = commit_changed_files(repo, original_commit)
        if actual_files != planned_files:
            raise CherryPickError(
                "Reviewed branch changed-file set does not match the original MR plan at commit "
                f"{index}. Expected {planned_files}, found {actual_files}. "
                "Do not add files to a cherry-pick branch."
            )


def build_prepare_state(
    repo: Path,
    ticket: str,
    mode: str,
    base_branch: str,
    new_branch: str,
    mrs: list[MergeRequestInfo],
) -> dict:
    validate_branch_matches_plan(repo, base_branch, mrs)
    return {
        "version": 1,
        "ticket": ticket,
        "mode": mode,
        "base_branch": base_branch,
        "base_sha": run("git", "rev-parse", f"origin/{base_branch}", cwd=repo).stdout.strip(),
        "new_branch": new_branch,
        "prepared_head": run("git", "rev-parse", "HEAD", cwd=repo).stdout.strip(),
        "branch_commits": branch_commits(repo, base_branch),
        "original_commits": planned_commit_shas(mrs),
        "changed_files": branch_changed_files(repo, base_branch),
        "diff_sha256": diff_fingerprint(repo, base_branch),
    }


def seal_prepared_branch(
    repo: Path,
    ticket: str,
    mode: str,
    base_branch: str,
    new_branch: str,
    mrs: list[MergeRequestInfo],
) -> dict:
    state = build_prepare_state(repo, ticket, mode, base_branch, new_branch, mrs)
    path = prepare_state_path(repo, new_branch)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    return state


def load_prepare_state(repo: Path, branch_name: str) -> dict:
    path = prepare_state_path(repo, branch_name)
    if not path.exists():
        raise CherryPickError(
            "Prepared-branch integrity seal is missing. Run --prepare-only again, or use --seal-reviewed "
            "after resolving a cherry-pick conflict."
        )
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CherryPickError(f"Cannot read prepared-branch integrity seal: {path}") from error
    if not isinstance(data, dict):
        raise CherryPickError(f"Invalid prepared-branch integrity seal: {path}")
    return data


def validate_prepare_state(
    repo: Path,
    ticket: str,
    mode: str,
    base_branch: str,
    new_branch: str,
    mrs: list[MergeRequestInfo],
) -> None:
    state = load_prepare_state(repo, new_branch)
    expected_identity = {
        "ticket": ticket,
        "mode": mode,
        "base_branch": base_branch,
        "new_branch": new_branch,
        "original_commits": planned_commit_shas(mrs),
    }
    mismatches = [key for key, value in expected_identity.items() if state.get(key) != value]
    if mismatches:
        raise CherryPickError(
            f"Prepared-branch integrity seal does not match the current plan: {', '.join(mismatches)}"
        )

    current_state = build_prepare_state(repo, ticket, mode, base_branch, new_branch, mrs)
    protected_fields = [
        "base_sha",
        "prepared_head",
        "branch_commits",
        "changed_files",
        "diff_sha256",
    ]
    changed_fields = [key for key in protected_fields if state.get(key) != current_state.get(key)]
    if changed_fields:
        raise CherryPickError(
            "Reviewed branch changed after it was prepared and sealed: "
            f"{', '.join(changed_fields)}. Recreate the cherry-pick branch; do not append or amend commits."
        )


def validate_reviewed_branch(
    repo: Path, base_branch: str, new_branch: str, mrs: list[MergeRequestInfo]
) -> None:
    if current_branch(repo) != new_branch:
        raise CherryPickError(f"Current branch must be the reviewed branch: {new_branch}")
    if (repo / ".git" / "CHERRY_PICK_HEAD").exists():
        raise CherryPickError("Cherry-pick is still in progress. Resolve and continue it before publishing.")
    ensure_clean_worktree(repo)
    ancestor = run(
        "git", "merge-base", "--is-ancestor", f"origin/{base_branch}", "HEAD", cwd=repo, check=False
    )
    if ancestor.returncode != 0:
        raise CherryPickError(f"Reviewed branch is not based on origin/{base_branch}: {new_branch}")
    commit_count = int(run("git", "rev-list", "--count", f"origin/{base_branch}..HEAD", cwd=repo).stdout)
    if commit_count == 0:
        raise CherryPickError(f"Reviewed branch has no commits over origin/{base_branch}: {new_branch}")
    validate_branch_matches_plan(repo, base_branch, mrs)
    if remote_branch_exists(repo, new_branch):
        raise CherryPickError(f"Remote branch already exists: {new_branch}")


def push_branch(repo: Path, branch_name: str) -> None:
    run("git", "push", "-u", "origin", branch_name, cwd=repo)


def create_merge_request(
    repo: Path,
    source_branch: str,
    target_branch: str,
    title: str,
    mrs: list[MergeRequestInfo],
) -> str:
    description_lines = [
        f"Cherry-pick ticket MRs into {target_branch}.",
        "",
        "Original MRs:",
    ]
    description_lines.extend(f"- !{mr.iid} {mr.title}" for mr in mrs)
    description = "\n".join(description_lines)
    proc = run(
        "glab",
        "mr",
        "create",
        "--source-branch",
        source_branch,
        "--target-branch",
        target_branch,
        "--title",
        title,
        "--description",
        description,
        "--yes",
        cwd=repo,
    )
    url = proc.stdout.strip().splitlines()[-1].strip()
    if not url.startswith("http"):
        raise CherryPickError(f"Unexpected MR create output: {proc.stdout}")
    return url


def total_shortstat(repo: Path, base_branch: str) -> str:
    proc = run("git", "diff", "--shortstat", f"origin/{base_branch}..HEAD", cwd=repo)
    return normalize_shortstat(proc.stdout)


def print_plan(ticket: str, mode: str, base_branch: str, new_branch: str, mrs: list[MergeRequestInfo]) -> None:
    plan = {
        "ticket": ticket,
        "mode": mode,
        "base_branch": base_branch,
        "new_branch": new_branch,
        "mr_count": len(mrs),
        "mrs": [
            {
                "iid": mr.iid,
                "title": mr.title,
                "merged_at": mr.merged_at,
                "source_branch": mr.source_branch,
                "target_branch": mr.target_branch,
                "web_url": mr.web_url,
                "commit_count": len(mr.commits),
                "commits": [{"sha": commit.sha, "title": commit.title} for commit in mr.commits],
            }
            for mr in mrs
        ],
    }
    print(json.dumps(plan, ensure_ascii=False, indent=2))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a ticket-based hotfix cherry-pick branch and merge request."
    )
    parser.add_argument("--ticket", required=True, help="Ticket number, for example KYUYO_NEW-4318.")
    parser.add_argument(
        "--mode",
        required=True,
        choices=sorted(MODE_CONFIG.keys()),
        help="Hotfix mode: staging-hotfix, test-hotfix, or production-hotfix.",
    )
    parser.add_argument("--repo", default=".", help="Path to kyuyo-backend git repository.")
    parser.add_argument("--project", help="Override GitLab project path.")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument(
        "--plan-only",
        action="store_true",
        help="Resolve MRs, commits, and branch names without changing git state.",
    )
    action.add_argument(
        "--prepare-only",
        action="store_true",
        help="Create the local branch and replay commits without pushing or creating an MR.",
    )
    action.add_argument(
        "--publish-reviewed",
        action="store_true",
        help="Publish the current prepared branch after semantic review and target verification.",
    )
    action.add_argument(
        "--seal-reviewed",
        action="store_true",
        help="Seal a manually conflict-resolved branch after semantic review, without publishing it.",
    )
    parser.add_argument(
        "--base-date",
        help="Required staging hotfix base date in YYYYMMDD. Default: today. Applies to staging-hotfix.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = Path(args.repo).resolve()

    try:
        validate_repo(repo)
        project = args.project or infer_project_from_remote(repo)
        config = MODE_CONFIG[args.mode]
        run("git", "fetch", "origin", cwd=repo)
        base_branch = resolve_base_branch(repo, args.mode, config, args.base_date)
        mrs = list_ticket_merge_requests(repo, args.ticket, project)
        if not mrs:
            raise CherryPickError(f"No merged original MR found for ticket {args.ticket}.")

        new_branch = build_branch_name(config, mrs)
        mr_title = build_mr_title(config, mrs)

        if args.plan_only:
            print_plan(args.ticket, args.mode, base_branch, new_branch, mrs)
            return 0

        if args.prepare_only:
            with repo_lock(repo):
                ensure_clean_worktree(repo)
                if branch_exists(repo, new_branch):
                    raise CherryPickError(f"Target branch already exists: {new_branch}")
                clear_prepare_state(repo, new_branch)
                checkout_base_branch(repo, base_branch, new_branch)
                applied = [cherry_pick_commit(repo, mr, commit) for mr in mrs for commit in mr.commits]
                integrity_state = seal_prepared_branch(
                    repo, args.ticket, args.mode, base_branch, new_branch, mrs
                )
            summary = {
                "status": "semantic_review_required",
                "ticket": args.ticket,
                "mode": args.mode,
                "base_branch": base_branch,
                "new_branch": new_branch,
                "mr_count": len(mrs),
                "applied_commits": applied,
                "total_shortstat": total_shortstat(repo, base_branch),
                "integrity_seal_head": integrity_state["prepared_head"],
            }
        elif args.seal_reviewed:
            with repo_lock(repo):
                if prepare_state_path(repo, new_branch).exists():
                    raise CherryPickError(
                        "Prepared branch is already sealed. Do not change it after --prepare-only."
                    )
                validate_reviewed_branch(repo, base_branch, new_branch, mrs)
                integrity_state = seal_prepared_branch(
                    repo, args.ticket, args.mode, base_branch, new_branch, mrs
                )
            summary = {
                "status": "sealed_after_conflict_review",
                "ticket": args.ticket,
                "mode": args.mode,
                "base_branch": base_branch,
                "new_branch": new_branch,
                "mr_count": len(mrs),
                "total_shortstat": total_shortstat(repo, base_branch),
                "integrity_seal_head": integrity_state["prepared_head"],
            }
        else:
            with repo_lock(repo):
                validate_reviewed_branch(repo, base_branch, new_branch, mrs)
                validate_prepare_state(
                    repo, args.ticket, args.mode, base_branch, new_branch, mrs
                )
                push_branch(repo, new_branch)
                mr_url = create_merge_request(repo, new_branch, base_branch, mr_title, mrs)
            summary = {
                "status": "published_after_semantic_review",
                "ticket": args.ticket,
                "mode": args.mode,
                "base_branch": base_branch,
                "new_branch": new_branch,
                "merge_request_url": mr_url,
                "mr_count": len(mrs),
                "total_shortstat": total_shortstat(repo, base_branch),
            }
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return 0
    except CherryPickError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
