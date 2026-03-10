#!/usr/bin/env bash
# orchestrate.sh — Runs an agent debate via shared markdown file
#
# Usage:
#   ./orchestrate.sh --topic "question" --rounds 3
#   ./orchestrate.sh --topic "question" --agents opus,codex,sonnet --rounds 2
#   ./orchestrate.sh --resume path/to/debate.md --rounds 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
DEBATES_DIR="$PROJECT_DIR/debates"
GUARDRAILS="$SCRIPT_DIR/agent-guardrails.md"
TEMPLATE="$SCRIPT_DIR/TEMPLATE.md"

# Defaults
MAX_ROUNDS=3
TOPIC=""
FILES=""
RESUME_FILE=""
CONSTRAINTS=""
AGENT_1="Claude"
AGENT_2="Codex"
AGENT1_OVERRIDE_NAME=""
AGENT2_OVERRIDE_NAME=""
AGENT3_OVERRIDE_NAME=""
CONFIG_FILE=""
AGENTS_SPEC=""
RUNTIME_CONFIG_FILE=""
AGENT_COUNT=0
declare -a AGENT_NAMES=()
declare -a AGENT_PROVIDERS=()
HOST_PROVIDER=""
SKIP_PROVIDER=""
STATE_FILE=""
PLAN_MODE=true
PLAN_ROUNDS=2

cleanup() {
  if [[ -n "${RUNTIME_CONFIG_FILE:-}" && -f "${RUNTIME_CONFIG_FILE:-}" ]]; then
    rm -f "$RUNTIME_CONFIG_FILE"
  fi
}

trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Start a new debate:
  --topic "question"          The debate topic (required for new debates)
  --files file1 file2 ...     Relevant source files to include as context
  --constraints "text"        Non-negotiable constraints
  --agents a,b[,c]            Agent aliases/models (e.g. opus,codex or gemini,codex,sonnet)
  --config path/to/config.json  Agent configuration file (optional)
  --skip-provider name        Skip invoking one provider (claude|codex|gemini) in this run; required when host provider is in lineup
  --rounds N                  Max rounds per agent (default: 3)
  --agent1 name               Override Agent 1 display name
  --agent2 name               Override Agent 2 display name
  --agent3 name               Override Agent 3 display name
  --plan                      Force-enable Implementation Plan phase (default: enabled)
  --no-plan                   Disable Implementation Plan phase for this run
  --plan-rounds N             Max plan review rounds (default: 2)

Resume an existing debate:
  --resume path/to/debate.md  Path to existing debate file
  --rounds N                  Additional rounds to run

Exit codes:
  0  Success (debate completed)
  1  Failure
  2  Paused for host-direct turn (missing required host tag)

EOF
  exit 1
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic) TOPIC="$2"; shift 2 ;;
    --files) shift; FILES=""; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do FILES="$FILES $1"; shift; done ;;
    --constraints) CONSTRAINTS="$2"; shift 2 ;;
    --agents) AGENTS_SPEC="$2"; shift 2 ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --skip-provider) SKIP_PROVIDER="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    --rounds) MAX_ROUNDS="$2"; shift 2 ;;
    --resume) RESUME_FILE="$2"; shift 2 ;;
    --agent1) AGENT1_OVERRIDE_NAME="$2"; shift 2 ;;
    --agent2) AGENT2_OVERRIDE_NAME="$2"; shift 2 ;;
    --agent3) AGENT3_OVERRIDE_NAME="$2"; shift 2 ;;
    --plan) PLAN_MODE=true; shift ;;
    --no-plan) PLAN_MODE=false; shift ;;
    --plan-rounds) PLAN_ROUNDS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Validate
if [[ -z "$RESUME_FILE" && -z "$TOPIC" ]]; then
  echo "Error: --topic is required for new debates (or use --resume)"
  usage
fi

resolve_config() {
  if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
      echo "Error: config file not found: $CONFIG_FILE"
      exit 1
    fi
    return
  fi

  if [[ -f "./debate.config.json" ]]; then
    CONFIG_FILE="./debate.config.json"
  elif [[ -f "$HOME/.agent-debate/config.json" ]]; then
    CONFIG_FILE="$HOME/.agent-debate/config.json"
  else
    CONFIG_FILE=""
  fi
}

detect_host_provider() {
  if [[ -n "${AGENT_DEBATE_HOST_PROVIDER:-}" ]]; then
    HOST_PROVIDER="$(printf '%s' "$AGENT_DEBATE_HOST_PROVIDER" | tr '[:upper:]' '[:lower:]')"
    return
  fi

  if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    HOST_PROVIDER="codex"
  elif [[ -n "${CLAUDE_CODE_SSE_PORT:-}" || -n "${CLAUDECODE:-}" ]]; then
    HOST_PROVIDER="claude"
  elif [[ -n "${GEMINI_CLI_SESSION:-}" || -n "${GEMINI_SESSION_ID:-}" ]]; then
    HOST_PROVIDER="gemini"
  else
    HOST_PROVIDER=""
  fi
}

