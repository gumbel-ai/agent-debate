import textwrap
import unittest

from agent_response_parser import normalize_agent_response


DEBATE_BODY = textwrap.dedent(
    """\
    # Debate: parser smoke

    ## Proposal

    STATUS: OPEN

    [A2-R1] Response.

    ## Dispute Log

    | Round | Agent | Section | What Changed | Why | Status |
    |-------|-------|---------|--------------|-----|--------|
    | 1 | Agent | Proposal | Added response | Test | CLOSED |
    """
)


class AgentResponseParserTest(unittest.TestCase):
    def test_accepts_plain_debate_document(self):
        self.assertEqual(normalize_agent_response(DEBATE_BODY), DEBATE_BODY)

    def test_strips_preamble_before_debate_document(self):
        raw = "All claims verified. Writing the response now.\n\n" + DEBATE_BODY

        self.assertEqual(normalize_agent_response(raw), DEBATE_BODY)

    def test_leaves_non_debate_output_unchanged(self):
        raw = "I cannot edit this debate because context is missing."

        self.assertEqual(normalize_agent_response(raw), raw)


if __name__ == "__main__":
    unittest.main()
