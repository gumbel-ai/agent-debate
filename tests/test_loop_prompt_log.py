import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks" / "loop-prompt-log.sh"


class LoopPromptLogTest(unittest.TestCase):
    def make_project(self, tmpdir):
        project = Path(tmpdir) / "project"
        loop_dir = project / ".agent-debate" / "loop"
        loop_dir.mkdir(parents=True)
        (loop_dir / "state.json").write_text("{}\n")
        (loop_dir / "journal.md").write_text("")
        loop = project / "loop.sh"
        # Minimal stand-in that mirrors cmd_log so the test stays hermetic.
        loop.write_text(
            "#!/usr/bin/env bash\n"
            "shift\n"
            'printf "[ts] %s\\n" "$*" >> .agent-debate/loop/journal.md\n'
        )
        loop.chmod(0o755)
        return project

    def journal(self, project):
        return (project / ".agent-debate" / "loop" / "journal.md").read_text()

    def run_hook(self, payload, project):
        return subprocess.run(
            [str(HOOK)],
            input=json.dumps(payload),
            text=True,
            cwd=project,
            env=os.environ.copy(),
            capture_output=True,
            check=False,
        )

    def test_claude_prompt_field_is_journaled(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            result = self.run_hook(
                {"prompt": "switch the cache to redis", "cwd": str(project)},
                project,
            )

            self.assertEqual(result.returncode, 0)
            self.assertIn("user: switch the cache to redis", self.journal(project))

    def test_codex_user_prompt_field_is_journaled(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            result = self.run_hook(
                {"user_prompt": "add retry logic", "cwd": str(project)},
                project,
            )

            self.assertEqual(result.returncode, 0)
            self.assertIn("user: add retry logic", self.journal(project))

    def test_multiline_prompt_is_flattened_and_truncated(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            long_prompt = "line one\nline two\n" + ("x" * 600)
            result = self.run_hook({"prompt": long_prompt, "cwd": str(project)}, project)

            self.assertEqual(result.returncode, 0)
            journal = self.journal(project)
            self.assertIn("user: line one line two", journal)
            self.assertNotIn("\nline two", journal.split("user: ", 1)[1])
            self.assertIn("...", journal)

    def test_slash_command_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            result = self.run_hook({"prompt": "/hooks", "cwd": str(project)}, project)

            self.assertEqual(result.returncode, 0)
            self.assertEqual(self.journal(project), "")

    def test_no_active_loop_is_a_quiet_noop(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = Path(tmpdir) / "bare"
            project.mkdir()
            result = self.run_hook({"prompt": "hello", "cwd": str(project)}, project)

            self.assertEqual(result.returncode, 0)
            self.assertFalse((project / ".agent-debate").exists())


if __name__ == "__main__":
    unittest.main()
