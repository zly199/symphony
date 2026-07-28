from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "prepare_ticket_branch.py"
SPEC = importlib.util.spec_from_file_location("prepare_ticket_branch", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrepareTicketBranchTest(unittest.TestCase):
    def git(self, repo: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            text=True,
            capture_output=True,
            check=True,
        )
        return result.stdout.strip()

    def test_builds_scope_from_issue_nature(self) -> None:
        title = "【backend】【Customer環境】給与計算エラー"
        self.assertEqual(
            MODULE.build_branch_name("KYUYO_NEW-4658", title, ["Bug"]),
            "fix/KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー",
        )
        self.assertEqual(
            MODULE.build_branch_name("KYUYO_NEW-4658", title, ["CI"]),
            "doc/KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー",
        )
        self.assertEqual(
            MODULE.build_branch_name("KYUYO_NEW-4658", title, ["CI/CD"]),
            "doc/KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー",
        )
        self.assertEqual(
            MODULE.build_branch_name("KYUYO_NEW-4658", title, ["Task"]),
            "feat/KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー",
        )

    def test_sanitizes_git_invalid_characters_and_truncates_utf8(self) -> None:
        branch = MODULE.build_branch_name(
            "KYUYO_NEW-4658",
            " title / with: [invalid]? * chars .. " + ("給" * 200),
            ["Documentation"],
        )
        self.assertTrue(branch.startswith("doc/KYUYO_NEW-4658-title-with-invalid-chars-"))
        self.assertLessEqual(len(branch.split("/", maxsplit=1)[1].encode("utf-8")), 240)
        subprocess.run(
            ["git", "check-ref-format", "--branch", branch],
            check=True,
            capture_output=True,
        )

    def test_creates_new_branch_from_latest_origin_master(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            remote = root / "remote.git"
            seed = root / "seed"
            work = root / "work"

            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
            subprocess.run(
                ["git", "init", "-b", "master", str(seed)], check=True, capture_output=True
            )
            self.git(seed, "config", "user.name", "Test User")
            self.git(seed, "config", "user.email", "test@example.com")
            (seed / "README.md").write_text("initial\n", encoding="utf-8")
            self.git(seed, "add", "README.md")
            self.git(seed, "commit", "-m", "initial")
            self.git(seed, "remote", "add", "origin", str(remote))
            self.git(seed, "push", "-u", "origin", "master")
            subprocess.run(["git", "clone", str(remote), str(work)], check=True, capture_output=True)

            (seed / "latest.txt").write_text("latest\n", encoding="utf-8")
            self.git(seed, "add", "latest.txt")
            self.git(seed, "commit", "-m", "latest")
            self.git(seed, "push", "origin", "master")

            branch = MODULE.build_branch_name(
                "KYUYO_NEW-4658",
                "【backend】【Customer環境】給与計算エラー",
                ["Task"],
            )
            result = MODULE.prepare_branch(work, "KYUYO_NEW-4658", branch)

            self.assertEqual(result, f"created:{branch}")
            self.assertEqual(self.git(work, "branch", "--show-current"), branch)
            self.assertEqual(
                self.git(work, "rev-parse", "HEAD"),
                self.git(work, "rev-parse", "origin/master"),
            )
            self.assertEqual(
                subprocess.run(
                    [
                        "git",
                        "-C",
                        str(work),
                        "rev-parse",
                        "--abbrev-ref",
                        "--symbolic-full-name",
                        "@{upstream}",
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                ).returncode,
                128,
            )
            self.assertTrue((work / "latest.txt").exists())

    def test_creates_branch_inside_worktree_while_master_is_checked_out(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            remote = root / "remote.git"
            seed = root / "seed"
            main_repo = root / "main"
            worktree = root / "worktrees" / "KYUYO_NEW-4658"

            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
            subprocess.run(
                ["git", "init", "-b", "master", str(seed)], check=True, capture_output=True
            )
            self.git(seed, "config", "user.name", "Test User")
            self.git(seed, "config", "user.email", "test@example.com")
            (seed / "README.md").write_text("initial\n", encoding="utf-8")
            self.git(seed, "add", "README.md")
            self.git(seed, "commit", "-m", "initial")
            self.git(seed, "remote", "add", "origin", str(remote))
            self.git(seed, "push", "-u", "origin", "master")
            subprocess.run(
                ["git", "clone", "-b", "master", str(remote), str(main_repo)],
                check=True,
                capture_output=True,
            )

            # master stays checked out in the main repository, which is what the user keeps working in.
            self.assertEqual(self.git(main_repo, "branch", "--show-current"), "master")
            self.git(main_repo, "worktree", "add", "--detach", str(worktree), "origin/master")

            branch = MODULE.build_branch_name(
                "KYUYO_NEW-4658",
                "【backend】【Customer環境】給与計算エラー",
                ["Bug"],
            )
            result = MODULE.prepare_branch(worktree, "KYUYO_NEW-4658", branch)

            self.assertEqual(result, f"created:{branch}")
            self.assertEqual(self.git(worktree, "branch", "--show-current"), branch)
            self.assertEqual(self.git(main_repo, "branch", "--show-current"), "master")
            self.assertEqual(
                self.git(worktree, "rev-parse", "HEAD"),
                self.git(main_repo, "rev-parse", "origin/master"),
            )

    def test_reuses_current_ticket_branch_with_local_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            subprocess.run(
                ["git", "init", "-b", "master", str(repo)], check=True, capture_output=True
            )
            self.git(repo, "config", "user.name", "Test User")
            self.git(repo, "config", "user.email", "test@example.com")
            (repo / "README.md").write_text("initial\n", encoding="utf-8")
            self.git(repo, "add", "README.md")
            self.git(repo, "commit", "-m", "initial")
            self.git(repo, "switch", "-c", "fix/KYUYO_NEW-4658-existing")
            (repo / "progress.txt").write_text("keep\n", encoding="utf-8")

            result = MODULE.prepare_branch(
                repo,
                "KYUYO_NEW-4658",
                "feat/KYUYO_NEW-4658-new-title",
            )

            self.assertEqual(result, "reuse:fix/KYUYO_NEW-4658-existing")
            self.assertTrue((repo / "progress.txt").exists())


if __name__ == "__main__":
    unittest.main()
