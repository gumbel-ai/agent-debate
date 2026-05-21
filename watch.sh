#!/usr/bin/env bash
# watch.sh — Async watcher feedback for a coding session
#
# Usage:
#   ./watch.sh start [--watcher alias]
#   ./watch.sh stop
#   ./watch.sh status
#   ./watch.sh log "one-line summary"
#   ./watch.sh check

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
  check                    Print unread watcher feedback and advance cursor
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

path, key, value = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    state = json.load(f)

if key in {"feedback_cursor", "loop_pid", "watch_interval"}:
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
  nohup "$WATCH_SCRIPT" loop >/dev/null 2>&1 &
  local pid="$!"
  printf '%s\n' "$pid" > "$PID_FILE"
  update_state_value "loop_pid" "$pid"

  local watcher_provider
  watcher_provider="$(json_value "watcher_provider")"
  echo "Watch mode on. ${watcher_alias} (${watcher_provider:-unknown}) will review asynchronously every ${interval}s."
}

cmd_stop() {
  if [[ ! -d "$WATCH_DIR" ]]; then
    echo "watch mode is not active"
    return
  fi

  local pid=""
  pid="$(state_loop_pid)"
  if [[ -n "$pid" ]] && live_pid "$pid"; then
    kill "$pid" 2>/dev/null || true
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

cmd_check() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "watch mode is not active"
    return
  fi

  touch "$FEEDBACK_FILE"
  local cursor size
  cursor="$(json_value "feedback_cursor")"
  if ! [[ "$cursor" =~ ^[0-9]+$ ]]; then
    cursor=0
  fi
  size="$(wc -c < "$FEEDBACK_FILE" | tr -d '[:space:]')"

  if [[ "$size" -gt "$cursor" ]]; then
    tail -c +"$((cursor + 1))" "$FEEDBACK_FILE"
  else
    echo "No unread watcher feedback."
  fi

  update_state_value "feedback_cursor" "$size"
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

    local watcher_alias host_provider watcher_provider watcher_json journal_tail diff_stat prompt_file output
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

    journal_tail="$(tail -n 80 "$JOURNAL_FILE" 2>/dev/null || true)"
    diff_stat="$(git diff --stat 2>/dev/null || true)"
    prompt_file="$(mktemp)"
    cat > "$prompt_file" <<EOF
You are watching a coding session asynchronously.
Primary provider: $host_provider
Watcher provider: $watcher_provider

Recent primary journal:
$journal_tail

Current git diff stat:
$diff_stat

Write at most one concise note if there is a concrete risk, missed requirement, or likely bug.
If there is no actionable feedback, output exactly NO_FEEDBACK.
EOF

    if ! output="$(invoke_watcher "$watcher_json" "$prompt_file" 2>&1)"; then
      rm -f "$prompt_file"
      append_system_feedback "watcher command failed: ${output%%$'\n'*}"
      continue
    fi
    rm -f "$prompt_file"

    output="$(printf '%s' "$output" | sed '/^[[:space:]]*$/d')"
    if [[ -n "$output" && "$output" != "NO_FEEDBACK" ]]; then
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
  check) cmd_check "$@" ;;
  loop) cmd_loop "$@" ;;
  -h|--help) usage ;;
  *)
    echo "Unknown command: $command" >&2
    usage >&2
    exit 1
    ;;
esac
