#!/usr/bin/env bash
# orchestrate.sh — Runs an agent debate via shared markdown file
#
# Usage:
#   ./tools/debate/orchestrate.sh --topic "question" --rounds 3
#   ./tools/debate/orchestrate.sh --resume path/to/debate.md --rounds 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBATES_DIR="$SCRIPT_DIR/debates"
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

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Start a new debate:
  --topic "question"          The debate topic (required for new debates)
  --files file1 file2 ...     Relevant source files to include as context
  --constraints "text"        Non-negotiable constraints
  --rounds N                  Max rounds per agent (default: 3)
  --agent1 name               First agent name (default: Claude)
  --agent2 name               Second agent name (default: Codex)

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
    --rounds) MAX_ROUNDS="$2"; shift 2 ;;
    --resume) RESUME_FILE="$2"; shift 2 ;;
    --agent1) AGENT_1="$2"; shift 2 ;;
    --agent2) AGENT_2="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Validate
if [[ -z "$RESUME_FILE" && -z "$TOPIC" ]]; then
  echo "Error: --topic is required for new debates (or use --resume)"
  usage
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
  CURRENT_ROUND=$(grep -c '^\| R[0-9]' "$DEBATE_FILE" 2>/dev/null || echo "0")
  CURRENT_ROUND=$(( (CURRENT_ROUND / 2) + 1 ))
else
  mkdir -p "$DEBATES_DIR"
  # Auto-increment debate number from existing files
  LAST_NUM=$(ls "$DEBATES_DIR"/*.md 2>/dev/null | sed 's|.*/||' | grep -oE '^[0-9]+' | sort -n | tail -1)
  NEXT_NUM=$(( ${LAST_NUM:-0} + 1 ))
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

  echo "Created debate file: $DEBATE_FILE"
fi

# --- Read guardrails ---
GUARDRAILS_TEXT=$(cat "$GUARDRAILS")

# --- Debate loop ---

invoke_agent() {
  local agent_name="$1"
  local other_name="$2"
  local round="$3"
  local debate_content
  debate_content=$(cat "$DEBATE_FILE")

  # Build prompt: guardrails (with substitutions) + debate file
  local prompt
  prompt=$(echo "$GUARDRAILS_TEXT" | \
    sed -e "s|{AGENT_NAME}|$agent_name|g" \
        -e "s|{OTHER_AGENT}|$other_name|g" \
        -e "s|{ROUND}|$round|g" \
        -e "s|{MAX_ROUNDS}|$MAX_ROUNDS|g")

  prompt="$prompt

---

Below is the current state of the debate file. Edit it according to the guardrails above.
Return ONLY the updated debate file content (the full file, with your edits applied).

---

$debate_content"

  local response=""

  if [[ "$agent_name" == "Claude" ]]; then
    echo "  Invoking Claude (Round $round)..."
    response=$(claude -p "$prompt" 2>/dev/null)
  elif [[ "$agent_name" == "Codex" ]]; then
    echo "  Invoking Codex (Round $round)..."
    # codex quiet mode — adjust command if CLI interface differs
    response=$(codex -q "$prompt" 2>/dev/null)
  else
    echo "  Error: Unknown agent: $agent_name"
    return 1
  fi

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
echo "  Rounds: $MAX_ROUNDS | Agent 1: $AGENT_1 | Agent 2: $AGENT_2"
echo ""

END_ROUND=$(( CURRENT_ROUND + MAX_ROUNDS - 1 ))

for (( round=CURRENT_ROUND; round<=END_ROUND; round++ )); do
  echo "--- Round $round ---"

  # Agent 1 goes first
  invoke_agent "$AGENT_1" "$AGENT_2" "$round"

  # Check for convergence
  if grep -q "STATUS: CONVERGED" "$DEBATE_FILE" 2>/dev/null; then
    echo ""
    echo "  $AGENT_1 marked CONVERGED. Checking with $AGENT_2..."
  fi

  # Agent 2 responds
  invoke_agent "$AGENT_2" "$AGENT_1" "$round"

  # Check for mutual convergence
  CONVERGED_COUNT=$(grep -c "STATUS: CONVERGED" "$DEBATE_FILE" 2>/dev/null || echo "0")
  if [[ "$CONVERGED_COUNT" -ge 1 ]]; then
    # Both agents see the same file — if STATUS is still CONVERGED after agent 2, they agree
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
