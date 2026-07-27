from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "run_ticket_hotfix_cherry_pick.py"
SPEC = importlib.util.spec_from_file_location("run_ticket_hotfix_cherry_pick", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class PublishIntegrityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp_dir.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Test User")
        self.git("config", "user.email", "test@example.com")

        (self.repo / "source.txt").write_text("base\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git("commit", "--quiet", "-m", "base")
        self.base_sha = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/production", self.base_sha)

        self.git("checkout", "--quiet", "-b", "original")
        (self.repo / "source.txt").write_text("ticket change\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git("commit", "--quiet", "-m", "feat: ticket")
        self.original_sha = self.git("rev-parse", "HEAD")

        self.branch_name = "test-cherry-pick/ticket"
        self.git("checkout", "--quiet", "-b", self.branch_name, self.base_sha)
        self.git("cherry-pick", "--quiet", self.original_sha)
        self.mrs = [
            MODULE.MergeRequestInfo(
                iid=1,
                title="feat: ticket",
                web_url="https://example.invalid/mr/1",
                source_branch="feat/ticket",
                target_branch="master",
                merged_at="2026-07-22T00:00:00Z",
                merge_commit_sha="",
                commits=[MODULE.CommitInfo(sha=self.original_sha, title="feat: ticket")],
            )
        ]

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def git(self, *args: str) -> str:
        proc = subprocess.run(
            ["git", *args], cwd=self.repo, text=True, capture_output=True, check=True
        )
        return proc.stdout.strip()

    def seal(self) -> dict:
        return MODULE.seal_prepared_branch(
            self.repo, "TICKET-1", "test-hotfix", "production", self.branch_name, self.mrs
        )

    def validate_seal(self) -> None:
        MODULE.validate_prepare_state(
            self.repo, "TICKET-1", "test-hotfix", "production", self.branch_name, self.mrs
        )

    def test_sealed_clean_replay_passes(self) -> None:
        state = self.seal()

        self.validate_seal()
        self.assertEqual(state["changed_files"], ["source.txt"])
        self.assertEqual(len(state["branch_commits"]), 1)

    def test_extra_commit_is_rejected(self) -> None:
        (self.repo / "test.txt").write_text("extra verification\n", encoding="utf-8")
        self.git("add", "test.txt")
        self.git("commit", "--quiet", "-m", "test: extra")

        with self.assertRaisesRegex(MODULE.CherryPickError, "commit count"):
            MODULE.validate_branch_matches_plan(self.repo, "production", self.mrs)

    def test_extra_file_folded_into_replay_commit_is_rejected(self) -> None:
        (self.repo / "test.txt").write_text("extra verification\n", encoding="utf-8")
        self.git("add", "test.txt")
        self.git("commit", "--quiet", "--amend", "--no-edit")

        with self.assertRaisesRegex(MODULE.CherryPickError, "changed-file set"):
            MODULE.validate_branch_matches_plan(self.repo, "production", self.mrs)

    def test_amended_replay_is_rejected_after_seal(self) -> None:
        self.seal()
        (self.repo / "source.txt").write_text("changed after review\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git("commit", "--quiet", "--amend", "--no-edit")

        with self.assertRaisesRegex(MODULE.CherryPickError, "changed after it was prepared"):
            self.validate_seal()


if __name__ == "__main__":
    unittest.main()
