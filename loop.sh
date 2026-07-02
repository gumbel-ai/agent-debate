#!/usr/bin/env bash
# loop.sh — Async reviewer feedback loop for a coding session
#
# One agent codes (the primary), a second model reviews progress in the
# background (the reviewer) and writes feedback the primary must disposition.
# Works both ways: Claude Code primary -> Codex reviewer, Codex primary ->
# Claude reviewer.
#
# Usage:
#   ./loop.sh start [--reviewer alias] [--task "task statement"]
#   ./loop.sh stop
#   ./loop.sh status
#   ./loop.sh task "task statement"
#   ./loop.sh log "one-line summary"
#   ./loop.sh intent "what + why + expected validation"
#   ./loop.sh progress "what changed + current risk"
#   ./loop.sh outcome "files changed + checks run + remaining risk"
#   ./loop.sh feedback accept|deny|park "summary/reason"
#   ./loop.sh check [--strict]
#   ./loop.sh bypass ["reason"]

set -euo pipefail

PROJECT_DIR="$(pwd)"
LOOP_DIR="$PROJECT_DIR/.agent-debate/loop"
STATE_FILE="$LOOP_DIR/state.json"
JOURNAL_FILE="$LOOP_DIR/journal.md"
FEEDBACK_FILE="$LOOP_DIR/feedback.md"
PID_FILE="$LOOP_DIR/loop.pid"
DEFAULT_INTERVAL=60
DEFAULT_IDLE_TIMEOUT=7200
DIFF_BYTE_CAP=20000
SYSTEM_TAG="[loop-system]"

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_SOURCE" = /* ]]; then
  LOOP_SCRIPT="$SCRIPT_SOURCE"
else
  LOOP_SCRIPT="$PROJECT_DIR/$SCRIPT_SOURCE"
fi

loop_command_display() {
  printf '%q' "$LOOP_SCRIPT"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") COMMAND

Commands:
  start [--reviewer alias] [--task "..."]  Start loop mode for this project
  stop                     Stop loop mode and archive the session files
  status                   Show active state and recent reviewer feedback
  task "statement"         Set or update the task statement shown to the reviewer
  log "summary"            Append a primary-agent activity note
  intent "summary"         Append a structured intent ledger entry
  progress "summary"       Append a structured progress ledger entry
  outcome "summary"        Append a structured outcome ledger entry
  feedback ACTION "reason" Record feedback disposition; ACTION is accept, deny, or park
  check [--strict]         Print unread feedback; strict exits 2 on blockers
  bypass ["reason"]        Allow the next ledger gate to pass once
  gate                     Internal task-completion ledger gate
  hook-stop                Internal Stop-hook checkpoint
  run-loop                 Internal background reviewer loop
EOF
}

detect_host_provider() {
  if [[ -n "${AGENT_DEBATE_HOST_PROVIDER:-}" ]]; then
    printf '%s' "$AGENT_DEBATE_HOST_PROVIDER" | tr '[:upper:]' '[:lower:]'
    return
  fi

  if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    printf 'codex'
  elif [[ -n "${CLAUDE_CODE_SSE_PORT:-}" || -n "${CLAUDECODE:-}" ]]; then
    printf 'claude'
  else
    printf ''
  fi
}

default_reviewer_alias() {
  local host_provider="$1"
  case "$host_provider" in
    claude) printf 'codex' ;;
    codex) printf 'opus' ;;
    *)
      echo "Error: could not detect host provider. Set AGENT_DEBATE_HOST_PROVIDER=claude|codex." >&2
      return 1
      ;;
  esac
}

config_path() {
  if [[ -f "$PROJECT_DIR/debate.config.json" ]]; then
    printf '%s' "$PROJECT_DIR/debate.config.json"
  elif [[ -f "$HOME/.agent-debate/config.json" ]]; then
    printf '%s' "$HOME/.agent-debate/config.json"
  else
    printf ''
  fi
}

resolve_alias_json() {
  local alias="$1"
  local cfg
  cfg="$(config_path)"

  python3 - "$cfg" "$alias" <<'PY'
import json
import os
import sys

config_path = sys.argv[1]
alias = sys.argv[2].strip().lower()

BUILTIN_ALIASES = {
    "opus": {
        "name": "Opus",
        "provider": "claude",
        "command_template": ["claude", "-p", "--model", "opus", "--effort", "{EFFORT}"],
        "reasoning": {"default": "medium", "allowed": ["low", "medium", "high"]},
        "prompt_transport": "arg",
    },
    "sonnet": {
        "name": "Sonnet",
        "provider": "claude",
        "command_template": ["claude", "-p", "--model", "sonnet", "--effort", "{EFFORT}"],
        "reasoning": {"default": "medium", "allowed": ["low", "medium", "high"]},
        "prompt_transport": "arg",
    },
    "codex": {
        "name": "Codex",
        "provider": "codex",
        "command_template": ["codex", "exec", "--skip-git-repo-check", "-c", "model_reasoning_effort=\"{EFFORT}\""],
        "reasoning": {"default": "medium", "allowed": ["low", "medium", "high"]},
        "prompt_transport": "arg",
    },
}

def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)

if config_path:
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON in config ({config_path}): {exc}")
    aliases = cfg.get("aliases")
    if not isinstance(aliases, dict):
        fail("config.aliases must be an object")
else:
    aliases = BUILTIN_ALIASES

if alias not in aliases:
    available = ", ".join(sorted(aliases.keys()))
    fail(f"unknown reviewer alias '{alias}'. Available: {available}")

spec = aliases[alias]
if not isinstance(spec, dict):
    fail(f"alias '{alias}' must be an object")

name = spec.get("name")
if not isinstance(name, str) or not name.strip():
    fail(f"alias '{alias}' has invalid name")

template = spec.get("command_template")
if not isinstance(template, list) or not template or not all(isinstance(x, str) and x for x in template):
    fail(f"alias '{alias}' command_template must be a non-empty array of strings")

transport = spec.get("prompt_transport", "arg")
if transport not in ("arg", "stdin"):
    fail(f"alias '{alias}' prompt_transport must be 'arg' or 'stdin'")

provider = spec.get("provider", "")
if provider is None:
    provider = ""
if not isinstance(provider, str):
    fail(f"alias '{alias}' provider must be a string when set")
provider = provider.strip().lower()

reasoning = spec.get("reasoning") or {}
if not isinstance(reasoning, dict):
    fail(f"alias '{alias}' reasoning must be an object")
