#!/usr/bin/env bash
# UserPromptSubmit adapter for loop mode. Appends each user utterance to the
# journal so the reviewer sees intent evolve and the task distiller can run.
# Must never block the prompt: always exits 0.

set -uo pipefail

HOOK_INPUT="$(cat || true)"

analysis="$(HOOK_INPUT="$HOOK_INPUT" python3 - <<'PY' 2>/dev/null || printf '\n\n'
import json
import os

MAX_CHARS = 500

try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
except json.JSONDecodeError:
    data = {}
if not isinstance(data, dict):
    data = {}

prompt = data.get("prompt")
if not isinstance(prompt, str):
    prompt = data.get("user_prompt")
if not isinstance(prompt, str):
    prompt = ""

text = " ".join(prompt.split())
if len(text) > MAX_CHARS:
    text = text[:MAX_CHARS] + "..."

if text.startswith("/"):
    text = ""

cwd = data.get("cwd", "")
if not isinstance(cwd, str):
    cwd = ""

print(text)
print(cwd)
PY
)"

text="$(printf '%s\n' "$analysis" | sed -n '1p')"
project_dir="$(printf '%s\n' "$analysis" | sed -n '2p')"

if [[ -z "$text" ]]; then
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

if [[ ! -f "$project_dir/.agent-debate/loop/state.json" ]]; then
  exit 0
fi

loop_script="$project_dir/loop.sh"
if [[ ! -x "$loop_script" ]]; then
  loop_script="$HOME/.agent-debate/loop.sh"
fi

if [[ ! -x "$loop_script" ]]; then
  exit 0
fi

cd "$project_dir"
"$loop_script" log "user: $text" >/dev/null 2>&1 || true
exit 0
