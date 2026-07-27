#!/usr/bin/env python3
"""Launch the installed Symphony Backlog service without persisting its API key."""

from __future__ import annotations

import os
import re


INSTALL_ROOT = "/Users/user/symphony"
BINARY_PATH = f"{INSTALL_ROOT}/symphony-backlog-macos_arm64"
WORKFLOW_PATH = f"{INSTALL_ROOT}/WORKFLOW.backlog.md"
RUNTIME_PATH = f"{INSTALL_ROOT}/runtime"
LOGS_PATH = f"{INSTALL_ROOT}/var"
OPENCODE_CONFIG = "/Users/user/.config/opencode/opencode.jsonc"
ACKNOWLEDGEMENT = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"


def backlog_api_key() -> str:
    existing = os.environ.get("BACKLOG_API_KEY", "").strip()
    if existing:
        return existing

    with open(OPENCODE_CONFIG, encoding="utf-8") as config_file:
        content = config_file.read()

    environment_match = re.search(
        r'"backlog"\s*:\s*\{.*?"environment"\s*:\s*\{(?P<body>.*?)\}',
        content,
        flags=re.DOTALL,
    )
    if environment_match is None:
        raise RuntimeError("Backlog environment was not found in the OpenCode config.")

    api_key_match = re.search(
        r'"BACKLOG_API_KEY"\s*:\s*"(?P<value>[^"]+)"',
        environment_match.group("body"),
    )
    if api_key_match is None:
        raise RuntimeError("BACKLOG_API_KEY was not found in the OpenCode config.")

    return api_key_match.group("value")


def main() -> None:
    os.makedirs(RUNTIME_PATH, mode=0o700, exist_ok=True)
    os.makedirs(LOGS_PATH, mode=0o700, exist_ok=True)

    environment = os.environ.copy()
    environment["BACKLOG_API_KEY"] = backlog_api_key()
    environment["SYMPHONY_INSTALL_DIR"] = RUNTIME_PATH
    environment["PATH"] = (
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    )
    environment.setdefault("LANG", "en_US.UTF-8")

    os.execve(
        BINARY_PATH,
        [
            BINARY_PATH,
            ACKNOWLEDGEMENT,
            "--logs-root",
            LOGS_PATH,
            WORKFLOW_PATH,
        ],
        environment,
    )


if __name__ == "__main__":
    main()
