#!/usr/bin/env bash
# watch.sh — Async watcher feedback for a coding session
#
# Usage:
#   ./watch.sh start [--watcher alias]
#   ./watch.sh stop
#   ./watch.sh status
#   ./watch.sh log "one-line summary"
#   ./watch.sh intent "what + why + expected validation"
#   ./watch.sh progress "what changed + current risk"
#   ./watch.sh outcome "files changed + checks run + remaining risk"
#   ./watch.sh feedback accept|deny|park "summary/reason"
#   ./watch.sh check [--strict]

set -euo pipefail

PROJECT_DIR="$(pwd)"
WATCH_DIR="$PROJECT_DIR/.agent-debate/watch"
STATE_FILE="$WATCH_DIR/state.json"
JOURNAL_FILE="$WATCH_DIR/journal.md"
FEEDBACK_FILE="$WATCH_DIR/feedback.md"
PID_FILE="$WATCH_DIR/loop.pid"
DEFAULT_INTERVAL=60

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_SOURCE" = /* ]]; then
  WATCH_SCRIPT="$SCRIPT_SOURCE"
else
  WATCH_SCRIPT="$PROJECT_DIR/$SCRIPT_SOURCE"
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") COMMAND

Commands:
  start [--watcher alias]  Start watch mode for this project
  stop                     Stop watch mode and archive the session files
  status                   Show active state and recent watcher feedback
  log "summary"            Append a primary-agent activity note
  intent "summary"         Append a structured intent ledger entry
  progress "summary"       Append a structured progress ledger entry
  outcome "summary"        Append a structured outcome ledger entry
  feedback ACTION "reason" Record feedback disposition; ACTION is accept, deny, or park
  check [--strict]         Print unread feedback; strict exits 2 on blockers
  gate                     Internal task-completion ledger gate
  hook-stop                Internal Stop-hook checkpoint
  loop                     Internal background watcher loop
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

default_watcher_alias() {
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
    fail(f"unknown watcher alias '{alias}'. Available: {available}")

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
  local watcher_alias="$2"
  local watcher_json="$3"
  local interval="$4"

  python3 - "$STATE_FILE" "$host_provider" "$watcher_alias" "$watcher_json" "$JOURNAL_FILE" "$FEEDBACK_FILE" "$interval" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

state_path, host_provider, watcher_alias, watcher_json, journal_path, feedback_path, interval = sys.argv[1:8]
watcher = json.loads(watcher_json)
state = {
    "host_provider": host_provider,
    "watcher_provider": watcher.get("provider", ""),
    "watcher_alias": watcher_alias,
    "journal_path": journal_path,
    "feedback_path": feedback_path,
    "feedback_cursor": 0,
    "ledger_completion_cursor": 0,
    "journal_review_offset": 0,
    "loop_pid": "",
    "started_at": datetime.now(timezone.utc).isoformat(),
    "watch_interval": int(interval),
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

try:
    with open(path, "r", encoding="utf-8") as f:
        state = json.load(f)

    if key in {"feedback_cursor", "journal_review_offset", "ledger_completion_cursor", "loop_pid", "watch_interval"}:
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

ensure_watch_dir() {
  mkdir -p "$WATCH_DIR"
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

  if [[ -x "$shared_path" ]]; then
    printf '%s' "$shared_path"
  elif [[ -x "$project_path" ]]; then
    printf '%s' "$project_path"
  else
    printf '%s' "$shared_path"
  fi
}

project_hook_commands_json() {
  local script_name="$1"
  local shared_path="$HOME/.agent-debate/hooks/$script_name"
  local project_path="$PROJECT_DIR/hooks/$script_name"

  python3 - "$shared_path" "$project_path" <<'PY'
import json
import sys

commands = []
for value in sys.argv[1:]:
    if value and value not in commands:
        commands.append(value)
json.dump(commands, sys.stdout)
PY
}

install_claude_project_hooks() {
  local stop_command="$1"
  local git_command="$2"
  local task_command="$3"
  local settings_path="$PROJECT_DIR/.claude/settings.local.json"

  mkdir -p "$(dirname "$settings_path")"
  python3 - "$settings_path" "$stop_command" "$git_command" "$task_command" <<'PY'
import json
import os
import sys

path, stop_command, git_command, task_command = sys.argv[1:5]

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

if not has_command("PreToolUse", git_command):
    append_group(
        "PreToolUse",
        {
            "matcher": "Bash",
            "hooks": [
                {
                    "type": "command",
                    "if": "Bash(git commit*)",
                    "command": git_command,
                }
            ],
        },
    )

if not has_command("PreToolUse", task_command):
    append_group(
        "PreToolUse",
        {
            "matcher": "TaskUpdate",
            "hooks": [{"type": "command", "command": task_command}],
        },
    )

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
  local hooks_path="$PROJECT_DIR/.codex/hooks.json"

  mkdir -p "$(dirname "$hooks_path")"
  python3 - "$hooks_path" "$stop_command" "$task_command" <<'PY'
import json
import os
import sys

path, stop_command, task_command = sys.argv[1:4]

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

tmp_path = f"{path}.tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp_path, path)
PY
}

install_project_hooks() {
  local host_provider="$1"
  local stop_command git_command task_command
  stop_command="$(hook_command_path "watch-stop.sh")"
  task_command="$(hook_command_path "watch-task-check.sh")"

  case "$host_provider" in
    claude)
      git_command="$(hook_command_path "watch-git-check.sh")"
      install_claude_project_hooks "$stop_command" "$git_command" "$task_command"
      ;;
    codex)
      install_codex_project_hooks "$stop_command" "$task_command"
      ;;
  esac
}

