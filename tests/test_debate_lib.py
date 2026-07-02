import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import debate_lib  # noqa: E402


DOC = """# Debate: sample

**Status:** OPEN

## Proposal

STATUS: OPEN

[A1-R1] initial proposal
~~old claim [A1-R1]~~ [A2-R1] counter

## Parking Lot

- [A1-R1] someone wrote STATUS: CONVERGED in prose here

## Dispute Log

| Round | Agent | Section | What Changed | Why | Status |
|-------|-------|---------|--------------|-----|--------|
| | | | | | |
| 1 | A2 | Proposal | countered claim | evidence | OPEN |
"""


class SectionParsingTest(unittest.TestCase):
    def test_proposal_not_converged_despite_mention_elsewhere(self):
        self.assertFalse(
            debate_lib.section_has_status_line(DOC, "## Proposal", "STATUS: CONVERGED")
        )

    def test_proposal_converged_detected_in_section_only(self):
        converged = DOC.replace("STATUS: OPEN\n\n[A1-R1]", "STATUS: CONVERGED\n\n[A1-R1]")
        self.assertTrue(
            debate_lib.section_has_status_line(converged, "## Proposal", "STATUS: CONVERGED")
        )

    def test_plan_converged(self):
        doc = "## Plan\n\nPLAN_STATUS: CONVERGED\n\n## Parking Lot\n"
        self.assertTrue(
            debate_lib.section_has_status_line(doc, "## Plan", "PLAN_STATUS: CONVERGED")
        )
        doc_open = doc.replace("CONVERGED", "OPEN")
        self.assertFalse(
            debate_lib.section_has_status_line(doc_open, "## Plan", "PLAN_STATUS: CONVERGED")
        )


class DisputeLogTest(unittest.TestCase):
    def test_open_dispute_detected(self):
        self.assertTrue(debate_lib.has_open_disputes(DOC))

    def test_open_dispute_without_trailing_pipe_detected(self):
        doc = DOC.replace(
            "| 1 | A2 | Proposal | countered claim | evidence | OPEN |",
            "| 1 | A2 | Proposal | countered claim | evidence | OPEN",
        )
        self.assertTrue(debate_lib.has_open_disputes(doc))

    def test_closed_and_parked_do_not_block(self):
        doc = DOC.replace("| OPEN |", "| CLOSED |")
        self.assertFalse(debate_lib.has_open_disputes(doc))
        doc = DOC.replace("| OPEN |", "| PARKED |")
        self.assertFalse(debate_lib.has_open_disputes(doc))

    def test_template_empty_row_ignored(self):
        doc = DOC.replace("| 1 | A2 | Proposal | countered claim | evidence | OPEN |\n", "")
        self.assertFalse(debate_lib.has_open_disputes(doc))


class TagPreservationTest(unittest.TestCase):
    def check(self, old, new):
        with tempfile.TemporaryDirectory() as tmpdir:
            old_path = Path(tmpdir) / "old.md"
            new_path = Path(tmpdir) / "new.md"
            old_path.write_text(old)
            new_path.write_text(new)
            return subprocess.run(
                [sys.executable, str(ROOT / "debate_lib.py"), "verify-preservation", str(old_path), str(new_path)],
                capture_output=True,
                text=True,
            )

    def test_collects_tags_with_counts(self):
        self.assertEqual(
            debate_lib.collect_turn_tags(DOC), {"[A1-R1]": 3, "[A2-R1]": 1}
        )

    def test_dropping_one_duplicate_occurrence_fails(self):
        new = DOC.replace("[A1-R1] initial proposal", "rewritten proposal")
        result = self.check(DOC, new)
        self.assertEqual(result.returncode, 1)
        self.assertIn("[A1-R1]", result.stdout)

    def test_normal_addition_passes(self):
        new = DOC + "\n[A1-R2] follow-up edit\n"
        result = self.check(DOC, new)
        self.assertEqual(result.returncode, 0)

    def test_dropped_tag_fails(self):
        new = DOC.replace("~~old claim [A1-R1]~~ [A2-R1] counter", "rewritten history")
        result = self.check(DOC, new)
        self.assertEqual(result.returncode, 1)
        self.assertIn("[A2-R1]", result.stdout)

    def test_shrunk_dispute_log_fails(self):
        new = DOC.replace("| 1 | A2 | Proposal | countered claim | evidence | OPEN |\n", "")
        new += "\n[A2-R1] keep tag present\n"
        result = self.check(DOC, new)
        self.assertEqual(result.returncode, 1)
        self.assertIn("dispute log shrank", result.stdout)


class RenderTemplateTest(unittest.TestCase):
    def render(self, env_overrides):
        env = os.environ.copy()
        env.update(
            {
                "DL_TOPIC": "plain topic",
                "DL_DATE": "2026-07-02",
                "DL_MAX_ROUNDS": "3",
                "DL_CONSTRAINTS": "",
                "DL_AGENT_COUNT": "2",
                "DL_AGENT1": "Opus",
                "DL_AGENT2": "Codex",
                "DL_AGENT3": "",
                "DL_AGENT4": "",
                "DL_FILES": "",
            }
        )
        env.update(env_overrides)
        with tempfile.TemporaryDirectory() as tmpdir:
            out = Path(tmpdir) / "debate.md"
            result = subprocess.run(
                [sys.executable, str(ROOT / "debate_lib.py"), "render", str(ROOT / "TEMPLATE.md"), str(out)],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return out.read_text()

    def test_topic_with_sed_metacharacters_is_verbatim(self):
        text = self.render({"DL_TOPIC": "use X | Y & Z\\ or not?"})
        self.assertIn("# Debate: use X | Y & Z\\ or not?", text)

    def test_two_agents_drop_agent_3_and_4_lines(self):
        text = self.render({})
        self.assertNotIn("Agent 3", text)
        self.assertNotIn("Agent 4", text)
        self.assertNotIn("{AGENT_3_NAME}", text)

    def test_four_agents_keep_all_names(self):
        text = self.render(
            {"DL_AGENT_COUNT": "4", "DL_AGENT3": "Gemini", "DL_AGENT4": "Copilot"}
        )
        self.assertIn("**Agent 3:** Gemini", text)
        self.assertIn("**Agent 4:** Copilot", text)

    def test_file_list_renders_one_bullet_per_line(self):
        text = self.render({"DL_FILES": "src/a.py\nsrc/b.py\n"})
        self.assertIn("- `src/a.py`\n- `src/b.py`", text)

    def test_no_files_renders_default_text(self):
        text = self.render({})
        self.assertIn("None specified — agents should explore as needed.", text)

    def test_constraints_default(self):
        text = self.render({})
        self.assertIn("None specified.", text)


if __name__ == "__main__":
    unittest.main()
