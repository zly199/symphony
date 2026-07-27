#!/usr/bin/env python3
"""Backlog API helper.

Provide a small CLI for common read operations:
- list projects
- list issues with filters
- fetch issue details by key
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


OPENCODE_CONFIG = os.path.expanduser("~/.config/opencode/opencode.jsonc")


def read_opencode_backlog_env() -> dict[str, str]:
    """Read Backlog MCP environment values from opencode config when shell env is absent."""
    if not os.path.exists(OPENCODE_CONFIG):
        return {}

    with open(OPENCODE_CONFIG, encoding="utf-8") as file:
        content = file.read()

    environment_match = re.search(
        r'"backlog"\s*:\s*\{.*?"environment"\s*:\s*\{(?P<body>.*?)\}',
        content,
        flags=re.DOTALL,
    )
    if not environment_match:
        return {}

    values: dict[str, str] = {}
    for key in ("BACKLOG_BASE_URL", "BACKLOG_SPACE", "BACKLOG_DOMAIN", "BACKLOG_API_KEY"):
        match = re.search(rf'"{key}"\s*:\s*"(?P<value>[^"]*)"', environment_match.group("body"))
        if match:
            values[key] = match.group("value").strip()
    return values


def get_config_value(name: str) -> str:
    """Return a Backlog setting from shell env, then opencode Backlog MCP config."""
    value = os.environ.get(name, "").strip()
    if value:
        return value
    return read_opencode_backlog_env().get(name, "")


def build_base_url() -> str:
    """Resolve Backlog API base URL from environment variables.

    Returns:
        str: API base URL with `/api/v2` suffix.

    Raises:
        RuntimeError: If neither `BACKLOG_BASE_URL` nor `BACKLOG_SPACE` is configured.

    Edge cases:
        - If `BACKLOG_BASE_URL` is provided with a trailing slash, normalize it.
        - If both are present, `BACKLOG_BASE_URL` takes precedence.
    """
    backlog_base_url = get_config_value("BACKLOG_BASE_URL")
    if backlog_base_url:
        return f"{backlog_base_url.rstrip('/')}/api/v2"

    backlog_space = get_config_value("BACKLOG_SPACE")
    if backlog_space:
        return f"https://{backlog_space}.backlog.com/api/v2"

    backlog_domain = get_config_value("BACKLOG_DOMAIN")
    if backlog_domain:
        return f"https://{backlog_domain.rstrip('/')}/api/v2"

    raise RuntimeError(
        "Missing Backlog config: set BACKLOG_BASE_URL/BACKLOG_SPACE or configure backlog MCP in opencode.jsonc."
    )


def get_api_key() -> str:
    """Return Backlog API key from environment.

    Returns:
        str: Non-empty API key.

    Raises:
        RuntimeError: If `BACKLOG_API_KEY` is missing.

    Edge cases:
        - Empty or whitespace-only values are treated as missing.
    """
    api_key = get_config_value("BACKLOG_API_KEY")
    if not api_key:
        raise RuntimeError("Missing Backlog config: BACKLOG_API_KEY.")
    return api_key


def request_json(path: str, params: dict[str, Any]) -> Any:
    """Call Backlog API GET endpoint and parse JSON response.

    Args:
        path: Endpoint path such as `/projects` or `/issues`.
        params: Query string parameters excluding API key.

    Returns:
        Any: Parsed JSON response.

    Raises:
        RuntimeError: For HTTP/network failures or non-JSON responses.

    Edge cases:
        - Existing `apiKey` in params is overwritten to avoid ambiguity.
        - Error body parsing falls back to plain text if response is not JSON.
    """
    base_url = build_base_url()
    api_key = get_api_key()
    query = dict(params)
    query["apiKey"] = api_key
    encoded_query = urllib.parse.urlencode(query, doseq=True)
    url = f"{base_url}{path}?{encoded_query}"

    request = urllib.request.Request(url=url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read().decode("utf-8")
            return json.loads(payload)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        try:
            parsed_body = json.loads(body)
        except json.JSONDecodeError:
            parsed_body = body
        raise RuntimeError(
            f"Backlog API HTTP error {error.code}: {json.dumps(parsed_body, ensure_ascii=False)}"
        ) from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Backlog API network error: {error.reason}") from error
    except json.JSONDecodeError as error:
        raise RuntimeError("Backlog API returned non-JSON response.") from error


def brief_issue(issue: dict[str, Any]) -> dict[str, Any]:
    """Reduce an issue payload to review-friendly fields.

    Args:
        issue: Raw issue object from Backlog.

    Returns:
        dict: Compact fields with description truncated to 400 chars.

    Edge cases:
        - Nullable objects (status/assignee/issueType/milestone) degrade to None.
    """
    description = issue.get("description") or ""
    if len(description) > 400:
        description = description[:400] + "…(truncated)"
    milestones = issue.get("milestone") or []
    return {
        "issueKey": issue.get("issueKey"),
        "summary": issue.get("summary"),
        "issueType": (issue.get("issueType") or {}).get("name"),
        "status": (issue.get("status") or {}).get("name"),
        "assignee": (issue.get("assignee") or {}).get("name"),
        "milestone": [milestone.get("name") for milestone in milestones],
        "created": issue.get("created"),
        "updated": issue.get("updated"),
        "description": description,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse command line arguments for Backlog operations.

    Args:
        argv: Raw CLI args excluding executable path.

    Returns:
        argparse.Namespace: Parsed command and options.

    Raises:
        SystemExit: Triggered by argparse on invalid options.

    Edge cases:
        - Repeated `--status-id` is preserved as list for Backlog API.
    """
    parser = argparse.ArgumentParser(description="Backlog API CLI helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("projects", help="List projects")

    issues_parser = subparsers.add_parser("issues", help="Search issues")
    issues_parser.add_argument("--project-id", type=int, help="Project ID")
    issues_parser.add_argument("--project-key", help="Project key")
    issues_parser.add_argument(
        "--status-id",
        type=int,
        action="append",
        default=[],
        help="Status ID (repeatable)",
    )
    issues_parser.add_argument("--assignee-id", type=int, help="Assignee user ID")
    issues_parser.add_argument("--keyword", help="Free-text keyword")
    issues_parser.add_argument("--count", type=int, default=20, help="Result count (1-100)")
    issues_parser.add_argument("--offset", type=int, default=0, help="Result offset")
    issues_parser.add_argument("--updated-since", help="Updated on or after this date (yyyy-MM-dd)")
    issues_parser.add_argument("--updated-until", help="Updated on or before this date (yyyy-MM-dd)")
    issues_parser.add_argument("--created-since", help="Created on or after this date (yyyy-MM-dd)")
    issues_parser.add_argument("--created-until", help="Created on or before this date (yyyy-MM-dd)")
    issues_parser.add_argument(
        "--sort",
        choices=["created", "updated", "issueType", "status", "priority", "dueDate"],
        help="Sort key",
    )
    issues_parser.add_argument("--order", choices=["asc", "desc"], default="desc", help="Sort order")
    issues_parser.add_argument(
        "--brief",
        action="store_true",
        help="Print compact fields only (key/summary/status/assignee/dates), description truncated",
    )

    issue_parser = subparsers.add_parser("issue", help="Get issue by issue key")
    issue_parser.add_argument("--issue-key", required=True, help="Issue key like APP-123")

    comments_parser = subparsers.add_parser("comments", help="List issue comments by issue key")
    comments_parser.add_argument("--issue-key", required=True, help="Issue key like APP-123")
    comments_parser.add_argument("--count", type=int, default=100, help="Result count (1-100)")
    comments_parser.add_argument("--order", choices=["asc", "desc"], default="asc", help="Sort order")
    comments_parser.add_argument("--full", action="store_true", help="Print the raw Backlog comment payload")

    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> Any:
    """Dispatch commands to Backlog endpoints.

    Args:
        args: Parsed CLI arguments.

    Returns:
        Any: Parsed JSON payload returned by Backlog.

    Raises:
        ValueError: If issue query parameters are outside supported range.

    Edge cases:
        - `count` must stay within Backlog accepted range 1..100.
        - `offset` must not be negative.
    """
    if args.command == "projects":
        return request_json("/projects", {})

    if args.command == "issues":
        if args.count < 1 or args.count > 100:
            raise ValueError("--count must be in range 1..100.")
        if args.offset < 0:
            raise ValueError("--offset must be >= 0.")

        params: dict[str, Any] = {"count": args.count, "offset": args.offset}
        if args.project_id is not None:
            params["projectId[]"] = args.project_id
        if args.project_key:
            project_key = urllib.parse.quote(args.project_key, safe="")
            params["projectId[]"] = request_json(f"/projects/{project_key}", {})["id"]
        if args.status_id:
            params["statusId[]"] = args.status_id
        if args.assignee_id is not None:
            params["assigneeId[]"] = args.assignee_id
        if args.keyword:
            params["keyword"] = args.keyword
        for option, param in (
            ("updated_since", "updatedSince"), ("updated_until", "updatedUntil"),
            ("created_since", "createdSince"), ("created_until", "createdUntil"),
        ):
            value = getattr(args, option)
            if value:
                params[param] = value
        if args.sort:
            params["sort"] = args.sort
            params["order"] = args.order

        issues = request_json("/issues", params)
        if args.brief:
            return [brief_issue(issue) for issue in issues]
        return issues

    if args.command == "issue":
        issue_key = urllib.parse.quote(args.issue_key, safe="")
        return request_json(f"/issues/{issue_key}", {})

    if args.command == "comments":
        if args.count < 1 or args.count > 100:
            raise ValueError("--count must be in range 1..100.")
        issue_key = urllib.parse.quote(args.issue_key, safe="")
        comments = request_json(f"/issues/{issue_key}/comments", {"count": args.count, "order": args.order})
        if args.full:
            return comments
        return [
            {
                "id": comment.get("id"),
                "created": comment.get("created"),
                "user": (comment.get("createdUser") or {}).get("name"),
                "content": comment.get("content"),
                "changeLog": [
                    {
                        "field": change.get("field"),
                        "newValue": change.get("newValue"),
                        "originalValue": change.get("originalValue"),
                    }
                    for change in comment.get("changeLog", [])
                ],
            }
            for comment in comments
        ]

    raise ValueError(f"Unsupported command: {args.command}")


def main(argv: list[str]) -> int:
    """Execute CLI and print JSON result.

    Args:
        argv: Raw CLI args excluding executable path.

    Returns:
        int: Process exit code (0 on success, 1 on failure).

    Edge cases:
        - Any runtime error is printed to stderr with non-zero exit.
    """
    try:
        args = parse_args(argv)
        output = run(args)
        print(json.dumps(output, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:  # pylint: disable=broad-except
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