remove_project_hooks() {
  local host_provider="$1"
  local stop_commands git_commands task_commands combined_commands

  case "$host_provider" in
    claude)
      stop_commands="$(project_hook_commands_json "watch-stop.sh")"
      git_commands="$(project_hook_commands_json "watch-git-check.sh")"
      task_commands="$(project_hook_commands_json "watch-task-check.sh")"
      combined_commands="$(python3 - "$stop_commands" "$git_commands" "$task_commands" <<'PY'
import json
import sys

combined = []
for raw in sys.argv[1:]:
    for value in json.loads(raw):
        if value not in combined:
            combined.append(value)
json.dump(combined, sys.stdout)
PY
)"
      remove_project_hook_commands "$PROJECT_DIR/.claude/settings.local.json" "$combined_commands"
      ;;
    codex)
      stop_commands="$(project_hook_commands_json "watch-stop.sh")"
      task_commands="$(project_hook_commands_json "watch-task-check.sh")"
      combined_commands="$(python3 - "$stop_commands" "$task_commands" <<'PY'
import json
import sys

combined = []
for raw in sys.argv[1:]:
    for value in json.loads(raw):
        if value not in combined:
            combined.append(value)
json.dump(combined, sys.stdout)
PY
)"
      remove_project_hook_commands "$PROJECT_DIR/.codex/hooks.json" "$combined_commands"
      ;;
  esac
}

cmd_start() {
  local watcher_alias=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --watcher)
        watcher_alias="${2:-}"
        if [[ -z "$watcher_alias" ]]; then
          echo "Error: --watcher requires an alias" >&2
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

  ensure_watch_dir

  local existing_pid
  existing_pid="$(state_loop_pid)"
  if [[ -n "$existing_pid" ]] && live_pid "$existing_pid"; then
    echo "watch mode already active"
    exit 1
  fi

  if [[ -f "$STATE_FILE" || -f "$PID_FILE" ]]; then
    echo "watch mode had stale state; replacing it"
    rm -f "$STATE_FILE" "$PID_FILE"
  fi

  reset_active_files

  local host_provider
  host_provider="$(detect_host_provider)"
  if [[ "$host_provider" != "claude" && "$host_provider" != "codex" ]]; then
    echo "Error: could not detect host provider. Set AGENT_DEBATE_HOST_PROVIDER=claude|codex." >&2
    exit 1
  fi

  if [[ -z "$watcher_alias" ]]; then
    watcher_alias="$(default_watcher_alias "$host_provider")"
  fi

  local watcher_json
  watcher_json="$(resolve_alias_json "$watcher_alias")"

  local interval="${WATCH_INTERVAL:-$DEFAULT_INTERVAL}"
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
    echo "Error: WATCH_INTERVAL must be a positive integer number of seconds" >&2
    exit 1
  fi

  write_initial_state "$host_provider" "$watcher_alias" "$watcher_json" "$interval"
  if ! install_project_hooks "$host_provider"; then
    rm -f "$STATE_FILE" "$PID_FILE" "$JOURNAL_FILE" "$FEEDBACK_FILE"
    exit 1
  fi
  nohup "$WATCH_SCRIPT" loop >/dev/null 2>&1 &
  local pid="$!"
  printf '%s\n' "$pid" > "$PID_FILE"
  update_state_value "loop_pid" "$pid"

  local watcher_provider
  watcher_provider="$(json_value "watcher_provider")"
  echo "Watch mode on. ${watcher_alias} (${watcher_provider:-unknown}) will review asynchronously every ${interval}s."
  cat <<'EOF'
