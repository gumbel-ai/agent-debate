import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ORCHESTRATE = ROOT / "orchestrate.sh"


DUMMY_AGENT = '''#!/usr/bin/env python3
"""Deterministic stand-in for an agent CLI in orchestrator tests.

Reads the prompt (last argument), extracts the embedded debate document,
adds its required turn tag, and marks the proposal converged. Behavior
toggles via DUMMY_MODE for failure-injection tests.
"""
import os
import sys

prompt = sys.argv[-1]
doc = prompt[prompt.rfind("# Debate:"):]

name_marker = "You are **Dummy"
idx = prompt[prompt.find(name_marker) + len(name_marker)]
round_marker = "This is Round **"
rnd = prompt[prompt.find(round_marker) + len(round_marker)]
tag = "[A" + idx + "-R" + rnd + "]"

mode = os.environ.get("DUMMY_MODE", "converge")

if mode == "drop_history":
    # Simulate a model that rewrites the file and loses an earlier turn tag.
    doc = doc.replace("[A1-R1] dummy edit by agent 1", "rewritten history")

doc = doc.replace("STATUS: OPEN", "STATUS: CONVERGED", 1)
doc += "\\n" + tag + " dummy edit by agent " + idx + "\\n"
sys.stdout.write(doc)
'''


class OrchestrateE2ETest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project = Path(self.tmpdir.name) / "project"
        self.project.mkdir()
        self.dummy = self.project / "dummy_agent.py"
        self.dummy.write_text(DUMMY_AGENT)
        self.dummy.chmod(0o755)
        (self.project / "debate.config.json").write_text(
            json.dumps(
                {
                    "aliases": {
                        "dummy1": {
                            "name": "Dummy1",
                            "provider": "d1",
                            "command_template": ["python3", str(self.dummy)],
                            "prompt_transport": "arg",
                        },
                        "dummy2": {
                            "name": "Dummy2",
                            "provider": "d2",
                            "command_template": ["python3", str(self.dummy)],
                            "prompt_transport": "arg",
                        },
                    },
                    "debate": {"default_agents": ["dummy1", "dummy2"], "min_agents": 2, "max_agents": 4},
                }
            )
        )

    def tearDown(self):
        self.tmpdir.cleanup()

    def run_orchestrate(self, *args, env_overrides=None):
        env = os.environ.copy()
        env["AGENT_DEBATE_HOST_PROVIDER"] = "none"
        if env_overrides:
            env.update(env_overrides)
        return subprocess.run(
            [str(ORCHESTRATE), *args],
            cwd=self.project,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def debate_file(self):
        files = sorted((self.project / "debates").glob("*.md"))
        self.assertEqual(len(files), 1)
        return files[0]

    def test_full_debate_converges_with_special_character_topic(self):
        result = self.run_orchestrate(
            "--topic", "use X | Y & Z\\ or not?", "--rounds", "2", "--no-plan"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CONVERGED at Round 1", result.stdout)

        text = self.debate_file().read_text()
        self.assertIn("# Debate: use X | Y & Z\\ or not?", text)
        self.assertIn("[A1-R1] dummy edit by agent 1", text)
        self.assertIn("[A2-R1] dummy edit by agent 2", text)

        state = json.loads(self.debate_file().with_suffix("").with_suffix("").parent.joinpath(
            self.debate_file().name.replace(".md", ".state.json")
        ).read_text())
        self.assertEqual(state["status"], "converged")

    def test_history_dropping_agent_is_rejected(self):
        result = self.run_orchestrate(
            "--topic", "preservation check", "--rounds", "2", "--no-plan",
            env_overrides={"DUMMY_MODE": "drop_history"},
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("dropped earlier debate content", result.stdout)
        self.assertIn("dropped earlier turn tags: [A1-R1]", result.stdout)

    def test_hung_agent_times_out_instead_of_blocking(self):
        hang = self.project / "hang.py"
        hang.write_text("import time\ntime.sleep(60)\n")
        (self.project / "debate.config.json").write_text(
            json.dumps(
                {
                    "aliases": {
                        "h1": {"name": "Dummy1", "provider": "d1",
                               "command_template": ["python3", str(hang)], "prompt_transport": "arg"},
                        "h2": {"name": "Dummy2", "provider": "d2",
                               "command_template": ["python3", str(hang)], "prompt_transport": "arg"},
                    },
                    "debate": {"default_agents": ["h1", "h2"], "min_agents": 2, "max_agents": 4},
                }
            )
        )
        result = self.run_orchestrate(
            "--topic", "timeout check", "--rounds", "1", "--no-plan",
            env_overrides={"AGENT_DEBATE_TURN_TIMEOUT": "2"},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("timed out after 2s", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