effort = reasoning.get("default", "")
allowed = reasoning.get("allowed")
if effort and allowed is not None:
    if not isinstance(allowed, list) or not all(isinstance(x, str) and x for x in allowed):
        fail(f"alias '{alias}' reasoning.allowed must be an array of strings")
    if effort not in allowed:
        fail(f"alias '{alias}' reasoning.default '{effort}' is not in reasoning.allowed")

model = spec.get("default_model", "")
command = []
for part in template:
    if "{EFFORT}" in part:
        if not effort:
            fail(f"alias '{alias}' requires reasoning.default when using {{EFFORT}}")
        part = part.replace("{EFFORT}", effort)
    if "{MODEL}" in part:
        if not model:
            fail(f"alias '{alias}' requires default_model when using {{MODEL}}")
        part = part.replace("{MODEL}", model)
    command.append(part)

if not provider and command:
    base = os.path.basename(command[0]).lower()
    if base in ("claude", "codex", "gemini", "copilot"):
        provider = base

json.dump(
    {
        "alias": alias,
        "name": name.strip(),
        "provider": provider,
        "command": command,
        "prompt_transport": transport,
    },
    sys.stdout,
)
PY
}

json_value() {
  local key="$1"
  python3 - "$STATE_FILE" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as f:
        state = json.load(f)
except FileNotFoundError:
    raise SystemExit(1)

value = state.get(key, "")
if value is None:
    value = ""
print(value)
PY
}

state_int_value() {
  local key="$1"
  local default_value="${2:-0}"

  python3 - "$STATE_FILE" "$key" "$default_value" <<'PY'
import json
import sys

path, key, default = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as f:
        state = json.load(f)
    value = state.get(key, default)
    print(int(value))
except Exception:
    print(default)
PY
}