resolve_agents() {
  RUNTIME_CONFIG_FILE=$(mktemp)

  local resolution_output
  if ! resolution_output=$(python3 - "$CONFIG_FILE" "$AGENTS_SPEC" "$RUNTIME_CONFIG_FILE" "$HOST_PROVIDER" "$SKIP_PROVIDER" <<'PY'
import json
import os
import sys

config_path = sys.argv[1]
agents_spec = sys.argv[2].strip()
out_path = sys.argv[3]
host_provider = sys.argv[4].strip().lower()
skip_provider = sys.argv[5].strip().lower()

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
    "gemini": {
        "name": "Gemini (Auto)",
        "provider": "gemini",
        "command_template": ["gemini", "-p"],
        "prompt_transport": "arg",
    },
}

BUILTIN_DEBATE = {
    "default_agents": ["opus", "codex"],
    "min_agents": 2,
    "max_agents": 3,
}

def fail(msg: str) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(1)

if config_path:
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except json.JSONDecodeError as e:
        fail(f"invalid JSON in config ({config_path}): {e}")

    aliases = cfg.get("aliases")
    debate = cfg.get("debate")
    if not isinstance(aliases, dict) or not aliases:
        fail("config.aliases must be a non-empty object")
    if not isinstance(debate, dict):
        fail("config.debate must be an object")

    default_agents = debate.get("default_agents")
    min_agents = debate.get("min_agents", 2)
    max_agents = debate.get("max_agents", 3)
else:
    aliases = BUILTIN_ALIASES
    default_agents = BUILTIN_DEBATE["default_agents"]
    min_agents = BUILTIN_DEBATE["min_agents"]
    max_agents = BUILTIN_DEBATE["max_agents"]

if not isinstance(default_agents, list) or not default_agents:
    fail("debate.default_agents must be a non-empty array")
if not isinstance(min_agents, int) or not isinstance(max_agents, int) or min_agents > max_agents:
    fail("debate.min_agents/max_agents must be valid integers with min_agents <= max_agents")

if agents_spec:
    requested = [tok.strip() for tok in agents_spec.split(",") if tok.strip()]
else:
    requested = list(default_agents)

if len(requested) < min_agents or len(requested) > max_agents:
    fail(f"agent count must be between {min_agents} and {max_agents}, got {len(requested)}")

resolved = []
unique_participants = set()
provider_counts = {}

for token in requested:
    if ":" in token:
        alias_raw, model_override = token.split(":", 1)
        model_override = model_override.strip()
    else:
        alias_raw, model_override = token, ""

    alias = alias_raw.strip().lower()
    if alias not in aliases:
        available = ", ".join(sorted(aliases.keys()))
        fail(f"unknown alias '{alias}'. Available: {available}")

    spec = aliases[alias]
    if not isinstance(spec, dict):
        fail(f"alias '{alias}' must be an object")

    provider = spec.get("provider", "")
    if provider is None:
        provider = ""
    if not isinstance(provider, str):
        fail(f"alias '{alias}' provider must be a string when set")
    provider = provider.strip().lower()

    name = spec.get("name")
    if not isinstance(name, str) or not name.strip():
        fail(f"alias '{alias}' has invalid name")

    template = spec.get("command_template")
    if not isinstance(template, list) or not template or not all(isinstance(x, str) and x for x in template):
        fail(f"alias '{alias}' command_template must be a non-empty array of strings")

    transport = spec.get("prompt_transport", "arg")
    if transport not in ("arg", "stdin"):
        fail(f"alias '{alias}' prompt_transport must be 'arg' or 'stdin'")

    has_model_placeholder = any("{MODEL}" in part for part in template)
    has_effort_placeholder = any("{EFFORT}" in part for part in template)

    model_value = model_override or spec.get("default_model", "")
    reasoning = spec.get("reasoning", {})
    if reasoning is None:
        reasoning = {}
    if not isinstance(reasoning, dict):
        fail(f"alias '{alias}' reasoning must be an object")
    effort_value = reasoning.get("default", "")
    if has_effort_placeholder and not effort_value:
        fail(f"alias '{alias}' requires reasoning.default when using {{EFFORT}}")
    allowed_efforts = reasoning.get("allowed")
    if effort_value and allowed_efforts is not None:
        if not isinstance(allowed_efforts, list) or not all(isinstance(v, str) and v for v in allowed_efforts):
            fail(f"alias '{alias}' reasoning.allowed must be an array of non-empty strings")
        if effort_value not in allowed_efforts:
            fail(f"alias '{alias}' reasoning.default '{effort_value}' is not in reasoning.allowed")

    cmd = []
    for part in template:
        if "{MODEL}" in part:
            if not model_value:
                fail(f"alias '{alias}' requires a model override or default_model")
            part = part.replace("{MODEL}", model_value)
        if "{EFFORT}" in part:
            if not effort_value:
                fail(f"alias '{alias}' requires reasoning.default when using {{EFFORT}}")
            part = part.replace("{EFFORT}", effort_value)
        cmd.append(part)

    # If model override given but no {MODEL} placeholder, append --model <value>
    if model_override and not has_model_placeholder:
        cmd.extend(["--model", model_override])

    if not provider and cmd:
        cmd_base = os.path.basename(cmd[0]).lower()
        if cmd_base in ("claude", "codex", "gemini"):
            provider = cmd_base

    participant_key = (alias, model_value)
    unique_participants.add(participant_key)

    resolved.append(
        {
            "name": name.strip(),
            "provider": provider,
            "command": cmd,
            "prompt_transport": transport,
        }
    )
    provider_key = provider or "unknown"
    provider_counts[provider_key] = provider_counts.get(provider_key, 0) + 1

if len(unique_participants) < 2:
    fail("need at least two unique participants")

if host_provider in ("claude", "codex", "gemini"):
    host_count = provider_counts.get(host_provider, 0)
    if host_count > 0 and skip_provider != host_provider:
        fail(
            f"host session '{host_provider}' includes {host_count} alias(es) from the host provider. "
            f"Use --skip-provider {host_provider} so the host can take its own turns directly while orchestrator runs other providers."
        )

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"agents": resolved}, f)