Watch ledger contract:
- Before marking a todo/task complete, run: ./watch.sh intent "what + why + expected validation"
- Check feedback with: ./watch.sh check
- If feedback exists, record a disposition before completing: ./watch.sh feedback accept|deny|park "reason"
- Optional context: ./watch.sh progress "..." and ./watch.sh outcome "..."
- Emergency bypass for one gate: WATCH_LEDGER_OFF=1
EOF
}

cmd_stop() {
  if [[ ! -d "$WATCH_DIR" ]]; then
    echo "watch mode is not active"
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

  local archive_dir="$WATCH_DIR/archive/$archive_name"
  mkdir -p "$archive_dir"
  [[ -f "$JOURNAL_FILE" ]] && cp "$JOURNAL_FILE" "$archive_dir/journal.md"
  [[ -f "$FEEDBACK_FILE" ]] && cp "$FEEDBACK_FILE" "$archive_dir/feedback.md"
  [[ -f "$STATE_FILE" ]] && cp "$STATE_FILE" "$archive_dir/state.json"

  rm -f "$STATE_FILE" "$PID_FILE" "$JOURNAL_FILE" "$FEEDBACK_FILE"
  echo "Watch mode off. Archived session to $archive_dir"
}

cmd_status() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "watch mode is not active"
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
    echo "watch mode is not active"
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

cmd_feedback() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "watch mode is not active"
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

  cmd_log "feedback-action: $action $*"
  touch "$FEEDBACK_FILE"
  update_state_value "feedback_cursor" "$(file_size "$FEEDBACK_FILE")"
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
      echo "watch mode is not active"
    fi
    return 0
  fi

  touch "$FEEDBACK_FILE"
  local cursor size blocked=false unread=""
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
    if [[ "$strict" == true ]]; then
      {
        echo "Unread watcher feedback requires attention before continuing:"
        printf '%s\n' "$unread"
        echo "Record a disposition with: ./watch.sh feedback accept|deny|park \"reason\""
      } >&2
      blocked=true
    else
      printf '%s\n' "$unread"
      echo "Feedback remains unread until you run: ./watch.sh feedback accept|deny|park \"reason\""
    fi
  else
    if [[ "$strict" == false ]]; then
      echo "No unread watcher feedback."
    fi
  fi

  if [[ "$strict" == true ]]; then
    local pid
    pid="$(state_loop_pid)"
    if [[ -z "$pid" ]] || ! live_pid "$pid"; then
      echo "watcher loop is not running; run ./watch.sh status or ./watch.sh stop" >&2
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

  if [[ "${WATCH_LEDGER_OFF:-}" == "1" ]]; then
    cmd_log "outcome: ledger-gate bypassed (WATCH_LEDGER_OFF)"
    echo "watch ledger gate bypassed by WATCH_LEDGER_OFF=1" >&2
    return 0
  fi

  touch "$JOURNAL_FILE" "$FEEDBACK_FILE"

  local analysis
  if ! analysis="$(python3 - "$STATE_FILE" "$JOURNAL_FILE" "$FEEDBACK_FILE" 2>/dev/null <<'PY'
import json
import os
import sys

state_path, journal_path, feedback_path = sys.argv[1:4]
with open(state_path, "r", encoding="utf-8") as f:
    state = json.load(f)

def int_value(key):
    try:
        return int(state.get(key, 0))
    except (TypeError, ValueError):
        return 0

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
has_unread_feedback = feedback_size > feedback_cursor

print("1" if has_intent else "0")
print("1" if has_unread_feedback else "0")
print(journal_size)
PY
  )"; then
    echo "watch ledger gate could not read state; allowing completion" >&2
    return 0
  fi

  local has_intent has_unread_feedback journal_size blocked=false
  has_intent="$(printf '%s\n' "$analysis" | sed -n '1p')"
  has_unread_feedback="$(printf '%s\n' "$analysis" | sed -n '2p')"
  journal_size="$(printf '%s\n' "$analysis" | sed -n '3p')"

  if [[ "$has_intent" != "1" ]]; then
    echo "Watch ledger requires intent before task completion." >&2
    echo "Run: ./watch.sh intent \"what + why + expected validation\"" >&2
    blocked=true
  fi

  if [[ "$has_unread_feedback" == "1" ]]; then
    echo "Unread watcher feedback requires disposition before task completion." >&2
    echo "Run: ./watch.sh feedback accept|deny|park \"reason\"" >&2
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
  local cursor size
  cursor="$(state_int_value "feedback_cursor" 0)"
  size="$(file_size "$FEEDBACK_FILE")"
  if [[ "$cursor" -gt "$size" ]]; then
    cursor=0
  fi
  if [[ "$size" -gt "$cursor" ]]; then
    echo "Unread watcher feedback is available; run ./watch.sh check" >&2
  fi
  return 0
}