file_size() {
  local path="$1"
  if [[ -f "$path" ]]; then
    wc -c < "$path" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

write_initial_state() {
  local host_provider="$1"
  local reviewer_alias="$2"
  local reviewer_json="$3"
  local interval="$4"
  local task="$5"
  local idle_timeout="$6"

  python3 - "$STATE_FILE" "$host_provider" "$reviewer_alias" "$reviewer_json" "$JOURNAL_FILE" "$FEEDBACK_FILE" "$interval" "$task" "$idle_timeout" <<'PY'
import json
import os
import sys
import time
from datetime import datetime, timezone

state_path, host_provider, reviewer_alias, reviewer_json, journal_path, feedback_path, interval, task, idle_timeout = sys.argv[1:10]
reviewer = json.loads(reviewer_json)
state = {
    "host_provider": host_provider,
    "reviewer_provider": reviewer.get("provider", ""),
    "reviewer_alias": reviewer_alias,
    "task": task,
    "journal_path": journal_path,
    "feedback_path": feedback_path,
    "feedback_cursor": 0,
    "feedback_seen_cursor": 0,
    "ledger_completion_cursor": 0,
    "ledger_bypass_once": 0,
    "journal_review_offset": 0,
    "user_distill_offset": 0,
    "last_review_signature": "",
    "last_change_at": int(time.time()),
    "consecutive_failures": 0,
    "last_failure_message": "",
    "loop_pid": "",
    "started_at": datetime.now(timezone.utc).isoformat(),
    "loop_interval": int(interval),
    "idle_timeout": int(idle_timeout),
}
tmp_path = f"{state_path}.tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
os.replace(tmp_path, state_path)
PY
}

update_state_value() {
  local key="$1"
  local value="$2"
  python3 - "$STATE_FILE" "$key" "$value" <<'PY'
import json
import os
import sys
import time

path, key, value = sys.argv[1:4]
lock_path = f"{path}.lock"
stale_after_seconds = 300
locked = False
for _ in range(100):
    try:
        os.mkdir(lock_path)
        locked = True
        break
    except FileExistsError:
        try:
            age = time.time() - os.stat(lock_path).st_mtime
            if age > stale_after_seconds:
                os.rmdir(lock_path)
                continue
        except OSError:
            pass
        time.sleep(0.05)

if not locked:
    raise SystemExit(f"Error: timed out waiting for state lock {lock_path}")

INT_KEYS = {
    "feedback_cursor",
    "feedback_seen_cursor",
    "journal_review_offset",
    "user_distill_offset",
    "ledger_completion_cursor",
    "ledger_bypass_once",
    "consecutive_failures",
    "last_change_at",
    "loop_pid",
    "loop_interval",
    "idle_timeout",
}

try:
    with open(path, "r", encoding="utf-8") as f:
        state = json.load(f)

    if key in INT_KEYS:
        try:
            state[key] = int(value)
        except ValueError:
            state[key] = value
    else:
        state[key] = value

    tmp_path = f"{path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, path)
finally:
    try:
        os.rmdir(lock_path)
    except OSError as exc:
        print(f"Warning: could not remove state lock {lock_path}: {exc}", file=sys.stderr)
PY
}

live_pid() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

state_loop_pid() {
  local pid=""
  if [[ -f "$STATE_FILE" ]]; then
    pid="$(json_value "loop_pid" 2>/dev/null || true)"
  fi
  if [[ -z "$pid" && -f "$PID_FILE" ]]; then
    pid="$(sed -n '1p' "$PID_FILE")"
  fi
  printf '%s' "$pid"
}

ensure_loop_dir() {
  mkdir -p "$LOOP_DIR"
  touch "$JOURNAL_FILE" "$FEEDBACK_FILE"
}

reset_active_files() {
  : > "$JOURNAL_FILE"
  : > "$FEEDBACK_FILE"
}

hook_command_path() {
  local script_name="$1"
  local shared_path="$HOME/.agent-debate/hooks/$script_name"
  local project_path="$PROJECT_DIR/hooks/$script_name"

  if [[ -x "$project_path" ]]; then
    printf '%s' "$project_path"
  elif [[ -x "$shared_path" ]]; then
    printf '%s' "$shared_path"
  else
    printf '%s' "$shared_path"
  fi
}

project_hook_commands_json() {
  python3 - "$HOME/.agent-debate/hooks" "$PROJECT_DIR/hooks" "$@" <<'PY'
import json
import sys

shared_dir, project_dir = sys.argv[1:3]
names = sys.argv[3:]

commands = []
for name in names:
    for base in (shared_dir, project_dir):
        value = f"{base}/{name}"
        if value not in commands:
            commands.append(value)
json.dump(commands, sys.stdout)
PY
}

install_claude_project_hooks() {
  local stop_command="$1"
  local git_command="$2"
  local task_command="$3"
  local prompt_command="$4"
  local settings_path="$PROJECT_DIR/.claude/settings.local.json"

  mkdir -p "$(dirname "$settings_path")"
  python3 - "$settings_path" "$stop_command" "$git_command" "$task_command" "$prompt_command" <<'PY'
import json
import os
import sys

path, stop_command, git_command, task_command, prompt_command = sys.argv[1:6]

if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise SystemExit(f"Error: {path} must contain a JSON object")
else:
    data = {}

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit(f"Error: {path}.hooks must be a JSON object")

def has_command(event: str, command: str) -> bool:
    groups = hooks.get(event, [])
    if not isinstance(groups, list):
        raise SystemExit(f"Error: {path}.hooks.{event} must be an array")
    for group in groups:
        if not isinstance(group, dict):
            continue
        handlers = group.get("hooks", [])
        if not isinstance(handlers, list):
            continue
        for handler in handlers:
            if (
                isinstance(handler, dict)
                and handler.get("type") == "command"
                and handler.get("command") == command
            ):
                return True
    return False

def append_group(event: str, group: dict) -> None:
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        raise SystemExit(f"Error: {path}.hooks.{event} must be an array")
    groups.append(group)

if not has_command("Stop", stop_command):
    append_group("Stop", {"hooks": [{"type": "command", "command": stop_command}]})

# The git hook script parses the Bash command itself and exits quietly for
# anything that is not a `git commit`, so a broad matcher is safe.
if not has_command("PreToolUse", git_command):
    append_group(
        "PreToolUse",
        {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": git_command}],
        },
    )

if not has_command("PreToolUse", task_command):
    append_group(
        "PreToolUse",
        {
            "matcher": "TaskUpdate|TodoWrite",
            "hooks": [{"type": "command", "command": task_command}],
        },
    )

if not has_command("UserPromptSubmit", prompt_command):
    append_group("UserPromptSubmit", {"hooks": [{"type": "command", "command": prompt_command}]})

tmp_path = f"{path}.tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp_path, path)
PY
}

remove_project_hook_commands() {
  local settings_path="$1"
  local commands_json="$2"

  [[ -f "$settings_path" ]] || return 0

  python3 - "$settings_path" "$commands_json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
commands = set(json.loads(sys.argv[2]))

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit(f"Error: {path} must contain a JSON object")

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit(0)

for event in list(hooks.keys()):
    groups = hooks[event]
    if not isinstance(groups, list):
        continue
    kept_groups = []
    for group in groups:
        if not isinstance(group, dict):
            kept_groups.append(group)
            continue
        handlers = group.get("hooks")
        if not isinstance(handlers, list):
            kept_groups.append(group)
            continue
        kept_handlers = []
        for handler in handlers:
            if (
                isinstance(handler, dict)
                and handler.get("type") == "command"
                and handler.get("command") in commands
            ):
                continue
            kept_handlers.append(handler)
        if kept_handlers:
            group["hooks"] = kept_handlers
            kept_groups.append(group)
    if kept_groups:
        hooks[event] = kept_groups
    else:
        hooks.pop(event, None)

if not hooks:
    data.pop("hooks", None)

tmp_path = f"{path}.tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp_path, path)
PY
}

install_codex_project_hooks() {
  local stop_command="$1"
  local task_command="$2"
  local prompt_command="$3"
  local hooks_path="$PROJECT_DIR/.codex/hooks.json"

  mkdir -p "$(dirname "$hooks_path")"
  python3 - "$hooks_path" "$stop_command" "$task_command" "$prompt_command" <<'PY'
import json
import os
import sys

path, stop_command, task_command, prompt_command = sys.argv[1:5]

if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise SystemExit(f"Error: {path} must contain a JSON object")
else:
    data = {}

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit(f"Error: {path}.hooks must be a JSON object")

def has_command(event: str, command: str) -> bool:
    groups = hooks.get(event, [])
    if not isinstance(groups, list):
        raise SystemExit(f"Error: {path}.hooks.{event} must be an array")
    for group in groups:
        if not isinstance(group, dict):
            continue
        handlers = group.get("hooks", [])
        if not isinstance(handlers, list):
            continue
        for handler in handlers:
            if (
                isinstance(handler, dict)
                and handler.get("type") == "command"
                and handler.get("command") == command
            ):
                return True
    return False

def append_group(event: str, group: dict) -> None:
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        raise SystemExit(f"Error: {path}.hooks.{event} must be an array")
    groups.append(group)

if not has_command("Stop", stop_command):
    append_group("Stop", {"hooks": [{"type": "command", "command": stop_command}]})

if not has_command("PreToolUse", task_command):
    append_group(
        "PreToolUse",
        {
            "matcher": "^update_plan$",
            "hooks": [{"type": "command", "command": task_command}],
        },
    )

if not has_command("UserPromptSubmit", prompt_command):
    append_group("UserPromptSubmit", {"hooks": [{"type": "command", "command": prompt_command}]})

tmp_path = f"{path}.tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp_path, path)
PY
}

install_project_hooks() {
  local host_provider="$1"
  local stop_command git_command task_command prompt_command
  stop_command="$(hook_command_path "loop-stop.sh")"
  task_command="$(hook_command_path "loop-task-check.sh")"
  prompt_command="$(hook_command_path "loop-prompt-log.sh")"

  case "$host_provider" in
    claude)
      git_command="$(hook_command_path "loop-git-check.sh")"
      install_claude_project_hooks "$stop_command" "$git_command" "$task_command" "$prompt_command"
      ;;
    codex)
      install_codex_project_hooks "$stop_command" "$task_command" "$prompt_command"
      ;;
  esac
}

remove_project_hooks() {
  local host_provider="$1"
  local combined_commands

  combined_commands="$(project_hook_commands_json \
    "loop-stop.sh" "loop-git-check.sh" "loop-task-check.sh" "loop-prompt-log.sh")"

  case "$host_provider" in
    claude)
      remove_project_hook_commands "$PROJECT_DIR/.claude/settings.local.json" "$combined_commands"
      ;;
    codex)
      remove_project_hook_commands "$PROJECT_DIR/.codex/hooks.json" "$combined_commands"
      ;;
  esac
}