print(len(resolved))
for agent in resolved:
    print(f"{agent['name']}\t{agent.get('provider', '')}")
PY
  ); then
    exit 1
  fi

  local resolved_lines=()
  local line
  while IFS= read -r line; do
    resolved_lines+=("$line")
  done <<< "$resolution_output"

  if [[ ${#resolved_lines[@]} -lt 2 ]]; then
    echo "Error: failed to resolve agent config"
    exit 1
  fi

  AGENT_COUNT="${resolved_lines[0]}"
  AGENT_NAMES=()
  AGENT_PROVIDERS=()
  local i
  local resolved_name resolved_provider
  for (( i=1; i<${#resolved_lines[@]}; i++ )); do
    IFS=$'\t' read -r resolved_name resolved_provider <<< "${resolved_lines[$i]}"
    if [[ -z "$resolved_name" ]]; then
      echo "Error: resolved agent entry missing name"
      exit 1
    fi
    AGENT_NAMES+=("$resolved_name")
    AGENT_PROVIDERS+=("$resolved_provider")
  done

  if [[ "${#AGENT_NAMES[@]}" -ne "$AGENT_COUNT" ]]; then
    echo "Error: resolved agent count mismatch"
    exit 1
  fi
  if [[ "${#AGENT_PROVIDERS[@]}" -ne "$AGENT_COUNT" ]]; then
    echo "Error: resolved provider count mismatch"
    exit 1
  fi

  AGENT_1="${AGENT_NAMES[0]}"
  AGENT_2="${AGENT_NAMES[1]}"
}

guardrails_support_three_agents() {
  grep -q "{OTHER_AGENTS}" "$GUARDRAILS" && grep -q "\[A3-R1\]" "$GUARDRAILS"
}

escape_for_sed() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

has_open_disputes() {
  grep -Eq '^\|.*\|[[:space:]]*OPEN[[:space:]]*\|[[:space:]]*$' "$DEBATE_FILE"
}

tag_for_turn() {
  local agent_idx="$1"
  local round="$2"
  printf '[A%s-R%s]' "$agent_idx" "$round"
}

count_tag_in_file() {
  local file="$1"
  local tag="$2"
  local count
  count=$(grep -oF "$tag" "$file" 2>/dev/null | wc -l || true)
  count=$(printf '%s' "$count" | tr -d '[:space:]')
  [[ -z "$count" ]] && count=0
  printf '%s' "$count"
}

count_tag_in_text() {
  local text="$1"
  local tag="$2"
  local count
  count=$(printf '%s' "$text" | grep -oF "$tag" 2>/dev/null | wc -l || true)
  count=$(printf '%s' "$count" | tr -d '[:space:]')
  [[ -z "$count" ]] && count=0
  printf '%s' "$count"
}

looks_like_debate_file() {
  local content="$1"
  [[ "$content" == *"## Proposal"* ]] \
    && [[ "$content" == *"## Dispute Log"* ]] \
    && [[ "$content" == *"| Round | Agent |"* ]]
}

all_agents_contributed_in_round() {
  local round="$1"
  local idx tag
  for (( idx=1; idx<=AGENT_COUNT; idx++ )); do
    tag=$(tag_for_turn "$idx" "$round")
    if [[ "$(count_tag_in_file "$DEBATE_FILE" "$tag")" -eq 0 ]]; then
      return 1
    fi
  done
  return 0
}

is_converged() {
  local round="$1"
  grep -q "STATUS: CONVERGED" "$DEBATE_FILE" \
    && ! has_open_disputes \
    && all_agents_contributed_in_round "$round"
}

is_plan_converged() {
  python3 - "$DEBATE_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

m = re.search(r"^## Implementation Plan\s*$", text, re.MULTILINE)
if not m:
    raise SystemExit(1)

section = text[m.end():]
m_next = re.search(r"^##\s+", section, re.MULTILINE)
if m_next:
    section = section[:m_next.start()]

for line in section.splitlines():
    line = line.strip()
    if not line:
        continue
    m_status = re.match(r"^PLAN_STATUS:\s*([A-Z_]+)\s*$", line)
    if m_status:
        raise SystemExit(0 if m_status.group(1) == "CONVERGED" else 1)

raise SystemExit(1)
PY
  [[ $? -eq 0 ]] && ! has_open_disputes
}

state_init() {
  python3 - "$STATE_FILE" "$DEBATE_FILE" "$HOST_PROVIDER" "$SKIP_PROVIDER" "$AGENT_COUNT" "${AGENT_NAMES[@]}" -- "${AGENT_PROVIDERS[@]}" <<'PY'
import json
import sys
from datetime import datetime, timezone

state_file = sys.argv[1]
debate_file = sys.argv[2]
host_provider = sys.argv[3]
skip_provider = sys.argv[4]
agent_count = int(sys.argv[5])
args = sys.argv[6:]
sep = args.index("--")
agent_names = args[:sep]
agent_providers = args[sep + 1:]

planned_agents = []
for idx in range(agent_count):
    planned_agents.append(
        {
            "index": idx + 1,
            "name": agent_names[idx] if idx < len(agent_names) else f"Agent {idx + 1}",
            "provider": agent_providers[idx] if idx < len(agent_providers) else "",
        }
    )

state = {
    "version": 1,
    "debate_file": debate_file,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "host_provider": host_provider,
    "skip_provider": skip_provider,
    "status": "running",
    "planned_agents": planned_agents,
    "events": [],
}

with open(state_file, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
PY
}

state_add_event() {
  local event_type="$1"
  local round="$2"
  local agent_idx="$3"
  local status="$4"
  local detail="$5"
  python3 - "$STATE_FILE" "$event_type" "$round" "$agent_idx" "$status" "$detail" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

state_file, event_type, round_s, agent_idx_s, status, detail = sys.argv[1:7]

if os.path.exists(state_file):
    with open(state_file, "r", encoding="utf-8") as f:
        state = json.load(f)
else:
    state = {"events": [], "status": "running"}

events = state.setdefault("events", [])
events.append(
    {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "type": event_type,
        "round": int(round_s),
        "agent_index": int(agent_idx_s),
        "status": status,
        "detail": detail,
    }
)

with open(state_file, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
PY
}

state_set_status() {
  local status="$1"
  local detail="$2"
  local round="$3"
  python3 - "$STATE_FILE" "$status" "$detail" "$round" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

state_file, status, detail, round_s = sys.argv[1:5]
if os.path.exists(state_file):
    with open(state_file, "r", encoding="utf-8") as f:
        state = json.load(f)
else:
    state = {"events": []}

state["status"] = status
state["updated_at"] = datetime.now(timezone.utc).isoformat()
state["last_detail"] = detail
state["current_round"] = int(round_s)

with open(state_file, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
PY
}

ensure_host_turn_present() {
  local agent_idx="$1"
  local round="$2"
  local tag
  tag=$(tag_for_turn "$agent_idx" "$round")
  if [[ "$(count_tag_in_file "$DEBATE_FILE" "$tag")" -eq 0 ]]; then
    echo "  Host action required: missing $tag for ${AGENT_NAMES[$((agent_idx - 1))]} in Round $round."
    echo "  Add your host-provider edit in the debate file, then rerun with --resume \"$DEBATE_FILE\"."
    state_add_event "turn" "$round" "$agent_idx" "pending_host" "Missing required host tag $tag"
    return 1
  fi
  state_add_event "turn" "$round" "$agent_idx" "host_completed" "Found host tag $tag"
  return 0
}

verify_round_participation() {
  local round="$1"
  local idx tag
  local missing=""
  for (( idx=1; idx<=AGENT_COUNT; idx++ )); do
    tag=$(tag_for_turn "$idx" "$round")
    if [[ "$(count_tag_in_file "$DEBATE_FILE" "$tag")" -eq 0 ]]; then
      if [[ -z "$missing" ]]; then
        missing="$tag"
      else
        missing="$missing, $tag"
      fi
    fi
  done
  if [[ -n "$missing" ]]; then
    echo "  Error: round $round is incomplete. Missing tags: $missing"
    state_set_status "failed" "Round $round incomplete: missing $missing" "$round"
    return 1
  fi
  return 0
}

agent_list_text() {
  local joined="${AGENT_NAMES[0]}"
  local idx
  for (( idx=1; idx<AGENT_COUNT; idx++ )); do
    joined="${joined}, ${AGENT_NAMES[$idx]}"
  done
  printf '%s' "$joined"
}

resolve_config
detect_host_provider
resolve_agents

if [[ -n "$AGENT1_OVERRIDE_NAME" ]]; then
  AGENT_NAMES[0]="$AGENT1_OVERRIDE_NAME"
fi
if [[ -n "$AGENT2_OVERRIDE_NAME" ]]; then
  AGENT_NAMES[1]="$AGENT2_OVERRIDE_NAME"
fi
if [[ -n "$AGENT3_OVERRIDE_NAME" && "$AGENT_COUNT" -ge 3 ]]; then
  AGENT_NAMES[2]="$AGENT3_OVERRIDE_NAME"
fi

AGENT_1="${AGENT_NAMES[0]}"
AGENT_2="${AGENT_NAMES[1]}"

if [[ "$AGENT_COUNT" -eq 3 ]] && ! guardrails_support_three_agents; then
  echo "Error: 3-agent debate requires guardrails v2"
  exit 1
fi

# --- Create or resume debate file ---

if [[ -n "$RESUME_FILE" ]]; then
  DEBATE_FILE="$RESUME_FILE"
  if [[ ! -f "$DEBATE_FILE" ]]; then
    echo "Error: debate file not found: $DEBATE_FILE"
    exit 1
  fi
  echo "Resuming debate: $DEBATE_FILE"
  # Detect current round from file
  CURRENT_ROUND=$(grep -Ec '^\|[[:space:]]*R[0-9]+[[:space:]]*\|' "$DEBATE_FILE" 2>/dev/null || true)
  [[ -z "$CURRENT_ROUND" ]] && CURRENT_ROUND=0
  CURRENT_ROUND=$(( (CURRENT_ROUND / AGENT_COUNT) + 1 ))
else
  mkdir -p "$DEBATES_DIR"
  # Auto-increment debate number from existing files (safe when directory is empty)
  LAST_NUM=0
  shopt -s nullglob
  for path in "$DEBATES_DIR"/*.md; do
    base="${path##*/}"
    if [[ "$base" =~ ^([0-9]+)- ]]; then
      num="${BASH_REMATCH[1]}"
      if (( num > LAST_NUM )); then
        LAST_NUM="$num"
      fi
    fi
  done
  shopt -u nullglob
  NEXT_NUM=$(( LAST_NUM + 1 ))
  SLUG=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 40)
  DEBATE_FILE="$DEBATES_DIR/${NEXT_NUM}-$(date +%Y-%m-%d)-${SLUG}.md"
  CURRENT_ROUND=1

  # Build file context section
  FILE_CONTEXT=""
  if [[ -n "$FILES" ]]; then
    for f in $FILES; do
      if [[ -f "$f" ]]; then
        FILE_CONTEXT="$FILE_CONTEXT\n- \`$f\`"
      else
        echo "Warning: file not found, skipping: $f"
      fi
    done
  fi
  [[ -z "$FILE_CONTEXT" ]] && FILE_CONTEXT="None specified — agents should explore as needed."

  CONSTRAINT_TEXT="${CONSTRAINTS:-None specified.}"

  # Create debate file from template
  sed \
    -e "s|{TOPIC}|$TOPIC|g" \
    -e "s|{DATE}|$(date +%Y-%m-%d)|g" \
    -e "s|{AGENT_1_NAME}|$AGENT_1|g" \
    -e "s|{AGENT_2_NAME}|$AGENT_2|g" \
    -e "s|{MAX_ROUNDS}|$MAX_ROUNDS|g" \
    -e "s|{PROBLEM_DESCRIPTION}|$TOPIC|g" \
    -e "s|{FILE_LIST_WITH_KEY_SECTIONS}|$FILE_CONTEXT|g" \
    -e "s|{ANY_CONSTRAINTS_OR_NON_NEGOTIABLES}|$CONSTRAINT_TEXT|g" \
    "$TEMPLATE" > "$DEBATE_FILE"

  # Handle Agent 3: substitute or remove the placeholder line
  tmp_debate=""
  tmp_debate=$(mktemp)
  if [[ "$AGENT_COUNT" -ge 3 ]]; then
    sed "s|{AGENT_3_NAME}|${AGENT_NAMES[2]}|g" "$DEBATE_FILE" > "$tmp_debate"
  else
    sed '/{AGENT_3_NAME}/d' "$DEBATE_FILE" > "$tmp_debate"
  fi
  mv "$tmp_debate" "$DEBATE_FILE"

  echo "Created debate file: $DEBATE_FILE"
fi

STATE_FILE="${DEBATE_FILE%.md}.state.json"
state_init

# --- Read guardrails ---
GUARDRAILS_TEXT=$(cat "$GUARDRAILS")

# --- Debate loop ---

invoke_agent() {
  local agent_idx="$1"
  local round="$2"
  local phase="${3:-debate}"
  local agent_name="${AGENT_NAMES[$((agent_idx - 1))]}"
  local other_names=""
  local idx

  for (( idx=1; idx<=AGENT_COUNT; idx++ )); do
    if [[ "$idx" -eq "$agent_idx" ]]; then
      continue
    fi
    if [[ -z "$other_names" ]]; then
      other_names="${AGENT_NAMES[$((idx - 1))]}"
    else
      other_names="${other_names}, ${AGENT_NAMES[$((idx - 1))]}"
    fi
  done

  local debate_content
  debate_content=$(cat "$DEBATE_FILE")
  local required_tag
  required_tag=$(tag_for_turn "$agent_idx" "$round")
  local before_tag_count
  before_tag_count=$(count_tag_in_text "$debate_content" "$required_tag")

  # Build prompt: guardrails (with substitutions) + debate file
  local prompt
  local agent_name_esc other_names_esc
  agent_name_esc=$(escape_for_sed "$agent_name")
  other_names_esc=$(escape_for_sed "$other_names")
  prompt=$(echo "$GUARDRAILS_TEXT" | \
    sed -e "s|{AGENT_NAME}|$agent_name_esc|g" \
        -e "s|{OTHER_AGENT}|$other_names_esc|g" \
        -e "s|{OTHER_AGENTS}|$other_names_esc|g" \
        -e "s|{ROUND}|$round|g" \
        -e "s|{MAX_ROUNDS}|$MAX_ROUNDS|g")

  # Add plan-phase instructions if in plan mode
  local phase_instruction=""
  if [[ "$phase" == "plan" ]]; then
    if [[ "$agent_idx" -eq 1 ]]; then
      phase_instruction="

---

IMPLEMENTATION PLAN PHASE: The debate has converged. Write a concrete implementation plan in the Implementation Plan section. Change PLAN_STATUS from PENDING to OPEN. Include: exact files to change, what to change (with line references), order of operations, and code snippets for non-trivial changes. Tag your edits as [$required_tag]."
    else
      phase_instruction="

---

IMPLEMENTATION PLAN PHASE: The debate has converged. Review the Implementation Plan section written by Agent 1. Apply the same guardrails: strikethrough to disagree, evidence required. Check that the plan implements what the debate agreed on. If the plan is correct and complete, mark PLAN_STATUS: CONVERGED. Tag your edits as [$required_tag]."
    fi
  fi

  prompt="$prompt
$phase_instruction
---

Below is the current state of the debate file. Edit it according to the guardrails above.
Return ONLY the updated debate file content (the full file, with your edits applied).

---

$debate_content"

  local prompt_file
  prompt_file=$(mktemp)
  printf '%s' "$prompt" > "$prompt_file"

  echo "  Invoking $agent_name (Round $round)..."
  local response
  if ! response=$(python3 - "$RUNTIME_CONFIG_FILE" "$agent_idx" "$prompt_file" <<'PY'
import json
import os
import subprocess
import sys

config_file = sys.argv[1]
agent_idx = int(sys.argv[2]) - 1
prompt_file = sys.argv[3]

with open(config_file, "r", encoding="utf-8") as f:
    cfg = json.load(f)

agents = cfg.get("agents", [])
if agent_idx < 0 or agent_idx >= len(agents):
    print(f"Error: invalid agent index {agent_idx + 1}", file=sys.stderr)
    raise SystemExit(1)

agent = agents[agent_idx]
command = agent.get("command", [])
transport = agent.get("prompt_transport", "arg")
provider = str(agent.get("provider", "")).strip().lower()

if not isinstance(command, list) or not command:
    print("Error: invalid agent command", file=sys.stderr)
    raise SystemExit(1)
if not provider and isinstance(command[0], str):
    cmd_base = os.path.basename(command[0]).lower()
    if cmd_base in ("claude", "codex", "gemini"):
        provider = cmd_base

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
        sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)

sys.stdout.write(result.stdout)
PY
  ); then
    rm -f "$prompt_file"
    echo "  Error: $agent_name failed Round $round."
    state_add_event "turn" "$round" "$agent_idx" "failed" "Agent command failed"
    state_set_status "failed" "$agent_name failed in round $round" "$round"
    return 1
  fi

  rm -f "$prompt_file"

  # Write response back to debate file
  if [[ -n "$response" ]]; then
    if ! looks_like_debate_file "$response"; then
      local raw_output_file
      raw_output_file="${DEBATE_FILE%.md}.agent${agent_idx}.round${round}.raw.txt"
      printf '%s' "$response" > "$raw_output_file"
      echo "  Error: $agent_name returned non-debate output in Round $round."
      if [[ "$response" == *"can't run nested Claude Code sessions"* ]]; then
        echo "  Hint: in host sessions, use --skip-provider <host> and have the host take its own turns directly."
      fi
      echo "  Raw output saved: $raw_output_file"
      state_add_event "turn" "$round" "$agent_idx" "failed" "Non-debate output"
      state_set_status "failed" "$agent_name returned non-debate output in round $round" "$round"
      return 1
    fi

    if [[ "$response" == "$debate_content" ]]; then
      echo "  Error: $agent_name made no file changes in Round $round."
      state_add_event "turn" "$round" "$agent_idx" "failed" "No content changes"
      state_set_status "failed" "$agent_name made no changes in round $round" "$round"
      return 1
    fi

    local after_tag_count
    after_tag_count=$(count_tag_in_text "$response" "$required_tag")
    if (( after_tag_count <= before_tag_count )); then
      echo "  Error: $agent_name response missing required turn tag $required_tag."
      state_add_event "turn" "$round" "$agent_idx" "failed" "Missing required tag $required_tag"
      state_set_status "failed" "$agent_name missing required tag $required_tag in round $round" "$round"
      return 1
    fi

    echo "$response" > "$DEBATE_FILE"
    echo "  $agent_name finished Round $round."
    state_add_event "turn" "$round" "$agent_idx" "completed" "Applied changes with tag $required_tag"
  else
    echo "  Warning: $agent_name returned empty response in Round $round."
    state_add_event "turn" "$round" "$agent_idx" "failed" "Empty response"
    state_set_status "failed" "$agent_name returned empty response in round $round" "$round"
    return 1
  fi
}

echo ""
echo "=== Agent Debate: $TOPIC ==="
echo "  Rounds: $MAX_ROUNDS | Agents: $(agent_list_text)"
if [[ -n "$CONFIG_FILE" ]]; then
  echo "  Config: $CONFIG_FILE"
fi
if [[ -n "$SKIP_PROVIDER" ]]; then
  echo "  Skip provider: $SKIP_PROVIDER (host-direct turns expected for this provider)"
fi
if [[ "$PLAN_MODE" == true ]]; then
  echo "  Plan phase: enabled (rounds: $PLAN_ROUNDS)"
else
  echo "  Plan phase: disabled (--no-plan)"
fi
echo ""

END_ROUND=$(( CURRENT_ROUND + MAX_ROUNDS - 1 ))

ACTIVE_AGENT_COUNT=0
for (( idx=1; idx<=AGENT_COUNT; idx++ )); do
  provider="${AGENT_PROVIDERS[$((idx - 1))]}"
  if [[ -n "$SKIP_PROVIDER" && "$provider" == "$SKIP_PROVIDER" ]]; then
    continue
  fi
  ACTIVE_AGENT_COUNT=$((ACTIVE_AGENT_COUNT + 1))
done
if [[ "$ACTIVE_AGENT_COUNT" -eq 0 ]]; then
  echo "Error: no runnable agents after applying --skip-provider $SKIP_PROVIDER"
  state_set_status "failed" "No runnable agents after skip-provider filter" "$CURRENT_ROUND"
  exit 1
fi

converged=false
last_completed_round=0
if [[ -n "$RESUME_FILE" && "$PLAN_MODE" == true ]]; then
  resume_last_round=$((CURRENT_ROUND - 1))
  if (( resume_last_round >= 1 )) && is_converged "$resume_last_round"; then
    converged=true
    last_completed_round="$resume_last_round"
    echo "Debate already converged at Round $resume_last_round (resume mode)."
    echo "Skipping additional debate rounds and entering plan phase."
  fi
fi

if [[ "$converged" != true ]]; then
  for (( round=CURRENT_ROUND; round<=END_ROUND; round++ )); do
    echo "--- Round $round ---"
    state_add_event "round_start" "$round" 0 "started" "Round $round started"
    round_summary="R${round}:"

    for (( idx=1; idx<=AGENT_COUNT; idx++ )); do
      provider="${AGENT_PROVIDERS[$((idx - 1))]}"
      if [[ -n "$SKIP_PROVIDER" && "$provider" == "$SKIP_PROVIDER" ]]; then
        echo "  Host-direct turn for ${AGENT_NAMES[$((idx - 1))]} (provider: $provider)."
        if ! ensure_host_turn_present "$idx" "$round"; then
          round_summary="$round_summary A${idx}⏸"
          echo "  Round paused for host action."
          echo "  $round_summary"
          state_set_status "paused_host_turn" "Missing host turn A${idx}-R${round}" "$round"
          echo ""
          echo "=== Debate paused ==="
          echo "  Output: $DEBATE_FILE"
          echo "  State:  $STATE_FILE"
          echo "  Add host turn and rerun with --resume \"$DEBATE_FILE\""
          exit 2
        fi
        round_summary="$round_summary A${idx}✅"
        continue
      fi
      if invoke_agent "$idx" "$round"; then
        round_summary="$round_summary A${idx}✅"
      else
        round_summary="$round_summary A${idx}❌"
        echo "  $round_summary"
        echo ""
        echo "=== Debate failed ==="
        echo "  Output: $DEBATE_FILE"
        echo "  State:  $STATE_FILE"
        exit 1
      fi
    done

    if ! verify_round_participation "$round"; then
      echo "  $round_summary"
      echo ""
      echo "=== Debate failed ==="
      echo "  Output: $DEBATE_FILE"
      echo "  State:  $STATE_FILE"
      exit 1
    fi

    last_completed_round="$round"
    if is_converged "$round"; then
      # All agents see the same file — if STATUS is still CONVERGED after the last agent, they agree
      echo ""
      echo "=== CONVERGED at Round $round ==="
      echo "  $round_summary"
      state_set_status "converged" "Converged at round $round" "$round"
      converged=true
      break
    fi

    echo "  $round_summary"
    state_add_event "round_end" "$round" 0 "completed" "$round_summary"
    echo ""
  done
fi

if [[ "$converged" != true ]]; then
  state_set_status "max_rounds_reached" "Reached max rounds without convergence" "$END_ROUND"
fi

# --- Implementation Plan phase ---
if [[ "$PLAN_MODE" == true && "$converged" == true ]]; then
  echo ""
  echo "=== CONVERGED — entering Implementation Plan phase ==="
  state_add_event "plan_phase_start" "$last_completed_round" 0 "started" "Entering plan phase"

  plan_converged=false
  plan_start_round=$((last_completed_round + 1))
  plan_end_round=$((plan_start_round + PLAN_ROUNDS - 1))

  for (( plan_round=plan_start_round; plan_round<=plan_end_round; plan_round++ )); do
    echo "--- Plan Round $plan_round ---"
    state_add_event "plan_round_start" "$plan_round" 0 "started" "Plan round $plan_round started"
    plan_summary="P${plan_round}:"

    for (( idx=1; idx<=AGENT_COUNT; idx++ )); do
      provider="${AGENT_PROVIDERS[$((idx - 1))]}"
      if [[ -n "$SKIP_PROVIDER" && "$provider" == "$SKIP_PROVIDER" ]]; then
        echo "  Host-direct plan turn for ${AGENT_NAMES[$((idx - 1))]} (provider: $provider)."
        if ! ensure_host_turn_present "$idx" "$plan_round"; then
          plan_summary="$plan_summary A${idx}⏸"
          echo "  Plan round paused for host action."
          echo "  $plan_summary"
          state_set_status "paused_host_plan_turn" "Missing host plan turn A${idx}-R${plan_round}" "$plan_round"
          echo ""
          echo "=== Plan phase paused ==="
          echo "  Output: $DEBATE_FILE"
          echo "  State:  $STATE_FILE"
          echo "  Add host plan turn and rerun with --resume \"$DEBATE_FILE\""
          exit 2
        fi
        plan_summary="$plan_summary A${idx}✅"
        continue
      fi
      if invoke_agent "$idx" "$plan_round" "plan"; then
        plan_summary="$plan_summary A${idx}✅"
      else
        plan_summary="$plan_summary A${idx}❌"
        echo "  $plan_summary"
        echo ""
        echo "=== Plan phase failed ==="
        echo "  Output: $DEBATE_FILE"
        echo "  State:  $STATE_FILE"
        exit 1
      fi
    done

    if is_plan_converged; then
      echo ""
      echo "=== Implementation Plan CONVERGED at Round $plan_round ==="
      echo "  $plan_summary"
      state_set_status "plan_converged" "Plan converged at round $plan_round" "$plan_round"
      plan_converged=true
      break
    fi

    echo "  $plan_summary"
    state_add_event "plan_round_end" "$plan_round" 0 "completed" "$plan_summary"
    echo ""
  done

  if [[ "$plan_converged" != true ]]; then
    state_set_status "plan_max_rounds" "Plan phase reached max rounds without convergence" "$plan_end_round"
  fi
fi

echo ""
echo "=== Debate complete ==="
echo "  Output: $DEBATE_FILE"
echo "  State:  $STATE_FILE"
echo "  Review the file and make your call."
