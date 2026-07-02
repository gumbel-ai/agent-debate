import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks" / "loop-task-check.sh"


class LoopTaskCheckTest(unittest.TestCase):
    def make_project(self, tmpdir, exit_code=0):
        project = Path(tmpdir) / "project"
        loop_dir = project / ".agent-debate" / "loop"
        loop_dir.mkdir(parents=True)
        (loop_dir / "state.json").write_text("{}\n")
        log = Path(tmpdir) / "loop.log"
        loop = project / "loop.sh"
        loop.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" >> \"${LOOP_TEST_LOG}\"\n"
            f"exit {exit_code}\n"
        )
        loop.chmod(0o755)
        return project, log

    def run_hook(self, payload, project, log):
        env = os.environ.copy()
        env["LOOP_TEST_LOG"] = str(log)
        return subprocess.run(
            [str(HOOK)],
            input=json.dumps(payload),
            text=True,
            cwd=project,
            env=env,
            capture_output=True,
            check=False,
        )

    def assert_checked(self, log):
        self.assertEqual(log.read_text(), "gate\n")

    def test_claude_completed_task_runs_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            result = self.run_hook(
                {
                    "tool_name": "TaskUpdate",
                    "tool_input": {"taskId": "1", "status": "completed"},
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assert_checked(log)

    def test_claude_non_completed_task_does_not_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            result = self.run_hook(
                {
                    "tool_name": "TaskUpdate",
                    "tool_input": {"taskId": "1", "status": "in_progress"},
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assertFalse(log.exists())

    def test_claude_done_status_runs_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            result = self.run_hook(
                {
                    "tool_name": "TaskUpdate",
                    "tool_input": {"taskId": "1", "status": "done"},
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assert_checked(log)

    def test_check_failure_propagates(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir, exit_code=2)
            result = self.run_hook(
                {
                    "tool_name": "TaskUpdate",
                    "tool_input": {"taskId": "1", "status": "completed"},
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 2)
            self.assert_checked(log)

    def test_claude_todowrite_new_completed_runs_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            result = self.run_hook(
                {
                    "tool_name": "TodoWrite",
                    "tool_input": {
                        "todos": [
                            {"content": "alpha", "status": "completed"},
                            {"content": "beta", "status": "pending"},
                        ]
                    },
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assert_checked(log)

    def test_claude_todowrite_no_completed_does_not_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            result = self.run_hook(
                {
                    "tool_name": "TodoWrite",
                    "tool_input": {
                        "todos": [
                            {"content": "alpha", "status": "in_progress"},
                            {"content": "beta", "status": "pending"},
                        ]
                    },
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assertFalse(log.exists())

    def test_claude_todowrite_already_completed_does_not_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            transcript = Path(tmpdir) / "transcript.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "tool_use",
                                    "name": "TodoWrite",
                                    "input": {
                                        "todos": [
                                            {"content": "alpha", "status": "completed"},
                                            {"content": "beta", "status": "pending"},
                                        ]
                                    },
                                }
                            ],
                        },
                    }
                )
                + "\n"
            )
            result = self.run_hook(
                {
                    "tool_name": "TodoWrite",
                    "tool_input": {
                        "todos": [
                            {"content": "alpha", "status": "completed"},
                            {"content": "beta", "status": "in_progress"},
                        ]
                    },
                    "transcript_path": str(transcript),
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assertFalse(log.exists())

    def test_claude_todowrite_newly_completed_with_transcript_runs_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            transcript = Path(tmpdir) / "transcript.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "tool_use",
                                    "name": "TodoWrite",
                                    "input": {
                                        "todos": [
                                            {"content": "alpha", "status": "completed"},
                                            {"content": "beta", "status": "pending"},
                                        ]
                                    },
                                }
                            ],
                        },
                    }
                )
                + "\n"
            )
            result = self.run_hook(
                {
                    "tool_name": "TodoWrite",
                    "tool_input": {
                        "todos": [
                            {"content": "alpha", "status": "completed"},
                            {"content": "beta", "status": "completed"},
                        ]
                    },
                    "transcript_path": str(transcript),
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assert_checked(log)

    def test_codex_new_completed_plan_item_runs_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            transcript = Path(tmpdir) / "rollout.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "response_item",
                        "payload": {
                            "type": "function_call",
                            "name": "update_plan",
                            "arguments": json.dumps(
                                {
                                    "plan": [
                                        {"step": "alpha", "status": "pending"},
                                        {"step": "beta", "status": "pending"},
                                    ]
                                }
                            ),
                        },
                    }
                )
                + "\n"
            )
            result = self.run_hook(
                {
                    "tool_name": "update_plan",
                    "tool_input": {
                        "plan": [
                            {"step": "alpha", "status": "completed"},
                            {"step": "beta", "status": "pending"},
                        ]
                    },
                    "transcript_path": str(transcript),
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assert_checked(log)

    def test_codex_completed_plan_without_transcript_runs_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            result = self.run_hook(
                {
                    "tool_name": "update_plan",
                    "tool_input": {
                        "plan": [
                            {"step": "alpha", "status": "completed"},
                            {"step": "beta", "status": "pending"},
                        ]
                    },
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assert_checked(log)

    def test_codex_already_completed_plan_item_does_not_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            transcript = Path(tmpdir) / "rollout.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "response_item",
                        "payload": {
                            "type": "function_call",
                            "name": "update_plan",
                            "arguments": json.dumps(
                                {
                                    "plan": [
                                        {"step": "alpha", "status": "completed"},
                                        {"step": "beta", "status": "pending"},
                                    ]
                                }
                            ),
                        },
                    }
                )
                + "\n"
            )
            result = self.run_hook(
                {
                    "tool_name": "update_plan",
                    "tool_input": {
                        "plan": [
                            {"step": "alpha", "status": "completed"},
                            {"step": "beta", "status": "in_progress"},
                        ]
                    },
                    "transcript_path": str(transcript),
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assertFalse(log.exists())

    def test_codex_reordered_completed_plan_item_does_not_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            transcript = Path(tmpdir) / "rollout.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "response_item",
                        "payload": {
                            "type": "function_call",
                            "name": "update_plan",
                            "arguments": json.dumps(
                                {
                                    "plan": [
                                        {"step": "alpha", "status": "completed"},
                                        {"step": "beta", "status": "pending"},
                                    ]
                                }
                            ),
                        },
                    }
                )
                + "\n"
            )
            result = self.run_hook(
                {
                    "tool_name": "update_plan",
                    "tool_input": {
                        "plan": [
                            {"step": "beta", "status": "in_progress"},
                            {"step": "alpha", "status": "completed"},
                        ]
                    },
                    "transcript_path": str(transcript),
                    "cwd": str(project),
                },
                project,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assertFalse(log.exists())

    def test_nested_cwd_finds_loop_root(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            project, log = self.make_project(tmpdir)
            nested = project / "subdir" / "deeper"
            nested.mkdir(parents=True)
            result = self.run_hook(
                {
                    "tool_name": "TaskUpdate",
                    "tool_input": {"taskId": "1", "status": "completed"},
                    "cwd": str(nested),
                },
                nested,
                log,
            )

            self.assertEqual(result.returncode, 0)
            self.assert_checked(log)


if __name__ == "__main__":
    unittest.main()
