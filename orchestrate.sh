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
  --agents a,b[,c]            Agent aliases/models (e.g. opus,codex or gemini:gemini-2.5-pro,codex,sonnet)
  --config path/to/config.json  Agent configuration file (optional)
  --rounds N                  Max rounds per agent (default: 3)
  --agent1 name               Override Agent 1 display name
  --agent2 name               Override Agent 2 display name
  --agent3 name               Override Agent 3 display name

Resume an existing debate:
  --resume path/to/debate.md  Path to existing debate file
  --rounds N                  Additional rounds to run

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
    --rounds) MAX_ROUNDS="$2"; shift 2 ;;
    --resume) RESUME_FILE="$2"; shift 2 ;;
    --agent1) AGENT1_OVERRIDE_NAME="$2"; shift 2 ;;
    --agent2) AGENT2_OVERRIDE_NAME="$2"; shift 2 ;;
    --agent3) AGENT3_OVERRIDE_NAME="$2"; shift 2 ;;
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

resolve_agents() {
  RUNTIME_CONFIG_FILE=$(mktemp)

  local resolution_output
  if ! resolution_output=$(python3 - "$CONFIG_FILE" "$AGENTS_SPEC" "$RUNTIME_CONFIG_FILE" <<'PY'
import json
import sys

config_path = sys.argv[1]
agents_spec = sys.argv[2].strip()
out_path = sys.argv[3]

BUILTIN_ALIASES = {
    "opus": {
        "name": "Opus",
        "command_template": ["claude", "-p", "--model", "opus", "--effort", "{EFFORT}"],
        "reasoning": {"default": "medium", "allowed": ["low", "medium", "high"]},
        "prompt_transport": "arg",
    },
    "sonnet": {
        "name": "Sonnet",
        "command_template": ["claude", "-p", "--model", "sonnet", "--effort", "{EFFORT}"],
        "reasoning": {"default": "medium", "allowed": ["low", "medium", "high"]},
        "prompt_transport": "arg",
    },
    "codex": {
        "name": "Codex",
        "command_template": ["codex", "exec", "-c", "model_reasoning_effort=\"{EFFORT}\""],
        "reasoning": {"default": "medium", "allowed": ["low", "medium", "high"]},
        "prompt_transport": "arg",
    },
    "gemini": {
        "name": "Gemini 2.5 Pro",
        "command_template": ["gemini", "-p", "--model", "{MODEL}"],
        "default_model": "gemini-2.5-pro",
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
    if model_override and not has_model_placeholder:
        fail(f"alias '{alias}' does not support model overrides")

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

    participant_key = (alias, model_value if has_model_placeholder else "")
    unique_participants.add(participant_key)

    resolved.append(
        {
            "name": name.strip(),
            "command": cmd,
            "prompt_transport": transport,
        }
    )

if len(unique_participants) < 2:
    fail("need at least two unique participants")

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"agents": resolved}, f)

print(len(resolved))
for agent in resolved:
    print(agent["name"])
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
  local i
  for (( i=1; i<${#resolved_lines[@]}; i++ )); do
    AGENT_NAMES+=("${resolved_lines[$i]}")
  done

  if [[ "${#AGENT_NAMES[@]}" -ne "$AGENT_COUNT" ]]; then
    echo "Error: resolved agent count mismatch"
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

is_converged() {
  grep -q "STATUS: CONVERGED" "$DEBATE_FILE" && ! has_open_disputes
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

# --- Read guardrails ---
GUARDRAILS_TEXT=$(cat "$GUARDRAILS")

# --- Debate loop ---

invoke_agent() {
  local agent_idx="$1"
  local round="$2"
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

  prompt="$prompt

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

if not isinstance(command, list) or not command:
    print("Error: invalid agent command", file=sys.stderr)
    raise SystemExit(1)

with open(prompt_file, "r", encoding="utf-8") as f:
    prompt = f.read()

if transport == "stdin":
    result = subprocess.run(command, input=prompt, capture_output=True, text=True)
else:
    result = subprocess.run(command + [prompt], capture_output=True, text=True)

if result.returncode != 0:
    if result.stderr:
        sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)

sys.stdout.write(result.stdout)
PY
  ); then
    rm -f "$prompt_file"
    echo "  Error: $agent_name failed Round $round."
    return 1
  fi

  rm -f "$prompt_file"

  # Write response back to debate file
  if [[ -n "$response" ]]; then
    echo "$response" > "$DEBATE_FILE"
    echo "  $agent_name finished Round $round."
  else
    echo "  Warning: $agent_name returned empty response in Round $round."
  fi
}

echo ""
echo "=== Agent Debate: $TOPIC ==="
echo "  Rounds: $MAX_ROUNDS | Agents: $(agent_list_text)"
if [[ -n "$CONFIG_FILE" ]]; then
  echo "  Config: $CONFIG_FILE"
fi
echo ""

END_ROUND=$(( CURRENT_ROUND + MAX_ROUNDS - 1 ))

for (( round=CURRENT_ROUND; round<=END_ROUND; round++ )); do
  echo "--- Round $round ---"

  for (( idx=1; idx<=AGENT_COUNT; idx++ )); do
    invoke_agent "$idx" "$round"
  done

  if is_converged; then
    # All agents see the same file — if STATUS is still CONVERGED after the last agent, they agree
    echo ""
    echo "=== CONVERGED at Round $round ==="
    break
  fi

  echo ""
done

echo ""
echo "=== Debate complete ==="
echo "  Output: $DEBATE_FILE"
echo "  Review the file and make your call."
