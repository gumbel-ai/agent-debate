#!/usr/bin/env bash
# Stop-hook adapter for watch mode. It is intentionally quiet on success.

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

find_watch_root() {
  local dir="$1"

  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/.agent-debate/watch/state.json" ]]; then
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
project_dir="$(find_watch_root "$project_dir")"

watch_script="$project_dir/watch.sh"
if [[ ! -x "$watch_script" ]]; then
  watch_script="$HOME/.agent-debate/watch.sh"
fi

if [[ ! -x "$watch_script" ]]; then
  exit 0
fi

cd "$project_dir"
exec "$watch_script" hook-stop
