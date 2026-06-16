#!/usr/bin/env python3
"""Normalize agent CLI responses before debate-file validation."""

from __future__ import annotations

import re
import sys


DEBATE_START_RE = re.compile(r"(?m)^[ \t]*# Debate: ")


def normalize_agent_response(response: str) -> str:
    """Return the debate document when a CLI adds text before it.

    Recent model/CLI responses sometimes prepend a short status line before the
    requested markdown document. Keep truly non-debate output unchanged so the
    existing raw-output failure path remains informative.
    """

    match = DEBATE_START_RE.search(response)
    if not match:
        return response
    return response[match.start() :]


def main() -> int:
    sys.stdout.write(normalize_agent_response(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
