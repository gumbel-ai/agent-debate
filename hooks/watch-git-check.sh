#!/usr/bin/env bash
# Claude PreToolUse adapter for gating git commit while watch mode is active.

set -euo pipefail

HOOK_INPUT="$(cat || true)"

analysis="$(HOOK_INPUT="$HOOK_INPUT" python3 - <<'PY' 2>/dev/null || printf '0\n\n'
import json
import os
import re
import shlex


def is_assignment(token: str) -> bool:
    if token.startswith("-") or "=" not in token:
        return False
    name = token.split("=", 1)[0]
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name))


def is_git_commit_simple(tokens):
    i = 0
    while i < len(tokens) and is_assignment(tokens[i]):
        i += 1

    while i < len(tokens) and tokens[i] in {"command", "exec", "noglob"}:
        i += 1

    if i >= len(tokens) or tokens[i] != "git":
        return False

    i += 1
    options_with_values = {
        "-C",
        "-c",
        "--git-dir",
        "--work-tree",
        "--namespace",
        "--exec-path",
        "--config-env",
    }
    while i < len(tokens):
        token = tokens[i]
        if token == "commit":
            return True
        if token == "--":
            i += 1
            continue
        if token in options_with_values:
            i += 2
            continue
        if any(token.startswith(prefix + "=") for prefix in options_with_values if prefix.startswith("--")):
            i += 1
            continue
        if token.startswith("-C") or token.startswith("-c"):
            i += 1
            continue
        if token.startswith("-"):
            i += 1
            continue
        return False
    return False


def is_git_commit(command):
    command = command.replace("\n", " ; ")
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return False

    current = []
    separators = {";", "&&", "||", "|", "&"}
    for token in tokens:
        if token in separators:
            if current and is_git_commit_simple(current):
                return True
            current = []
        else:
            current.append(token)
    return bool(current and is_git_commit_simple(current))


try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
except json.JSONDecodeError:
    data = {}

tool_input = data.get("tool_input", {})
if not isinstance(tool_input, dict):
    tool_input = {}

command = tool_input.get("command", "")
if not isinstance(command, str):
    command = ""

cwd = data.get("cwd", "")
if not isinstance(cwd, str):
    cwd = ""

print("1" if is_git_commit(command) else "0")
print(cwd)
PY
)"

is_commit="$(printf '%s\n' "$analysis" | sed -n '1p')"
project_dir="$(printf '%s\n' "$analysis" | sed -n '2p')"

if [[ "$is_commit" != "1" ]]; then
  exit 0
fi

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
exec "$watch_script" check --strict
