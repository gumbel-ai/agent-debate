#!/usr/bin/env bash
# Task/todo completion adapter for loop mode. It is intentionally quiet on
# success. Handles Claude TaskUpdate + TodoWrite and Codex update_plan.

set -euo pipefail

HOOK_INPUT="$(cat || true)"

analysis="$(HOOK_INPUT="$HOOK_INPUT" python3 - <<'PY' 2>/dev/null || printf '0\n\n'
import json
import os
from collections import Counter

COMPLETED_STATUSES = {"complete", "completed", "done"}


def as_dict(value):
    return value if isinstance(value, dict) else {}


def normalized_status(value):
    return str(value).strip().lower()


def item_completed_counts(items, text_keys):
    if not isinstance(items, list):
        return Counter()

    completed = Counter()
    for item in items:
        if not isinstance(item, dict):
            continue
        status = normalized_status(item.get("status", ""))
        if status not in COMPLETED_STATUSES:
            continue
        text = ""
        for key in text_keys:
            if item.get(key):
                text = item[key]
                break
        completed[str(text)] += 1
    return completed


def plan_completed_counts(plan):
    return item_completed_counts(plan, ("step", "text", "content"))


def todo_completed_counts(todos):
    return item_completed_counts(todos, ("content", "activeForm", "text"))


def parse_update_plan_arguments(raw):
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str):
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return as_dict(parsed)


def previous_codex_completed_counts(transcript_path):
    if not isinstance(transcript_path, str) or not transcript_path:
        return None
    if not os.path.exists(transcript_path):
        return None

    latest = None
    with open(transcript_path, "r", encoding="utf-8") as transcript:
        for line in transcript:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") != "response_item":
                continue
            payload = as_dict(entry.get("payload"))
            if payload.get("type") != "function_call" or payload.get("name") != "update_plan":
                continue
            arguments = parse_update_plan_arguments(payload.get("arguments"))
            latest = plan_completed_counts(arguments.get("plan"))
    return latest


def previous_claude_todo_completed_counts(transcript_path):
    if not isinstance(transcript_path, str) or not transcript_path:
        return None
    if not os.path.exists(transcript_path):
        return None

    latest = None
    with open(transcript_path, "r", encoding="utf-8") as transcript:
        for line in transcript:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            message = as_dict(entry.get("message"))
            content = message.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") != "tool_use" or block.get("name") != "TodoWrite":
                    continue
                block_input = as_dict(block.get("input"))
                latest = todo_completed_counts(block_input.get("todos"))
    return latest


try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
except json.JSONDecodeError:
    data = {}

data = as_dict(data)
tool_name = data.get("tool_name", "")
tool_input = as_dict(data.get("tool_input"))
should_check = False

if tool_name == "TaskUpdate":
    should_check = normalized_status(tool_input.get("status", "")) in COMPLETED_STATUSES
elif tool_name == "TodoWrite":
    current_completed = todo_completed_counts(tool_input.get("todos"))
    if current_completed:
        previous_completed = previous_claude_todo_completed_counts(data.get("transcript_path", ""))
        should_check = previous_completed is None or bool(current_completed - previous_completed)
elif tool_name == "update_plan":
    current_completed = plan_completed_counts(tool_input.get("plan"))
    if current_completed:
        previous_completed = previous_codex_completed_counts(data.get("transcript_path", ""))
        should_check = previous_completed is None or bool(current_completed - previous_completed)

cwd = data.get("cwd", "")
if not isinstance(cwd, str):
    cwd = ""

print("1" if should_check else "0")
print(cwd)
PY
)"

should_check="$(printf '%s\n' "$analysis" | sed -n '1p')"
project_dir="$(printf '%s\n' "$analysis" | sed -n '2p')"

if [[ "$should_check" != "1" ]]; then
  exit 0
fi

find_loop_root() {
  local dir="$1"

  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/.agent-debate/loop/state.json" ]]; then
      printf '%s' "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done

  printf '%s' "$1"
}

if [[ -z "$project_dir" || ! -d "$project_dir" ]]; then
  project_dir="$PWD"
fi
project_dir="$(cd "$project_dir" && pwd)"
project_dir="$(find_loop_root "$project_dir")"

loop_script="$project_dir/loop.sh"
if [[ ! -x "$loop_script" ]]; then
  loop_script="$HOME/.agent-debate/loop.sh"
fi

if [[ ! -x "$loop_script" ]]; then
  exit 0
fi

cd "$project_dir"
exec "$loop_script" gate