invoke_watcher() {
  local watcher_json="$1"
  local prompt_file="$2"

  python3 - "$watcher_json" "$prompt_file" <<'PY'
import json
import os
import subprocess
import sys

watcher = json.loads(sys.argv[1])
prompt_file = sys.argv[2]

command = watcher.get("command", [])
transport = watcher.get("prompt_transport", "arg")
provider = str(watcher.get("provider", "")).strip().lower()

if not isinstance(command, list) or not command:
    print("Error: invalid watcher command", file=sys.stderr)
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

if transport == "stdin":
    result = subprocess.run(command, input=prompt, capture_output=True, text=True, env=env)
else:
    result = subprocess.run(command + [prompt], capture_output=True, text=True, env=env)

if result.returncode != 0:
    if result.stderr:
        sys.stderr.write(result.stderr.splitlines()[0] + "\n")
    raise SystemExit(result.returncode)

sys.stdout.write(result.stdout)
PY
}

append_system_feedback() {
  local message="$1"
  printf '\n[%s] [watch-system] %s\n' "$(date -Iseconds)" "$message" >> "$FEEDBACK_FILE"
}

cmd_loop() {
  while [[ -f "$PID_FILE" ]]; do
    local interval
    interval="$DEFAULT_INTERVAL"
    if [[ -f "$STATE_FILE" ]]; then
      interval="$(json_value "watch_interval" 2>/dev/null || printf '%s' "$DEFAULT_INTERVAL")"
    fi
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
      interval="$DEFAULT_INTERVAL"
    fi

    sleep "$interval"
    [[ -f "$PID_FILE" && -f "$STATE_FILE" ]] || break

    local watcher_alias host_provider watcher_provider watcher_json journal_tail journal_slice_file journal_new_offset
    local diff_stat git_status feedback_status feedback_cursor feedback_size prompt_file output output_last_line
    watcher_alias="$(json_value "watcher_alias")"
    host_provider="$(json_value "host_provider")"

    if ! watcher_json="$(resolve_alias_json "$watcher_alias" 2>&1)"; then
      append_system_feedback "watcher command failed: $watcher_json"
      continue
    fi

    watcher_provider="$(python3 - "$watcher_json" <<'PY'
import json
import sys
watcher = json.loads(sys.argv[1])
print(watcher.get("provider", ""))
PY
)"

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

    diff_stat="$(git diff --stat 2>/dev/null || true)"
    git_status="$(git status --short 2>/dev/null || true)"
    feedback_size="$(file_size "$FEEDBACK_FILE")"
    feedback_cursor="$(state_int_value "feedback_cursor" 0)"
    if [[ "$feedback_cursor" -gt "$feedback_size" ]]; then
      feedback_cursor=0
    fi
    if [[ "$feedback_size" -gt "$feedback_cursor" ]]; then
      feedback_status="unread feedback pending; primary must run ./watch.sh feedback accept|deny|park"
    else
      feedback_status="clear"
    fi
    prompt_file="$(mktemp)"
    cat > "$prompt_file" <<EOF
You are watching a coding session asynchronously.
Primary provider: $host_provider
Watcher provider: $watcher_provider

New primary journal since last watcher pass:
$journal_tail

Current git status --short:
$git_status

Current git diff stat:
$diff_stat

Unread feedback disposition status:
$feedback_status

Write at most one concise note if there is a concrete risk, missed requirement, or likely bug.
If there is no actionable feedback, output a single line: NO_FEEDBACK.
EOF

    if ! output="$(invoke_watcher "$watcher_json" "$prompt_file" 2>&1)"; then
      rm -f "$prompt_file"
      append_system_feedback "watcher command failed: ${output%%$'\n'*}"
      continue
    fi
    rm -f "$prompt_file"

    update_state_value "journal_review_offset" "$journal_new_offset"

    output="$(printf '%s' "$output" | sed '/^[[:space:]]*$/d')"
    output_last_line="$(printf '%s\n' "$output" | tail -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -n "$output" && "$output_last_line" != "NO_FEEDBACK" ]]; then
      printf '\n[%s] [%s] %s\n' "$(date -Iseconds)" "${watcher_provider:-watcher}" "$output" >> "$FEEDBACK_FILE"
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
  log) cmd_log "$@" ;;
  intent) cmd_intent "$@" ;;
  progress) cmd_progress "$@" ;;
  outcome) cmd_outcome "$@" ;;
  feedback) cmd_feedback "$@" ;;
  check) cmd_check "$@" ;;
  gate) cmd_gate "$@" ;;
  hook-stop) cmd_hook_stop "$@" ;;
  loop) cmd_loop "$@" ;;
  -h|--help) usage ;;
  *)
    echo "Unknown command: $command" >&2
    usage >&2
    exit 1
    ;;
esac