cmd_start() {
  local reviewer_alias=""
  local task=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reviewer)
        reviewer_alias="${2:-}"
        if [[ -z "$reviewer_alias" ]]; then
          echo "Error: --reviewer requires an alias" >&2
          exit 1
        fi
        shift 2
        ;;
      --task)
        task="${2:-}"
        if [[ -z "$task" ]]; then
          echo "Error: --task requires a task statement" >&2
          exit 1
        fi
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option for start: $1" >&2
        exit 1
        ;;
    esac
  done

  ensure_loop_dir

  local existing_pid
  existing_pid="$(state_loop_pid)"
  if [[ -n "$existing_pid" ]] && live_pid "$existing_pid"; then
    echo "loop mode already active"
    exit 1
  fi

  if [[ -f "$STATE_FILE" || -f "$PID_FILE" ]]; then
    echo "loop mode had stale state; replacing it"
    rm -f "$STATE_FILE" "$PID_FILE"
  fi

  reset_active_files

  local host_provider
  host_provider="$(detect_host_provider)"
  if [[ "$host_provider" != "claude" && "$host_provider" != "codex" ]]; then
    echo "Error: could not detect host provider. Set AGENT_DEBATE_HOST_PROVIDER=claude|codex." >&2
    exit 1
  fi

  if [[ -z "$reviewer_alias" ]]; then
    reviewer_alias="$(default_reviewer_alias "$host_provider")"
  fi

  local reviewer_json
  reviewer_json="$(resolve_alias_json "$reviewer_alias")"

  local reviewer_bin
  reviewer_bin="$(python3 - "$reviewer_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["command"][0])
PY
)"
  if ! command -v "$reviewer_bin" >/dev/null 2>&1; then
    echo "Error: reviewer command '$reviewer_bin' not found on PATH. Install it or pick another reviewer with --reviewer." >&2
    exit 1
  fi

  local interval="${LOOP_INTERVAL:-$DEFAULT_INTERVAL}"
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
    echo "Error: LOOP_INTERVAL must be a positive integer number of seconds" >&2
    exit 1
  fi

  local idle_timeout="${LOOP_IDLE_TIMEOUT:-$DEFAULT_IDLE_TIMEOUT}"
  if ! [[ "$idle_timeout" =~ ^[0-9]+$ ]]; then
    echo "Error: LOOP_IDLE_TIMEOUT must be a non-negative integer number of seconds (0 disables auto-stop)" >&2
    exit 1
  fi

  write_initial_state "$host_provider" "$reviewer_alias" "$reviewer_json" "$interval" "$task" "$idle_timeout"
  if ! install_project_hooks "$host_provider"; then
    rm -f "$STATE_FILE" "$PID_FILE" "$JOURNAL_FILE" "$FEEDBACK_FILE"
    exit 1
  fi
  nohup "$LOOP_SCRIPT" run-loop >/dev/null 2>&1 &
  local pid="$!"
  printf '%s\n' "$pid" > "$PID_FILE"
  update_state_value "loop_pid" "$pid"

  local reviewer_provider
  reviewer_provider="$(json_value "reviewer_provider")"
  echo "Loop mode on. ${reviewer_alias} (${reviewer_provider:-unknown}) will review asynchronously every ${interval}s."
  if [[ "$idle_timeout" -gt 0 ]]; then
    echo "Auto-stop: loop shuts itself down after $((idle_timeout / 60)) minutes without activity."
  fi
  echo "Task tracking: user prompts are journaled via hook and auto-distilled into the task statement."
  local loop_cmd
  loop_cmd="$(loop_command_display)"
  cat <<EOF
Loop ledger contract:
- Before marking a todo/task complete, run: $loop_cmd intent "what + why + expected validation"
- Check feedback with: $loop_cmd check
- If feedback exists, record a disposition before completing: $loop_cmd feedback accept|deny|park "reason"
- Optional context: $loop_cmd progress "..." and $loop_cmd outcome "..."
- Set/update the task statement for the reviewer: $loop_cmd task "..."
- Emergency one-shot gate bypass: $loop_cmd bypass "reason"
Note: hooks installed just now may need a session restart or /hooks review before the host agent enforces them.
EOF
  if [[ -z "$task" ]]; then
    echo "Tip: no --task given. Run: $loop_cmd task \"<what the primary is building>\" so the reviewer knows the goal."
  fi
}

# Archives the active session files and prints the archive directory.
archive_session() {
  local archive_name
  archive_name="$(python3 - "$STATE_FILE" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

path = sys.argv[1]
started_at = datetime.now(timezone.utc).isoformat()
try:
    with open(path, "r", encoding="utf-8") as f:
        state = json.load(f)
    value = state.get("started_at")
    if isinstance(value, str) and value.strip():
        started_at = value.strip()
except Exception:
    pass

print(re.sub(r"[^0-9A-Za-z._-]+", "-", started_at).strip("-") or "session")
PY
)"

  local archive_dir="$LOOP_DIR/archive/$archive_name"
  mkdir -p "$archive_dir"
  [[ -f "$JOURNAL_FILE" ]] && cp "$JOURNAL_FILE" "$archive_dir/journal.md"
  [[ -f "$FEEDBACK_FILE" ]] && cp "$FEEDBACK_FILE" "$archive_dir/feedback.md"
  [[ -f "$STATE_FILE" ]] && cp "$STATE_FILE" "$archive_dir/state.json"
  printf '%s' "$archive_dir"
}

cmd_stop() {
  if [[ ! -d "$LOOP_DIR" ]]; then
    echo "loop mode is not active"
    return
  fi

  local pid=""
  pid="$(state_loop_pid)"
  local host_provider=""
  if [[ -f "$STATE_FILE" ]]; then
    host_provider="$(json_value "host_provider" 2>/dev/null || true)"
  fi
  if [[ -n "$pid" ]] && live_pid "$pid"; then
    kill "$pid" 2>/dev/null || true
  fi
  if [[ -n "$host_provider" ]]; then
    remove_project_hooks "$host_provider"
  fi

  local archive_dir
  archive_dir="$(archive_session)"

  rm -f "$STATE_FILE" "$PID_FILE" "$JOURNAL_FILE" "$FEEDBACK_FILE"
  echo "Loop mode off. Archived session to $archive_dir"
}

cmd_status() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "loop mode is not active"
    return
  fi

  python3 -m json.tool "$STATE_FILE"

  local pid
  pid="$(state_loop_pid)"
  if [[ -n "$pid" ]] && live_pid "$pid"; then
    echo "loop: running ($pid)"
  else
    echo "loop: stale"
  fi

  if [[ -s "$FEEDBACK_FILE" ]]; then
    echo ""
    echo "Recent feedback:"
    tail -n 5 "$FEEDBACK_FILE"
  fi
}

