#!/usr/bin/env python3
"""Debate-file parsing and rendering helpers for orchestrate.sh.

Commands:
  proposal-converged FILE      exit 0 if the Proposal section says STATUS: CONVERGED
  plan-converged FILE          exit 0 if the Plan section says PLAN_STATUS: CONVERGED
  open-disputes FILE           exit 0 if any Dispute Log row has status OPEN
  verify-preservation OLD NEW  exit 0 if NEW keeps all OLD turn tags and dispute rows
  render TEMPLATE OUT          render the debate template using DL_* env vars
"""

from __future__ import annotations

import os
import sys


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def section_body(text: str, heading: str) -> str | None:
    """Return the lines under `heading` up to the next '## ' heading."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == heading:
            start = i + 1
            break
    if start is None:
        return None
    body = []
    for line in lines[start:]:
        if line.startswith("## "):
            break
        body.append(line)
    return "\n".join(body)


def section_has_status_line(text: str, heading: str, status_line: str) -> bool:
    body = section_body(text, heading)
    if body is None:
        return False
    return any(line.strip() == status_line for line in body.splitlines())


def dispute_rows(text: str) -> list[list[str]]:
    """Data rows of the Dispute Log table. Tolerates a missing trailing pipe."""
    body = section_body(text, "## Dispute Log")
    if body is None:
        return []
    rows = []
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if not any(cells):
            continue
        if cells and cells[0] == "Round":
            continue
        if all(set(c) <= {"-", ":", " "} for c in cells if c):
            continue
        rows.append(cells)
    return rows


def has_open_disputes(text: str) -> bool:
    for cells in dispute_rows(text):
        non_empty = [c for c in cells if c]
        if non_empty and non_empty[-1] == "OPEN":
            return True
    return False


def collect_turn_tags(text: str) -> dict[str, int]:
    """Occurrence counts of well-formed turn tags like [A1-R2].

    Counts matter: the template and quoted text can mention a tag, so a
    set would miss an agent deleting one real occurrence of a duplicate.
    """
    tags: dict[str, int] = {}
    i = 0
    while True:
        i = text.find("[A", i)
        if i == -1:
            break
        end = text.find("]", i)
        if end == -1:
            break
        if end - i <= 10:
            body = text[i + 2 : end]
            agent_num, sep, round_num = body.partition("-R")
            if sep and agent_num.isdigit() and round_num.isdigit():
                tag = text[i : end + 1]
                tags[tag] = tags.get(tag, 0) + 1
        i += 2
    return tags


def cmd_verify_preservation(old_path: str, new_path: str) -> int:
    old_text = read_text(old_path)
    new_text = read_text(new_path)

    problems = []
    old_tags = collect_turn_tags(old_text)
    new_tags = collect_turn_tags(new_text)
    dropped = sorted(tag for tag, count in old_tags.items() if new_tags.get(tag, 0) < count)
    if dropped:
        problems.append(f"dropped earlier turn tags: {', '.join(dropped)}")

    old_rows = len(dispute_rows(old_text))
    new_rows = len(dispute_rows(new_text))
    if new_rows < old_rows:
        problems.append(f"dispute log shrank from {old_rows} to {new_rows} rows")

    if problems:
        for problem in problems:
            print(problem)
        return 1
    return 0


def cmd_render(template_path: str, out_path: str) -> int:
    text = read_text(template_path)

    topic = os.environ.get("DL_TOPIC", "")
    date = os.environ.get("DL_DATE", "")
    max_rounds = os.environ.get("DL_MAX_ROUNDS", "")
    constraints = os.environ.get("DL_CONSTRAINTS", "").strip()
    agent_count = int(os.environ.get("DL_AGENT_COUNT", "2"))
    agents = [
        os.environ.get("DL_AGENT1", ""),
        os.environ.get("DL_AGENT2", ""),
        os.environ.get("DL_AGENT3", ""),
        os.environ.get("DL_AGENT4", ""),
    ]
    files = [f for f in os.environ.get("DL_FILES", "").splitlines() if f.strip()]

    if files:
        file_context = "\n".join(f"- `{f.strip()}`" for f in files)
    else:
        file_context = "None specified — agents should explore as needed."

    replacements = {
        "{TOPIC}": topic,
        "{DATE}": date,
        "{MAX_ROUNDS}": max_rounds,
        "{PROBLEM_DESCRIPTION}": topic,
        "{FILE_LIST_WITH_KEY_SECTIONS}": file_context,
        "{ANY_CONSTRAINTS_OR_NON_NEGOTIABLES}": constraints or "None specified.",
        "{AGENT_1_NAME}": agents[0],
        "{AGENT_2_NAME}": agents[1],
    }
    for placeholder, value in replacements.items():
        text = text.replace(placeholder, value)

    lines = []
    for line in text.splitlines():
        if "{AGENT_3_NAME}" in line:
            if agent_count < 3:
                continue
            line = line.replace("{AGENT_3_NAME}", agents[2])
        if "{AGENT_4_NAME}" in line:
            if agent_count < 4:
                continue
            line = line.replace("{AGENT_4_NAME}", agents[3])
        lines.append(line)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    command = sys.argv[1]
    args = sys.argv[2:]

    if command == "proposal-converged" and len(args) == 1:
        return 0 if section_has_status_line(read_text(args[0]), "## Proposal", "STATUS: CONVERGED") else 1
    if command == "plan-converged" and len(args) == 1:
        return 0 if section_has_status_line(read_text(args[0]), "## Plan", "PLAN_STATUS: CONVERGED") else 1
    if command == "open-disputes" and len(args) == 1:
        return 0 if has_open_disputes(read_text(args[0])) else 1
    if command == "verify-preservation" and len(args) == 2:
        return cmd_verify_preservation(args[0], args[1])
    if command == "render" and len(args) == 2:
        return cmd_render(args[0], args[1])

    print(f"Error: unknown command or wrong arguments: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
