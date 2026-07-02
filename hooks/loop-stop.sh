#!/usr/bin/env bash
# Stop-hook adapter for loop mode. Blocks the stop once (exit 2) when
# actionable reviewer feedback is unread, so the primary actually sees it.

set -euo pipefail

HOOK_INPUT="$(cat || true)"

project_dir_from_input() {
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return
  fi

  HOOK_INPUT="$HOOK_INPUT" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
except json.JSONDecodeError:
    data = {}

cwd = data.get("cwd", "")
if isinstance(cwd, str):
    print(cwd)
PY
}

stop_hook_active_from_input() {
  HOOK_INPUT="$HOOK_INPUT" python3 - <<'PY' 2>/dev/null || printf '0'
import json
import os

try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
except json.JSONDecodeError:
    data = {}

print("1" if data.get("stop_hook_active") is True else "0")
PY
}

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

project_dir="$(project_dir_from_input)"
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

LOOP_STOP_ACTIVE="$(stop_hook_active_from_input)"
export LOOP_STOP_ACTIVE

cd "$project_dir"
exec "$loop_script" hook-stop
