import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WATCH = ROOT / "watch.sh"


class WatchLedgerContractTest(unittest.TestCase):
    def make_project(self, tmpdir):
        project = Path(tmpdir) / "project"
        watch_dir = project / ".agent-debate" / "watch"
        watch_dir.mkdir(parents=True)
        journal = watch_dir / "journal.md"
        feedback = watch_dir / "feedback.md"
        journal.write_text("")
        feedback.write_text("")
        self.write_state(project)
        return project

    def write_state(self, project, **overrides):
        watch_dir = project / ".agent-debate" / "watch"
        state = {
            "host_provider": "codex",
            "watcher_provider": "test",
            "watcher_alias": "dummy",
            "journal_path": str(watch_dir / "journal.md"),
            "feedback_path": str(watch_dir / "feedback.md"),
            "feedback_cursor": 0,
            "ledger_completion_cursor": 0,
            "journal_review_offset": 0,
            "loop_pid": "",
            "started_at": "2026-06-16T00:00:00+00:00",
            "watch_interval": 1,
        }
        state.update(overrides)
        (watch_dir / "state.json").write_text(json.dumps(state) + "\n")

    def run_watch(self, project, *args, env=None):
        full_env = os.environ.copy()
        full_env["HOME"] = str(project / "home")
        if env:
            full_env.update(env)
        return subprocess.run(
            [str(WATCH), *args],
            cwd=project,
            env=full_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def state(self, project):
        return json.loads((project / ".agent-debate" / "watch" / "state.json").read_text())

    def journal(self, project):
        return (project / ".agent-debate" / "watch" / "journal.md").read_text()

    def feedback(self, project):
        return (project / ".agent-debate" / "watch" / "feedback.md").read_text()

    def latest_archive(self, project):
        archives = sorted((project / ".agent-debate" / "watch" / "archive").iterdir())
        return archives[-1]

    def test_gate_requires_new_intent_per_completion(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)

            missing = self.run_watch(project, "gate")
            self.assertEqual(missing.returncode, 2)
            self.assertIn("watch.sh intent", missing.stderr)

            intent = self.run_watch(project, "intent", "implement CLI and run tests")
            self.assertEqual(intent.returncode, 0)

            first = self.run_watch(project, "gate")
            self.assertEqual(first.returncode, 0)
            self.assertGreater(self.state(project)["ledger_completion_cursor"], 0)

            second = self.run_watch(project, "gate")
            self.assertEqual(second.returncode, 2)
            self.assertIn("Watch ledger requires intent", second.stderr)

    def test_feedback_requires_disposition_and_check_does_not_ack(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.run_watch(project, "intent", "implement storage")
            feedback_file = project / ".agent-debate" / "watch" / "feedback.md"
            feedback_file.write_text("\n[time] [watcher] fix next_id validation\n")

            first = self.run_watch(project, "gate")
            self.assertEqual(first.returncode, 2)
            self.assertIn("feedback accept|deny|park", first.stderr)

            second = self.run_watch(project, "gate")
            self.assertEqual(second.returncode, 2)
            self.assertEqual(self.state(project)["feedback_cursor"], 0)

            check = self.run_watch(project, "check")
            self.assertEqual(check.returncode, 0)
            self.assertIn("fix next_id validation", check.stdout)
            self.assertEqual(self.state(project)["feedback_cursor"], 0)

            disposition = self.run_watch(project, "feedback", "accept", "added validation")
            self.assertEqual(disposition.returncode, 0)
            self.assertEqual(self.state(project)["feedback_cursor"], feedback_file.stat().st_size)

            passed = self.run_watch(project, "gate")
            self.assertEqual(passed.returncode, 0)
            self.assertIn("feedback-action: accept added validation", self.journal(project))

    def test_escape_hatch_logs_bypass(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)

            result = self.run_watch(project, "gate", env={"WATCH_LEDGER_OFF": "1"})

            self.assertEqual(result.returncode, 0)
            self.assertIn("ledger-gate bypassed", self.journal(project))

    def test_feedback_inactive_does_not_create_runtime_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = Path(tmpdir) / "project"
            project.mkdir()

            result = self.run_watch(project, "feedback", "accept", "not active")

            self.assertEqual(result.returncode, 0)
            self.assertIn("watch mode is not active", result.stdout)
            self.assertFalse((project / ".agent-debate").exists())

    def test_stale_state_lock_is_recovered(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.run_watch(project, "intent", "implement storage")
            lock_path = project / ".agent-debate" / "watch" / "state.json.lock"
            lock_path.mkdir()
            stale_time = time.time() - 400
            os.utime(lock_path, (stale_time, stale_time))

            result = self.run_watch(project, "gate")

            self.assertEqual(result.returncode, 0)
            self.assertFalse(lock_path.exists())
            self.assertGreater(self.state(project)["ledger_completion_cursor"], 0)

    def test_stop_hook_warns_without_blocking_or_logging(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            (project / ".agent-debate" / "watch" / "feedback.md").write_text("feedback\n")

            result = self.run_watch(project, "hook-stop")

            self.assertEqual(result.returncode, 0)
            self.assertIn("Unread watcher feedback", result.stderr)
            self.assertNotIn("Stop hook: turn completed", self.journal(project))

    def test_malformed_state_gate_fails_open(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            (project / ".agent-debate" / "watch" / "state.json").write_text("{bad json\n")

            result = self.run_watch(project, "gate")

            self.assertEqual(result.returncode, 0)
            self.assertIn("allowing completion", result.stderr)

    def test_watcher_loop_sees_untracked_files_and_trailing_no_feedback_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            prompt_path = project / "prompt.txt"
            watcher = project / "watcher.sh"
            watcher.write_text(
                "#!/usr/bin/env bash\n"
                "cat > \"$WATCH_TEST_PROMPT\"\n"
                "printf 'looked around\\nNO_FEEDBACK\\n'\n"
            )
            watcher.chmod(0o755)
            (project / "debate.config.json").write_text(
                json.dumps(
                    {
                        "aliases": {
                            "dummy": {
                                "name": "Dummy",
                                "provider": "dummy",
                                "command_template": [str(watcher)],
                                "prompt_transport": "stdin",
                            }
                        }
                    }
                )
                + "\n"
            )
            (project / "new_file.txt").write_text("untracked\n")

            env = {
                "AGENT_DEBATE_HOST_PROVIDER": "codex",
                "WATCH_INTERVAL": "1",
                "WATCH_TEST_PROMPT": str(prompt_path),
            }
            start = self.run_watch(project, "start", "--watcher", "dummy", env=env)
            self.assertEqual(start.returncode, 0, start.stderr)
            self.run_watch(project, "intent", "exercise watcher prompt", env=env)
            time.sleep(2.3)
            stop = self.run_watch(project, "stop", env=env)
            self.assertEqual(stop.returncode, 0, stop.stderr)

            prompt = prompt_path.read_text()
            archive = self.latest_archive(project)
            self.assertIn("Current git status --short", prompt)
            self.assertIn("?? new_file.txt", prompt)
            self.assertEqual((archive / "feedback.md").read_text(), "")

    def test_journal_cursor_prevents_duplicate_feedback_on_unchanged_journal(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            watcher = project / "watcher.sh"
            watcher.write_text(
                "#!/usr/bin/env bash\n"
                "prompt=$(cat)\n"
                "if printf '%s' \"$prompt\" | grep -q 'intent:'; then\n"
                "  printf 'review this once\\n'\n"
                "else\n"
                "  printf 'NO_FEEDBACK\\n'\n"
                "fi\n"
            )
            watcher.chmod(0o755)
            (project / "debate.config.json").write_text(
                json.dumps(
                    {
                        "aliases": {
                            "dummy": {
                                "name": "Dummy",
                                "provider": "dummy",
                                "command_template": [str(watcher)],
                                "prompt_transport": "stdin",
                            }
                        }
                    }
                )
                + "\n"
            )

            env = {"AGENT_DEBATE_HOST_PROVIDER": "codex", "WATCH_INTERVAL": "1"}
            start = self.run_watch(project, "start", "--watcher", "dummy", env=env)
            self.assertEqual(start.returncode, 0, start.stderr)
            self.run_watch(project, "intent", "one thing", env=env)
            time.sleep(2.8)
            stop = self.run_watch(project, "stop", env=env)
            self.assertEqual(stop.returncode, 0, stop.stderr)

            feedback = (self.latest_archive(project) / "feedback.md").read_text()
            self.assertEqual(feedback.count("review this once"), 1)


if __name__ == "__main__":
    unittest.main()