cmd_log() {
  if [[ $# -eq 0 ]]; then
    echo "Error: log requires a one-line summary" >&2
    exit 1
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "loop mode is not active"
    return
  fi
  printf '[%s] %s\n' "$(date -Iseconds)" "$*" >> "$JOURNAL_FILE"
}

cmd_tagged_log() {
  local tag="$1"
  shift
  if [[ $# -eq 0 ]]; then
    echo "Error: $tag requires a one-line summary" >&2
    exit 1
  fi
  cmd_log "$tag: $*"
}

cmd_intent() {
  cmd_tagged_log "intent" "$@"
}

cmd_progress() {
  cmd_tagged_log "progress" "$@"
}

cmd_outcome() {
  cmd_tagged_log "outcome" "$@"
}

cmd_task() {
  if [[ $# -eq 0 ]]; then
    echo "Error: task requires a task statement" >&2
    exit 1
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "loop mode is not active"
    return
  fi
  update_state_value "task" "$*"
  cmd_log "task: $*"
  echo "Task statement updated for the reviewer."
}

cmd_bypass() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "loop mode is not active"
    return
  fi
  update_state_value "ledger_bypass_once" 1
  cmd_log "bypass: ${*:-one-shot ledger bypass requested}"
  echo "Next ledger gate will pass once without intent/feedback checks."
}

cmd_feedback() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "loop mode is not active"
    return
  fi

  if [[ $# -lt 2 ]]; then
    echo "Error: feedback requires accept|deny|park and a reason" >&2
    exit 1
  fi

  local action="$1"
  shift
  case "$action" in
    accept|deny|park) ;;
    *)
      echo "Error: feedback action must be accept, deny, or park" >&2
      exit 1
      ;;
  esac

  touch "$FEEDBACK_FILE"
  local size cursor seen loop_cmd
  loop_cmd="$(loop_command_display)"
  size="$(file_size "$FEEDBACK_FILE")"
  cursor="$(state_int_value "feedback_cursor" 0)"
  if [[ "$cursor" -gt "$size" ]]; then
    cursor=0
  fi
  seen="$(state_int_value "feedback_seen_cursor" 0)"
  if [[ "$seen" -gt "$size" ]]; then
    seen="$size"
  fi

  if [[ "$size" -gt "$cursor" ]]; then
    if [[ "$seen" -le "$cursor" ]]; then
      echo "Error: unread feedback has not been viewed. Run $loop_cmd check first, then record a disposition." >&2
      exit 1
    fi
    cmd_log "feedback-action: $action $*"
    update_state_value "feedback_cursor" "$seen"
    if [[ "$size" -gt "$seen" ]]; then
      echo "Disposition recorded for the feedback you viewed. Newer feedback arrived since; run $loop_cmd check again."
    fi
  else
    cmd_log "feedback-action: $action $*"
  fi
}

# Prints unread feedback slice and whether any of it is actionable
# (i.e. not solely $SYSTEM_TAG infrastructure notes).
unread_feedback_analysis() {
  python3 - "$STATE_FILE" "$FEEDBACK_FILE" "$SYSTEM_TAG" <<'PY'
import json
import os
import sys

state_path, feedback_path, system_tag = sys.argv[1:4]
try:
    with open(state_path, "r", encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    state = {}

try:
    cursor = int(state.get("feedback_cursor", 0))
except (TypeError, ValueError):
    cursor = 0

size = os.path.getsize(feedback_path) if os.path.exists(feedback_path) else 0
cursor = max(0, cursor)
if cursor > size:
    cursor = 0

unread = ""
if size > cursor:
    with open(feedback_path, "rb") as f:
        f.seek(cursor)
        unread = f.read().decode("utf-8", errors="replace")

actionable = any(
    line.strip() and system_tag not in line
    for line in unread.splitlines()
)

print("1" if size > cursor else "0")
print("1" if actionable else "0")
print(size)
PY
}

cmd_check() {
  local strict=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        strict=true
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        echo "Unknown option for check: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ ! -f "$STATE_FILE" ]]; then
    if [[ "$strict" == false ]]; then
      echo "loop mode is not active"
    fi
    return 0
  fi

  touch "$FEEDBACK_FILE"
  local cursor size blocked=false unread="" loop_cmd
  loop_cmd="$(loop_command_display)"
  cursor="$(state_int_value "feedback_cursor" 0)"
  if ! [[ "$cursor" =~ ^[0-9]+$ ]]; then
    cursor=0
  fi
  size="$(file_size "$FEEDBACK_FILE")"
  if [[ "$cursor" -gt "$size" ]]; then
    cursor=0
  fi

  if [[ "$size" -gt "$cursor" ]]; then
    unread="$(tail -c +"$((cursor + 1))" "$FEEDBACK_FILE")"
    # Record how far the reader has actually seen; feedback dispositions ack
    # only up to this point so notes appended later are never silently acked.
    update_state_value "feedback_seen_cursor" "$size"
    if [[ "$strict" == true ]]; then
      {
        echo "Unread reviewer feedback requires attention before continuing:"
        printf '%s\n' "$unread"
        echo "Record a disposition with: $loop_cmd feedback accept|deny|park \"reason\""
      } >&2
      blocked=true
    else
      printf '%s\n' "$unread"
      echo "Feedback remains unread until you run: $loop_cmd feedback accept|deny|park \"reason\""
    fi
  else
    if [[ "$strict" == false ]]; then
      echo "No unread reviewer feedback."
    fi
  fi

  if [[ "$strict" == true ]]; then
    local pid
    pid="$(state_loop_pid)"
    if [[ -z "$pid" ]] || ! live_pid "$pid"; then
      echo "reviewer loop is not running; run $loop_cmd status or $loop_cmd stop" >&2
      blocked=true
    fi
    if [[ "$blocked" == true ]]; then
      exit 2
    fi
  fi
}

cmd_gate() {
  if [[ ! -f "$STATE_FILE" ]]; then
    return 0
  fi

  if [[ "${LOOP_LEDGER_OFF:-}" == "1" ]]; then
    cmd_log "outcome: ledger-gate bypassed (LOOP_LEDGER_OFF)"
    echo "loop ledger gate bypassed by LOOP_LEDGER_OFF=1" >&2
    return 0
  fi

  if [[ "$(state_int_value "ledger_bypass_once" 0)" == "1" ]]; then
    update_state_value "ledger_bypass_once" 0
    cmd_log "outcome: ledger-gate bypassed (one-shot bypass)"
    echo "loop ledger gate bypassed once" >&2
    return 0
  fi

  touch "$JOURNAL_FILE" "$FEEDBACK_FILE"

  local analysis loop_cmd
  loop_cmd="$(loop_command_display)"
  if ! analysis="$(python3 - "$STATE_FILE" "$JOURNAL_FILE" "$FEEDBACK_FILE" "$SYSTEM_TAG" 2>/dev/null <<'PY'
import json
import os
import sys

state_path, journal_path, feedback_path, system_tag = sys.argv[1:5]
with open(state_path, "r", encoding="utf-8") as f:
    state = json.load(f)

def int_value(key):
    try:
        return int(state.get(key, 0))
    except (TypeError, ValueError):
        return 0

task = state.get("task", "")
has_task = isinstance(task, str) and bool(task.strip())

ledger_cursor = max(0, int_value("ledger_completion_cursor"))
feedback_cursor = max(0, int_value("feedback_cursor"))

journal_size = os.path.getsize(journal_path) if os.path.exists(journal_path) else 0
feedback_size = os.path.getsize(feedback_path) if os.path.exists(feedback_path) else 0

if ledger_cursor > journal_size:
    ledger_cursor = 0
if feedback_cursor > feedback_size:
    feedback_cursor = 0

with open(journal_path, "rb") as f:
    f.seek(ledger_cursor)
    journal_delta = f.read().decode("utf-8", errors="replace")

has_intent = any("] intent: " in line for line in journal_delta.splitlines())

unread = ""
if feedback_size > feedback_cursor:
    with open(feedback_path, "rb") as f:
        f.seek(feedback_cursor)
        unread = f.read().decode("utf-8", errors="replace")

# Infrastructure notes (reviewer CLI failures etc.) are visible via `check`
# but must not block task completion for the primary.
has_actionable_feedback = any(
    line.strip() and system_tag not in line
    for line in unread.splitlines()
)

print("1" if has_task else "0")
print("1" if has_intent else "0")
print("1" if has_actionable_feedback else "0")
print(journal_size)
PY
  )"; then
    echo "loop ledger gate could not read state; allowing completion" >&2
    return 0
  fi

  local has_task has_intent has_unread_feedback journal_size blocked=false
  has_task="$(printf '%s\n' "$analysis" | sed -n '1p')"
  has_intent="$(printf '%s\n' "$analysis" | sed -n '2p')"
  has_unread_feedback="$(printf '%s\n' "$analysis" | sed -n '3p')"
  journal_size="$(printf '%s\n' "$analysis" | sed -n '4p')"

  if [[ "$has_task" != "1" ]]; then
    echo "Loop ledger requires a task statement before task completion." >&2
    echo "Run: $loop_cmd task \"<what the primary is building>\"" >&2
    blocked=true
  fi

  if [[ "$has_intent" != "1" ]]; then
    echo "Loop ledger requires intent before task completion." >&2
    echo "Run: $loop_cmd intent \"what + why + expected validation\"" >&2
    blocked=true
  fi

  if [[ "$has_unread_feedback" == "1" ]]; then
    echo "Unread reviewer feedback requires disposition before task completion." >&2
    echo "Run: $loop_cmd check then $loop_cmd feedback accept|deny|park \"reason\"" >&2
    blocked=true
  fi

  if [[ "$blocked" == true ]]; then
    exit 2
  fi

  update_state_value "ledger_completion_cursor" "$journal_size"
}

cmd_hook_stop() {
  if [[ ! -f "$STATE_FILE" ]]; then
    return 0
  fi

  touch "$FEEDBACK_FILE"
  local analysis has_unread has_actionable
  analysis="$(unread_feedback_analysis 2>/dev/null || printf '0\n0\n0\n')"
  has_unread="$(printf '%s\n' "$analysis" | sed -n '1p')"
  has_actionable="$(printf '%s\n' "$analysis" | sed -n '2p')"

  if [[ "$has_actionable" == "1" ]]; then
    local loop_cmd
    loop_cmd="$(loop_command_display)"
    if [[ "${LOOP_STOP_ACTIVE:-0}" == "1" ]]; then
      echo "Unread reviewer feedback is still pending; run $loop_cmd check" >&2
      return 0
    fi
    echo "Unread reviewer feedback is available. Run $loop_cmd check, then record a disposition with $loop_cmd feedback accept|deny|park \"reason\" before finishing." >&2
    exit 2
  fi

  if [[ "$has_unread" == "1" ]]; then
    local loop_cmd
    loop_cmd="$(loop_command_display)"
    echo "Reviewer infrastructure notes are pending; run $loop_cmd check when convenient" >&2
  fi
  return 0
}

invoke_reviewer() {
  local reviewer_json="$1"
  local prompt_file="$2"

  python3 - "$reviewer_json" "$prompt_file" <<'PY'
import json
import os
import subprocess
import sys

reviewer = json.loads(sys.argv[1])
prompt_file = sys.argv[2]

command = reviewer.get("command", [])
transport = reviewer.get("prompt_transport", "arg")
provider = str(reviewer.get("provider", "")).strip().lower()

if not isinstance(command, list) or not command:
    print("Error: invalid reviewer command", file=sys.stderr)
    raise SystemExit(1)

if not provider and isinstance(command[0], str):
    base = os.path.basename(command[0]).lower()
    if base in ("claude", "codex", "gemini", "copilot"):
        provider = base

with open(prompt_file, "r", encoding="utf-8") as f:
    prompt = f.read()

env = os.environ.copy()
if provider == "claude":
    env.pop("CLAUDECODE", None)
    for key in list(env.keys()):
        if key.startswith("CLAUDE_CODE_"):
            env.pop(key, None)
elif provider == "codex":
    env.pop("CODEX_THREAD_ID", None)
elif provider == "gemini":
    env.pop("GEMINI_SESSION_ID", None)
    env.pop("GEMINI_CLI_SESSION", None)

# stdin must be closed for arg transport: some CLIs (codex exec) block forever
# waiting on a piped-but-silent stdin. The timeout bounds a hung reviewer pass
# so the loop keeps ticking and idle auto-stop stays reachable.
timeout_seconds = int(os.environ.get("LOOP_REVIEWER_TIMEOUT", "600"))
try:
    if transport == "stdin":
        result = subprocess.run(
            command, input=prompt, capture_output=True, text=True, env=env,
            timeout=timeout_seconds,
        )
    else:
        result = subprocess.run(
            command + [prompt], capture_output=True, text=True, env=env,
            stdin=subprocess.DEVNULL, timeout=timeout_seconds,
        )
except subprocess.TimeoutExpired:
    print(f"reviewer command timed out after {timeout_seconds}s", file=sys.stderr)
    raise SystemExit(124)

if result.returncode != 0:
    if result.stderr:
        sys.stderr.write(result.stderr.splitlines()[0] + "\n")
    raise SystemExit(result.returncode)

sys.stdout.write(result.stdout)
PY
}

append_system_feedback() {
  local message="$1"
  printf '\n[%s] %s %s\n' "$(date -Iseconds)" "$SYSTEM_TAG" "$message" >> "$FEEDBACK_FILE"
}

record_loop_failure() {
  local message="$1"
  local last failures
  last="$(json_value "last_failure_message" 2>/dev/null || true)"
  failures="$(state_int_value "consecutive_failures" 0)"
  if [[ -n "$last" && "$message" == "$last" ]]; then
    update_state_value "consecutive_failures" "$((failures + 1))"
  else
    append_system_feedback "$message"
    update_state_value "last_failure_message" "$message"
    update_state_value "consecutive_failures" 1
  fi
}

clear_loop_failure() {
  local failures
  failures="$(state_int_value "consecutive_failures" 0)"
  if [[ "$failures" -gt 0 ]]; then
    update_state_value "consecutive_failures" 0
    update_state_value "last_failure_message" ""
  fi
}

# Rewrites the task statement from new "user:" journal entries (captured by
# the UserPromptSubmit hook) so the reviewer always judges against current
# intent, even when the primary agent forgets to run `task`.
run_task_distiller() {
  local reviewer_json="$1"
  local distill_offset journal_size user_lines current_task prompt_file output normalized

  distill_offset="$(state_int_value "user_distill_offset" 0)"
  journal_size="$(file_size "$JOURNAL_FILE")"
  if [[ "$distill_offset" -gt "$journal_size" ]]; then
    distill_offset=0
  fi
  [[ "$journal_size" -gt "$distill_offset" ]] || return 0

  user_lines="$(tail -c +"$((distill_offset + 1))" "$JOURNAL_FILE" | grep "] user: " || true)"
  if [[ -z "$user_lines" ]]; then
    update_state_value "user_distill_offset" "$journal_size"
    return 0
  fi

  current_task="$(json_value "task" 2>/dev/null || true)"
  prompt_file="$(mktemp)"
  cat > "$prompt_file" <<EOF
You are the task distiller for a coding session (loop mode).
Rewrite the task statement as 1-3 sentences of current truth for a code
reviewer. Preserve standing constraints unless the user explicitly changed
them. Base the rewrite on the current statement plus the new user messages.

Current task statement:
${current_task:-(none yet)}

New user messages (most recent last):
$user_lines

Output ONLY the rewritten task statement, no preamble.
If the new messages do not change the task, output exactly: NO_CHANGE
EOF

  if ! output="$(invoke_reviewer "$reviewer_json" "$prompt_file" 2>&1)"; then
    rm -f "$prompt_file"
    return 0
  fi
  rm -f "$prompt_file"

  update_state_value "user_distill_offset" "$journal_size"

  output="$(printf '%s' "$output" | sed '/^[[:space:]]*$/d' | head -c 1000)"
  normalized="$(printf '%s\n' "$output" | tail -n 1 | sed 's/[^A-Za-z_]//g' | tr '[:lower:]' '[:upper:]')"
  if [[ -z "$output" || "$normalized" == "NO_CHANGE" || "$normalized" == "NOCHANGE" ]]; then
    return 0
  fi

  output="$(printf '%s' "$output" | tr '\n' ' ')"
  update_state_value "task" "$output"
  cmd_log "task(auto): $output"
}

cmd_run_loop() {
  while [[ -f "$PID_FILE" ]]; do
    local interval failures
    interval="$DEFAULT_INTERVAL"
    if [[ -f "$STATE_FILE" ]]; then
      interval="$(json_value "loop_interval" 2>/dev/null || printf '%s' "$DEFAULT_INTERVAL")"
    fi
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
      interval="$DEFAULT_INTERVAL"
    fi

    # Back off while the reviewer command keeps failing.
    failures="$(state_int_value "consecutive_failures" 0)"
    if [[ "$failures" -gt 5 ]]; then
      failures=5
    fi
    sleep "$((interval * (1 + failures)))"
    [[ -f "$PID_FILE" && -f "$STATE_FILE" ]] || break

    # Idle auto-stop: forgotten sessions shut themselves down. Activity means
    # journal writes (intent/log/task/dispositions) or repo changes.
    local idle_timeout last_change journal_mtime idle_basis now
    idle_timeout="$(state_int_value "idle_timeout" "$DEFAULT_IDLE_TIMEOUT")"
    if [[ "$idle_timeout" -gt 0 ]]; then
      last_change="$(state_int_value "last_change_at" 0)"
      journal_mtime="$(python3 - "$JOURNAL_FILE" <<'PY'
import os
import sys

path = sys.argv[1]
print(int(os.path.getmtime(path)) if os.path.exists(path) else 0)
PY
)"
      idle_basis="$last_change"
      if [[ "$journal_mtime" -gt "$idle_basis" ]]; then
        idle_basis="$journal_mtime"
      fi
      now="$(date +%s)"
      if [[ "$idle_basis" -gt 0 && $((now - idle_basis)) -gt "$idle_timeout" ]]; then
        local stop_host
        stop_host="$(json_value "host_provider" 2>/dev/null || true)"
        if [[ -n "$stop_host" ]]; then
          remove_project_hooks "$stop_host"
        fi
        archive_session >/dev/null
        rm -f "$STATE_FILE" "$PID_FILE" "$JOURNAL_FILE" "$FEEDBACK_FILE"
        exit 0
      fi
    fi

    local reviewer_alias host_provider reviewer_provider reviewer_json task
    local journal_tail journal_slice_file journal_new_offset
    local diff_stat diff_body git_status feedback_status feedback_cursor feedback_size
    local recent_feedback signature last_signature prompt_file output output_last_line normalized_line
    local loop_cmd
    loop_cmd="$(loop_command_display)"
    reviewer_alias="$(json_value "reviewer_alias")"
    host_provider="$(json_value "host_provider")"

    if ! reviewer_json="$(resolve_alias_json "$reviewer_alias" 2>&1)"; then
      record_loop_failure "reviewer command failed: $reviewer_json"
      continue
    fi

    reviewer_provider="$(python3 - "$reviewer_json" <<'PY'
import json
import sys
reviewer = json.loads(sys.argv[1])
print(reviewer.get("provider", ""))
PY
)"

    # Fold new user utterances into the task statement before reviewing.
    run_task_distiller "$reviewer_json"
    task="$(json_value "task" 2>/dev/null || true)"

    journal_slice_file="$(mktemp)"
    if ! journal_new_offset="$(python3 - "$STATE_FILE" "$JOURNAL_FILE" "$journal_slice_file" 2>/dev/null <<'PY'
import json
import os
import sys

state_path, journal_path, output_path = sys.argv[1:4]
with open(state_path, "r", encoding="utf-8") as f:
    state = json.load(f)

try:
    offset = int(state.get("journal_review_offset", 0))
except (TypeError, ValueError):
    offset = 0

size = os.path.getsize(journal_path) if os.path.exists(journal_path) else 0
offset = max(0, min(offset, size))

with open(output_path, "w", encoding="utf-8") as out:
    if offset < size:
        with open(journal_path, "rb") as journal:
            journal.seek(offset)
            out.write(journal.read().decode("utf-8", errors="replace"))
    else:
        out.write("(no new journal entries since last review)\n")

print(size)
PY
    )"; then
      tail -n 80 "$JOURNAL_FILE" > "$journal_slice_file" 2>/dev/null || true
      journal_new_offset="$(file_size "$JOURNAL_FILE")"
    fi
    journal_tail="$(cat "$journal_slice_file")"
    rm -f "$journal_slice_file"

    git_status="$(git status --short 2>/dev/null || true)"
    # `git diff HEAD` covers staged + unstaged; plain `git diff` misses work the
    # primary has already staged. Fall back for repos without a commit yet.
    diff_stat="$(git diff HEAD --stat 2>/dev/null || git diff --stat 2>/dev/null || true)"
    diff_body="$(git diff HEAD 2>/dev/null | head -c "$DIFF_BYTE_CAP" || true)"
    if [[ -z "$diff_body" ]]; then
      diff_body="$(git diff 2>/dev/null | head -c "$DIFF_BYTE_CAP" || true)"
    fi
    if [[ "$(printf '%s' "$diff_body" | wc -c | tr -d '[:space:]')" -ge "$DIFF_BYTE_CAP" ]]; then
      diff_body="$diff_body
[diff truncated at $DIFF_BYTE_CAP bytes — read the files directly for the rest]"
    fi

    # Skip the model call entirely when nothing changed since the last pass.
    signature="$(printf '%s\n---\n%s\n---\n%s\n---\n%s' "$journal_tail" "$git_status" "$diff_stat" "$diff_body" | shasum -a 256 | cut -d' ' -f1)"
    last_signature="$(json_value "last_review_signature" 2>/dev/null || true)"
    if [[ -n "$signature" && "$signature" == "$last_signature" ]]; then
      continue
    fi
    update_state_value "last_change_at" "$(date +%s)"

    feedback_size="$(file_size "$FEEDBACK_FILE")"
    feedback_cursor="$(state_int_value "feedback_cursor" 0)"
    if [[ "$feedback_cursor" -gt "$feedback_size" ]]; then
      feedback_cursor=0
    fi
    if [[ "$feedback_size" -gt "$feedback_cursor" ]]; then
      feedback_status="unread feedback pending; primary must run $loop_cmd feedback accept|deny|park"
    else
      feedback_status="clear"
    fi

    recent_feedback="$(tail -n 30 "$FEEDBACK_FILE" 2>/dev/null || true)"
    if [[ -z "$recent_feedback" ]]; then
      recent_feedback="(none yet)"
    fi

    prompt_file="$(mktemp)"
    cat > "$prompt_file" <<EOF
You are the asynchronous reviewer for an active coding session (loop mode).
Primary agent provider: $host_provider
You (reviewer) provider: $reviewer_provider

You are running inside the project working directory. You may read files, run
git commands, and inspect code to verify a concern before reporting it.

Task statement from the primary session:
${task:-(none provided — judge against the journal and the changes themselves)}

New primary journal entries since your last pass:
$journal_tail

Current git status --short:
$git_status

Current git diff HEAD --stat:
$diff_stat

Changed content (git diff HEAD, capped):
$diff_body

Feedback you have already delivered (do NOT repeat these points):
$recent_feedback

Unread feedback disposition status:
$feedback_status

Review the implementation for a concrete risk, missed requirement,
over/under-engineering, or likely bug. Judge quality and practicality, not
style. Write at most ONE concise note (max 5 lines) with file:line evidence.
Only report something worth interrupting the primary for.
If there is nothing actionable, output exactly: NO_FEEDBACK
EOF

    if ! output="$(invoke_reviewer "$reviewer_json" "$prompt_file" 2>&1)"; then
      rm -f "$prompt_file"
      record_loop_failure "reviewer command failed: ${output%%$'\n'*}"
      continue
    fi
    rm -f "$prompt_file"

    clear_loop_failure
    update_state_value "journal_review_offset" "$journal_new_offset"
    update_state_value "last_review_signature" "$signature"

    output="$(printf '%s' "$output" | sed '/^[[:space:]]*$/d')"
    output_last_line="$(printf '%s\n' "$output" | tail -n 1)"
    # Tolerate wrappers like "`NO_FEEDBACK`", "**NO_FEEDBACK**", "no_feedback."
    normalized_line="$(printf '%s\n' "$output_last_line" | sed 's/[^A-Za-z_]//g' | tr '[:lower:]' '[:upper:]')"
    if [[ -n "$output" && "$normalized_line" != "NO_FEEDBACK" ]]; then
      printf '\n[%s] [%s] %s\n' "$(date -Iseconds)" "${reviewer_provider:-reviewer}" "$output" >> "$FEEDBACK_FILE"
    fi
  done
}

command="${1:-}"
if [[ -z "$command" ]]; then
  usage
  exit 1
fi
shift || true

case "$command" in
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  status) cmd_status "$@" ;;
  task) cmd_task "$@" ;;
  log) cmd_log "$@" ;;
  intent) cmd_intent "$@" ;;
  progress) cmd_progress "$@" ;;
  outcome) cmd_outcome "$@" ;;
  feedback) cmd_feedback "$@" ;;
  check) cmd_check "$@" ;;
  bypass) cmd_bypass "$@" ;;
  gate) cmd_gate "$@" ;;
  hook-stop) cmd_hook_stop "$@" ;;
  run-loop) cmd_run_loop "$@" ;;
  -h|--help) usage ;;
  *)
    echo "Unknown command: $command" >&2
    usage >&2
    exit 1
    ;;
esac
