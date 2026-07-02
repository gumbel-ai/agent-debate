import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOOP = ROOT / "loop.sh"


class LoopLedgerContractTest(unittest.TestCase):
    def make_project(self, tmpdir):
        project = Path(tmpdir) / "project"
        loop_dir = project / ".agent-debate" / "loop"
        loop_dir.mkdir(parents=True)
        journal = loop_dir / "journal.md"
        feedback = loop_dir / "feedback.md"
        journal.write_text("")
        feedback.write_text("")
        self.write_state(project)
        return project

    def write_state(self, project, **overrides):
        loop_dir = project / ".agent-debate" / "loop"
        state = {
            "host_provider": "codex",
            "reviewer_provider": "test",
            "reviewer_alias": "dummy",
            "task": "test task",
            "journal_path": str(loop_dir / "journal.md"),
            "feedback_path": str(loop_dir / "feedback.md"),
            "feedback_cursor": 0,
            "feedback_seen_cursor": 0,
            "ledger_completion_cursor": 0,
            "ledger_bypass_once": 0,
            "journal_review_offset": 0,
            "user_distill_offset": 0,
            "last_review_signature": "",
            "last_change_at": 0,
            "consecutive_failures": 0,
            "last_failure_message": "",
            "loop_pid": "",
            "started_at": "2026-06-16T00:00:00+00:00",
            "loop_interval": 1,
            "idle_timeout": 0,
        }
        state.update(overrides)
        (loop_dir / "state.json").write_text(json.dumps(state) + "\n")

    def run_loop(self, project, *args, env=None):
        full_env = os.environ.copy()
        full_env["HOME"] = str(project / "home")
        if env:
            full_env.update(env)
        return subprocess.run(
            [str(LOOP), *args],
            cwd=project,
            env=full_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def state(self, project):
        return json.loads((project / ".agent-debate" / "loop" / "state.json").read_text())

    def journal(self, project):
        return (project / ".agent-debate" / "loop" / "journal.md").read_text()

    def feedback_file(self, project):
        return project / ".agent-debate" / "loop" / "feedback.md"

    def latest_archive(self, project):
        archives = sorted((project / ".agent-debate" / "loop" / "archive").iterdir())
        return archives[-1]

    def wait_until(self, predicate, timeout=8):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return
            time.sleep(0.1)
        self.fail("timed out waiting for condition")

    def write_dummy_config(self, project, command, transport="stdin"):
        (project / "debate.config.json").write_text(
            json.dumps(
                {
                    "aliases": {
                        "dummy": {
                            "name": "Dummy",
                            "provider": "dummy",
                            "command_template": command,
                            "prompt_transport": transport,
                        }
                    }
                }
            )
            + "\n"
        )

    def test_gate_requires_new_intent_per_completion(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)

            missing = self.run_loop(project, "gate")
            self.assertEqual(missing.returncode, 2)
            self.assertIn("loop.sh intent", missing.stderr)

            intent = self.run_loop(project, "intent", "implement CLI and run tests")
            self.assertEqual(intent.returncode, 0)

            first = self.run_loop(project, "gate")
            self.assertEqual(first.returncode, 0)
            self.assertGreater(self.state(project)["ledger_completion_cursor"], 0)

            second = self.run_loop(project, "gate")
            self.assertEqual(second.returncode, 2)
            self.assertIn("Loop ledger requires intent", second.stderr)

    def test_gate_requires_task_statement(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.write_state(project, task="")
            self.run_loop(project, "intent", "implement something")

            blocked = self.run_loop(project, "gate")
            self.assertEqual(blocked.returncode, 2)
            self.assertIn("requires a task statement", blocked.stderr)

            set_task = self.run_loop(project, "task", "build the CLI")
            self.assertEqual(set_task.returncode, 0)
            self.assertEqual(self.state(project)["task"], "build the CLI")
            self.assertIn("task: build the CLI", self.journal(project))

            passed = self.run_loop(project, "gate")
            self.assertEqual(passed.returncode, 0)

    def test_feedback_requires_disposition_and_check_does_not_ack(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.run_loop(project, "intent", "implement storage")
            feedback_file = self.feedback_file(project)
            feedback_file.write_text("\n[time] [reviewer] fix next_id validation\n")

            first = self.run_loop(project, "gate")
            self.assertEqual(first.returncode, 2)
            self.assertIn("feedback accept|deny|park", first.stderr)

            second = self.run_loop(project, "gate")
            self.assertEqual(second.returncode, 2)
            self.assertEqual(self.state(project)["feedback_cursor"], 0)

            check = self.run_loop(project, "check")
            self.assertEqual(check.returncode, 0)
            self.assertIn("fix next_id validation", check.stdout)
            self.assertEqual(self.state(project)["feedback_cursor"], 0)
            self.assertEqual(
                self.state(project)["feedback_seen_cursor"],
                feedback_file.stat().st_size,
            )

            disposition = self.run_loop(project, "feedback", "accept", "added validation")
            self.assertEqual(disposition.returncode, 0)
            self.assertEqual(self.state(project)["feedback_cursor"], feedback_file.stat().st_size)

            passed = self.run_loop(project, "gate")
            self.assertEqual(passed.returncode, 0)
            self.assertIn("feedback-action: accept added validation", self.journal(project))

    def test_feedback_without_check_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.run_loop(project, "intent", "implement storage")
            self.feedback_file(project).write_text("\n[time] [reviewer] fix parsing\n")

            disposition = self.run_loop(project, "feedback", "accept", "sure")
            self.assertEqual(disposition.returncode, 1)
            self.assertIn("check first", disposition.stderr)
            self.assertEqual(self.state(project)["feedback_cursor"], 0)

            blocked = self.run_loop(project, "gate")
            self.assertEqual(blocked.returncode, 2)

    def test_disposition_acks_only_seen_feedback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.run_loop(project, "intent", "implement storage")
            feedback_file = self.feedback_file(project)
            feedback_file.write_text("\n[time] [reviewer] first note\n")

            check = self.run_loop(project, "check")
            self.assertEqual(check.returncode, 0)
            seen = self.state(project)["feedback_seen_cursor"]

            with feedback_file.open("a") as f:
                f.write("\n[time] [reviewer] second note appended after check\n")

            disposition = self.run_loop(project, "feedback", "accept", "handled first note")
            self.assertEqual(disposition.returncode, 0)
            self.assertIn("Newer feedback arrived", disposition.stdout)
            self.assertEqual(self.state(project)["feedback_cursor"], seen)

            blocked = self.run_loop(project, "gate")
            self.assertEqual(blocked.returncode, 2)
            self.assertIn("Unread reviewer feedback", blocked.stderr)

    def test_system_feedback_does_not_block_gate_or_stop(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.run_loop(project, "intent", "implement storage")
            self.feedback_file(project).write_text(
                "\n[time] [loop-system] reviewer command failed: codex not found\n"
            )

            gate = self.run_loop(project, "gate")
            self.assertEqual(gate.returncode, 0)

            stop = self.run_loop(project, "hook-stop")
            self.assertEqual(stop.returncode, 0)
            self.assertIn("infrastructure", stop.stderr)

    def test_check_clamps_cursor_after_feedback_file_truncation(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.write_state(project, feedback_cursor=999)
            self.feedback_file(project).write_text("new feedback\n")

            result = self.run_loop(project, "check")

            self.assertEqual(result.returncode, 0)
            self.assertIn("new feedback", result.stdout)

    def test_escape_hatch_env_logs_bypass(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)

            result = self.run_loop(project, "gate", env={"LOOP_LEDGER_OFF": "1"})

            self.assertEqual(result.returncode, 0)
            self.assertIn("ledger-gate bypassed", self.journal(project))

    def test_bypass_command_allows_exactly_one_gate(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)

            bypass = self.run_loop(project, "bypass", "hooks fired for unrelated todo")
            self.assertEqual(bypass.returncode, 0)
            self.assertEqual(self.state(project)["ledger_bypass_once"], 1)

            first = self.run_loop(project, "gate")
            self.assertEqual(first.returncode, 0)
            self.assertEqual(self.state(project)["ledger_bypass_once"], 0)

            second = self.run_loop(project, "gate")
            self.assertEqual(second.returncode, 2)

    def test_feedback_inactive_does_not_create_runtime_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = Path(tmpdir) / "project"
            project.mkdir()

            result = self.run_loop(project, "feedback", "accept", "not active")

            self.assertEqual(result.returncode, 0)
            self.assertIn("loop mode is not active", result.stdout)
            self.assertFalse((project / ".agent-debate").exists())

    def test_stale_state_lock_is_recovered(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.run_loop(project, "intent", "implement storage")
            lock_path = project / ".agent-debate" / "loop" / "state.json.lock"
            lock_path.mkdir()
            stale_time = time.time() - 400
            os.utime(lock_path, (stale_time, stale_time))

            result = self.run_loop(project, "gate")

            self.assertEqual(result.returncode, 0)
            self.assertFalse(lock_path.exists())
            self.assertGreater(self.state(project)["ledger_completion_cursor"], 0)

    def test_stop_hook_blocks_once_on_actionable_feedback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            self.feedback_file(project).write_text("\n[time] [reviewer] real feedback\n")

            blocked = self.run_loop(project, "hook-stop")
            self.assertEqual(blocked.returncode, 2)
            self.assertIn("Unread reviewer feedback", blocked.stderr)
            self.assertNotIn("Stop hook: turn completed", self.journal(project))

            continued = self.run_loop(project, "hook-stop", env={"LOOP_STOP_ACTIVE": "1"})
            self.assertEqual(continued.returncode, 0)
            self.assertIn("still pending", continued.stderr)

            self.feedback_file(project).write_text("")
            clear = self.run_loop(project, "hook-stop")
            self.assertEqual(clear.returncode, 0)
            self.assertEqual(clear.stderr, "")

    def test_malformed_state_gate_fails_open(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            (project / ".agent-debate" / "loop" / "state.json").write_text("{bad json\n")

            result = self.run_loop(project, "gate")

            self.assertEqual(result.returncode, 0)
            self.assertIn("allowing completion", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_start_fails_fast_when_reviewer_command_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = Path(tmpdir) / "project"
            project.mkdir()
            self.write_dummy_config(project, ["/nonexistent-reviewer-binary-xyz"])

            env = {"AGENT_DEBATE_HOST_PROVIDER": "codex"}
            result = self.run_loop(project, "start", "--reviewer", "dummy", env=env)

            self.assertEqual(result.returncode, 1)
            self.assertIn("not found on PATH", result.stderr)
            self.assertFalse((project / ".agent-debate" / "loop" / "loop.pid").exists())

    def test_runtime_instructions_use_resolved_loop_script(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)

            missing = self.run_loop(project, "gate")

            self.assertEqual(missing.returncode, 2)
            self.assertNotIn("./loop.sh", missing.stderr)
            self.assertIn(f"Run: {LOOP} intent", missing.stderr)

            self.run_loop(project, "intent", "handle feedback")
            self.feedback_file(project).write_text("feedback\n")

            blocked = self.run_loop(project, "gate")

            self.assertEqual(blocked.returncode, 2)
            self.assertNotIn("./loop.sh", blocked.stderr)
            self.assertIn(f"{LOOP} feedback", blocked.stderr)

            start_project = Path(tmpdir) / "start-project"
            start_project.mkdir()
            self.write_dummy_config(start_project, ["/bin/cat"])
            env = {
                "AGENT_DEBATE_HOST_PROVIDER": "codex",
                "LOOP_INTERVAL": "60",
            }
            start = self.run_loop(start_project, "start", "--reviewer", "dummy", env=env)
            try:
                self.assertEqual(start.returncode, 0, start.stderr)
                self.assertNotIn("./loop.sh", start.stdout)
                self.assertIn(f"{LOOP} intent", start.stdout)
                self.assertIn(f"{LOOP} feedback", start.stdout)
            finally:
                self.run_loop(start_project, "stop", env=env)

    def test_reviewer_prompt_includes_task_diff_and_untracked_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            prompt_path = project / "prompt.txt"
            reviewer = project / "reviewer.sh"
            reviewer.write_text(
                "#!/usr/bin/env bash\n"
                "cat > \"$LOOP_TEST_PROMPT\"\n"
                "printf 'looked around\\n`NO_FEEDBACK`.\\n'\n"
            )
            reviewer.chmod(0o755)
            self.write_dummy_config(project, [str(reviewer)])
            (project / "new_file.txt").write_text("untracked\n")

            env = {
                "AGENT_DEBATE_HOST_PROVIDER": "codex",
                "LOOP_INTERVAL": "1",
                "LOOP_TEST_PROMPT": str(prompt_path),
            }
            start = self.run_loop(
                project, "start", "--reviewer", "dummy", "--task", "build the widget CLI", env=env
            )
            self.assertEqual(start.returncode, 0, start.stderr)
            self.run_loop(project, "intent", "exercise reviewer prompt", env=env)
            self.wait_until(
                lambda: prompt_path.exists() and "?? new_file.txt" in prompt_path.read_text()
            )
            stop = self.run_loop(project, "stop", env=env)
            self.assertEqual(stop.returncode, 0, stop.stderr)

            prompt = prompt_path.read_text()
            archive = self.latest_archive(project)
            self.assertIn("Task statement", prompt)
            self.assertIn("build the widget CLI", prompt)
            self.assertIn("Current git status --short", prompt)
            self.assertIn("git diff HEAD", prompt)
            self.assertIn("?? new_file.txt", prompt)
            # Decorated NO_FEEDBACK ("`NO_FEEDBACK`.") must still count as no feedback.
            self.assertEqual((archive / "feedback.md").read_text(), "")

    def test_unchanged_session_skips_reviewer_calls(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            reviewer = project / "reviewer.sh"
            count_file = project / "reviewer-count.txt"
            reviewer.write_text(
                "#!/usr/bin/env bash\n"
                "count=0\n"
                "if [[ -f \"$LOOP_TEST_COUNT\" ]]; then count=$(cat \"$LOOP_TEST_COUNT\"); fi\n"
                "count=$((count + 1))\n"
                "printf '%s\\n' \"$count\" > \"$LOOP_TEST_COUNT\"\n"
                "prompt=$(cat)\n"
                "if printf '%s' \"$prompt\" | grep -q 'intent:'; then\n"
                "  printf 'review this once\\n'\n"
                "else\n"
                "  printf 'NO_FEEDBACK\\n'\n"
                "fi\n"
            )
            reviewer.chmod(0o755)
            self.write_dummy_config(project, [str(reviewer)])

            env = {
                "AGENT_DEBATE_HOST_PROVIDER": "codex",
                "LOOP_INTERVAL": "1",
                "LOOP_TEST_COUNT": str(count_file),
            }
            start = self.run_loop(project, "start", "--reviewer", "dummy", env=env)
            self.assertEqual(start.returncode, 0, start.stderr)
            self.run_loop(project, "intent", "one thing", env=env)
            # Pass 1 sees the intent and writes feedback; pass 2 sees an empty
            # journal delta (offset advanced) and returns NO_FEEDBACK.
            self.wait_until(
                lambda: count_file.exists() and int(count_file.read_text().strip()) >= 2
            )
            # From here nothing changes, so further passes must be skipped
            # without invoking the reviewer at all.
            time.sleep(3)
            settled_count = int(count_file.read_text().strip())
            stop = self.run_loop(project, "stop", env=env)
            self.assertEqual(stop.returncode, 0, stop.stderr)

            self.assertEqual(settled_count, 2)
            feedback = (self.latest_archive(project) / "feedback.md").read_text()
            self.assertEqual(feedback.count("review this once"), 1)

    def test_idle_loop_stops_itself_and_removes_hooks(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = Path(tmpdir) / "project"
            project.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            self.write_dummy_config(project, ["/bin/cat"])

            env = {
                "AGENT_DEBATE_HOST_PROVIDER": "codex",
                "LOOP_INTERVAL": "1",
                "LOOP_IDLE_TIMEOUT": "2",
            }
            start = self.run_loop(project, "start", "--reviewer", "dummy", env=env)
            self.assertEqual(start.returncode, 0, start.stderr)
            self.assertIn("Auto-stop", start.stdout)

            state_path = project / ".agent-debate" / "loop" / "state.json"
            self.wait_until(lambda: not state_path.exists(), timeout=25)

            self.assertTrue((project / ".agent-debate" / "loop" / "archive").exists())
            hooks = json.loads((project / ".codex" / "hooks.json").read_text())
            self.assertNotIn("hooks", hooks)

    def test_user_prompts_are_distilled_into_task(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = Path(tmpdir) / "project"
            project.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            reviewer = project / "reviewer.sh"
            reviewer.write_text(
                "#!/usr/bin/env bash\n"
                "prompt=$(cat)\n"
                "if printf '%s' \"$prompt\" | grep -q 'task distiller'; then\n"
                "  printf 'Build the redis-backed cache layer.\\n'\n"
                "else\n"
                "  printf 'NO_FEEDBACK\\n'\n"
                "fi\n"
            )
            reviewer.chmod(0o755)
            self.write_dummy_config(project, [str(reviewer)])

            env = {
                "AGENT_DEBATE_HOST_PROVIDER": "codex",
                "LOOP_INTERVAL": "1",
                "LOOP_IDLE_TIMEOUT": "0",
            }
            start = self.run_loop(
                project, "start", "--reviewer", "dummy", "--task", "initial task", env=env
            )
            self.assertEqual(start.returncode, 0, start.stderr)
            self.run_loop(project, "log", "user: actually build a redis cache instead", env=env)
            self.wait_until(
                lambda: self.state(project).get("task", "").startswith("Build the redis-backed"),
                timeout=15,
            )
            stop = self.run_loop(project, "stop", env=env)
            self.assertEqual(stop.returncode, 0, stop.stderr)

            journal = (self.latest_archive(project) / "journal.md").read_text()
            self.assertIn("task(auto): Build the redis-backed cache layer.", journal)

    def test_reviewer_failure_recorded_once_and_backs_off(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project = self.make_project(tmpdir)
            subprocess.run(["git", "init", "-q"], cwd=project, check=True)
            reviewer = project / "reviewer.sh"
            reviewer.write_text(
                "#!/usr/bin/env bash\n"
                "echo 'boom: cannot reach model' >&2\n"
                "exit 1\n"
            )
            reviewer.chmod(0o755)
            self.write_dummy_config(project, [str(reviewer)])

            env = {
                "AGENT_DEBATE_HOST_PROVIDER": "codex",
                "LOOP_INTERVAL": "1",
            }
            start = self.run_loop(project, "start", "--reviewer", "dummy", env=env)
            self.assertEqual(start.returncode, 0, start.stderr)
            self.wait_until(
                lambda: self.state(project).get("consecutive_failures", 0) >= 2,
                timeout=10,
            )
            stop = self.run_loop(project, "stop", env=env)
            self.assertEqual(stop.returncode, 0, stop.stderr)

            feedback = (self.latest_archive(project) / "feedback.md").read_text()
            self.assertEqual(feedback.count("boom: cannot reach model"), 1)
            self.assertIn("[loop-system]", feedback)


if __name__ == "__main__":
    unittest.main()
