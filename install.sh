#!/usr/bin/env bash
# install.sh — Install agent-debate protocol into AI agent global configs
#
# Usage:
#   ./install.sh                        # Install for all detected agents
#   ./install.sh --agent claude          # Install for Claude only
#   ./install.sh --agent codex           # Install for Codex only
#   ./install.sh --agent gemini          # Install for Gemini only
#   ./install.sh --agent copilot         # Install for Copilot only
#   ./install.sh --uninstall             # Remove from all agents
#   ./install.sh --uninstall --agent claude
#
# Via curl (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/gumbel-ai/agent-debate/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/gumbel-ai/agent-debate/main/install.sh | bash -s -- --agent claude

set -euo pipefail

# --- Constants ---

REPO_RAW="https://raw.githubusercontent.com/gumbel-ai/agent-debate/main"
SENTINEL_START="<!-- agent-debate:start -->"
SENTINEL_END="<!-- agent-debate:end -->"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}" 2>/dev/null)" 2>/dev/null && pwd 2>/dev/null || echo "")"

# --- Arg parsing ---

TARGET_AGENT="all"
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) TARGET_AGENT="$2"; shift 2 ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" 2>/dev/null || echo "Usage: install.sh [--agent claude|codex|gemini|copilot|all] [--uninstall]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

case "$TARGET_AGENT" in
  all|claude|codex|gemini|copilot) ;;
  *)
    echo "Error: --agent must be one of: claude, codex, gemini, copilot, all"
    exit 1
    ;;
esac

# --- Source detection ---
# Are we running from a cloned repo or via curl?

LOCAL_MODE=false
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/agent-guardrails.md" && -f "$SCRIPT_DIR/TEMPLATE.md" ]]; then
  LOCAL_MODE=true
fi

# --- Helper: get a file from local repo or GitHub ---

get_file() {
  local filename="$1"
  local dest="$2"
  if [[ "$LOCAL_MODE" == true ]]; then
    cp "$SCRIPT_DIR/$filename" "$dest"
  else
    curl -fsSL "$REPO_RAW/$filename" > "$dest"
  fi
}

# --- Instruction blocks ---
# Each agent gets its own version with different tone/formatting.

claude_instructions() {
  cat <<'CLAUDE_EOF'
<!-- agent-debate:start -->
## Agent Debate System

A structured multi-agent debate system where 2 to 4 AI agents review technical decisions via shared markdown files. Supports Claude, Codex, Gemini, and Copilot as participants.

### Manual Mode (you are a participant)

When user says **"continue debate N"** or **"respond to debate N"**:
1. Read `debates/N-*.md` in the current project (the debate file)
2. Read `~/.claude/agent-debate/agent-guardrails.md` (behavioral rules)
3. You are the responding agent. Edit the document in-place per the guardrails:
   - Strikethrough + counter for disagreements, not appending below
   - Tag every edit: `[A1-R2]`, `[A2-R1]`, `[A3-R1]`, `[A4-R1]` (your agent name, round number)
   - Update the Dispute Log with Status: `OPEN`, `CLOSED`, or `PARKED`
   - **Every problem and solution must include inline evidence** (log counts, file:line, actual vs expected values). No evidence = parking lot.
   - **Verify another agent's claims independently** before accepting. State what you checked and what you found.
4. No code changes unless the debate explicitly allows it

When user says **"start a debate on <topic>"**:
1. Create a new file in `./debates/` from `~/.claude/agent-debate/TEMPLATE.md`
2. Auto-number: increment from highest existing `N-` prefix in `./debates/`
3. You are Agent 1. Write the initial proposal
4. If fewer than 4 agents, remove unused `**Agent 3:**` / `**Agent 4:**` lines from the file

When user says **"implement debate N"**, **"apply plan for debate N"**, or **"implement it now"**:
1. Resolve the target debate file:
   - If `N` is provided: use `debates/N-*.md`
   - If user says "implement it now": pick the latest converged debate in `./debates/` (if ambiguous, ask which debate)
2. Verify readiness before coding:
   - Proposal must be converged (`STATUS: CONVERGED`)
   - Dispute Log must have no `OPEN` rows
   - If `## Plan` exists, require `PLAN_STATUS: CONVERGED`
3. If plan exists but is not converged, run plan phase first:
   - `./orchestrate.sh --resume "<debate-file>" --plan`
4. Implement the converged plan/proposal in code now.
5. After implementation, append an `## Implementation Results` section (or update it) in the debate file with:
   - Files changed
   - Commands/tests run
   - Any deviations from the plan

### Loop Mode

When user says **"loop mode on"** or **"start loop mode"**:
1. Run `./loop.sh start --task "<one-line task statement>"` if `./loop.sh` exists, else `~/.agent-debate/loop.sh start --task "..."`. Always pass `--task` so the reviewer knows the goal.
2. If the user names a reviewer model, add `--reviewer <alias>` (aliases: opus, sonnet, codex, gemini — not copilot). Default when unspecified: Codex reviews Claude; Opus reviews Codex.
3. Tell the user: "Loop mode on. <reviewer> will review asynchronously every 60s."
4. If hooks were just installed, they may need a session restart or `/hooks` review before they enforce.

When user says **"loop mode off"**, **"stop loop mode"**, **"switch off loop mode"**, or **"shut down loop mode"**:
1. Run `./loop.sh stop` if `./loop.sh` exists, else `~/.agent-debate/loop.sh stop`

While loop mode is active (works both ways — Claude codes with Codex reviewing, or Codex codes with Claude reviewing):
- User prompts are journaled automatically via a UserPromptSubmit hook and auto-distilled into the task statement each reviewer pass; you can still set it explicitly with `task "..."` when the goal changes
- Hooks gate todo/task completion: run `intent "<what + why + expected validation>"` before marking work complete; the gate also blocks until a task statement exists
- When reviewer feedback exists, run `check` to read it, then `feedback accept|deny|park "reason"` to disposition it; Claude also gates `git commit`
- After meaningful milestones, run `log "<one-line summary>"`
- One-shot gate escape: `bypass "reason"`
- The loop auto-stops after 2 hours without activity (journal writes or repo changes)

### Auto Mode (orchestrator-assisted)

When user says **"auto debate"** or asks for an automated multi-agent debate:
1. Run the orchestrator: `~/.agent-debate/orchestrate.sh` (or the repo copy if available)
2. Example: `./orchestrate.sh --topic "question" --agents opus,codex --rounds 3`
3. For 3 or 4 agents: `./orchestrate.sh --topic "question" --agents opus,codex,gemini,copilot --rounds 2`
4. The orchestrator handles round-robin invocation, guardrail injection, and convergence detection for agents it invokes.
5. If your own provider is in the lineup, run host-direct rounds: write your turn directly, then run orchestrator for the other providers with `--skip-provider` for your host (Claude example: `--skip-provider claude`).

### Key Files
- `~/.claude/agent-debate/agent-guardrails.md` — Rules for all agents (read first)
- `~/.claude/agent-debate/TEMPLATE.md` — Template for new debates
- `~/.agent-debate/config.json` — Agent aliases and defaults
- `~/.agent-debate/loop.sh` — Loop mode entrypoint
- `./debates/` — Project-local debate files, numbered `1-`, `2-`, etc.
<!-- agent-debate:end -->
CLAUDE_EOF
}

codex_instructions() {
  cat <<'CODEX_EOF'
<!-- agent-debate:start -->
## Agent Debate System

Multi-agent technical debate (2 to 4 agents) via shared markdown files. Supports Claude, Codex, Gemini, and Copilot as participants.

### Manual Mode (you are a participant)

When user says "continue debate N" or "respond to debate N":
1. Read the debate file at `debates/N-*.md` in the current project.
2. Read the guardrails at `~/.codex/agent-debate/agent-guardrails.md`.
3. You are the responding agent. Follow the guardrails exactly:
   - Edit the document in-place (strikethrough + counter, not append).
   - Tag every edit with your agent name and round: `[A2-R1]`, `[A3-R1]`, `[A4-R1]`.
   - Update the Dispute Log table with a Status per row (`OPEN`, `CLOSED`, `PARKED`).
   - **Every problem and solution must include inline evidence** (log counts, file:line, actual vs expected values). No evidence = parking lot.
   - **Verify another agent's claims independently** before accepting. State what you checked and what you found. Do not take claims at face value.
4. Do NOT make code changes unless the debate file explicitly allows it or the user asks to implement a converged debate plan.

### When user says "start a debate on <topic>":
1. Create a new debate file in `./debates/` using the template at `~/.codex/agent-debate/TEMPLATE.md`.
2. Auto-number: find the highest `N-` prefix in existing files and increment.
3. You are Agent 1. Write the initial proposal in the Proposal section.
4. If fewer than 4 agents, remove unused `**Agent 3:**` / `**Agent 4:**` lines from the file.

### When user says "implement debate N", "apply plan for debate N", or "implement it now":
1. Resolve target debate file:
   - If `N` is provided: use `debates/N-*.md`.
   - If user says "implement it now": pick the latest converged debate in `./debates/` (if ambiguous, ask which debate).
2. Verify readiness before coding:
   - Proposal must be converged (`STATUS: CONVERGED`).
   - Dispute Log must have no `OPEN` rows.
   - If `## Plan` exists, require `PLAN_STATUS: CONVERGED`.
3. If plan exists but is not converged, run plan phase first:
   - `./orchestrate.sh --resume "<debate-file>" --plan`
4. Implement the converged plan/proposal in code now.
5. After implementation, append an `## Implementation Results` section (or update it) in the debate file with:
   - Files changed
   - Commands/tests run
   - Any deviations from the plan

### Loop Mode

When user says "loop mode on" or "start loop mode":
1. Run `./loop.sh start --task "<one-line task statement>"` if `./loop.sh` exists, else `~/.agent-debate/loop.sh start --task "..."`. Always pass `--task` so the reviewer knows the goal.
2. If the user names a reviewer model, add `--reviewer <alias>` (aliases: opus, sonnet, codex, gemini — not copilot). Default when unspecified: Opus reviews Codex; Codex reviews Claude.
3. If Codex asks to review/trust the project hooks, use `/hooks` to trust the loop-mode hooks.
4. Tell the user: "Loop mode on. <reviewer> will review asynchronously every 60s."

When user says "loop mode off", "stop loop mode", "switch off loop mode", or "shut down loop mode":
1. Run `./loop.sh stop` if `./loop.sh` exists, else `~/.agent-debate/loop.sh stop`.

While loop mode is active (works both ways — Codex codes with Claude reviewing, or Claude codes with Codex reviewing):
- User prompts are journaled automatically via a UserPromptSubmit hook and auto-distilled into the task statement each reviewer pass; you can still set it explicitly with `task "..."` when the goal changes.
- Hooks gate plan-item completion: run `intent "<what + why + expected validation>"` before marking work complete; the gate also blocks until a task statement exists.
- When reviewer feedback exists, run `check` to read it, then `feedback accept|deny|park "reason"` to disposition it.
- After meaningful milestones, run `log "<one-line summary>"`.
- One-shot gate escape: `bypass "reason"`.
- The loop auto-stops after 2 hours without activity (journal writes or repo changes).

### Auto Mode (orchestrator-assisted)

When user says "auto debate" or asks for an automated multi-agent debate:
1. Run: `~/.agent-debate/orchestrate.sh --topic "question" --agents opus,codex --rounds 3`
2. For 3 or 4 agents: `--agents opus,codex,gemini,copilot`
3. The orchestrator handles round-robin invocation, guardrail injection, and convergence detection for agents it invokes.
4. If your own provider is in the lineup, run host-direct rounds: write your turn directly, then run orchestrator for the other providers with `--skip-provider` for your host (Codex example: `--skip-provider codex`).

### Key files:
- `~/.codex/agent-debate/agent-guardrails.md` — Behavioral rules for all agents (read this first)
- `~/.codex/agent-debate/TEMPLATE.md` — Starting template for new debates
- `~/.agent-debate/config.json` — Agent aliases and defaults
- `~/.agent-debate/loop.sh` — Loop mode entrypoint
- `./debates/` — All debate files, numbered `1-`, `2-`, etc.
<!-- agent-debate:end -->
CODEX_EOF
}

gemini_instructions() {
  cat <<'GEMINI_EOF'
<!-- agent-debate:start -->
## Agent Debate System

Multi-agent technical debate (2 to 4 agents) via shared markdown files. Supports Claude, Codex, Gemini, and Copilot as participants.

### Manual Mode (you are a participant)

When user says "continue debate N" or "respond to debate N":
1. Read the debate file at `debates/N-*.md` in the current project.
2. Read the guardrails at `~/.gemini/agent-debate/agent-guardrails.md`.
3. You are the responding agent. Follow the guardrails exactly:
   - Edit the document in-place (strikethrough + counter, not append).
   - Tag every edit with your agent name and round: `[A2-R1]`, `[A3-R1]`, `[A4-R1]`.
   - Update the Dispute Log table with a Status per row (`OPEN`, `CLOSED`, `PARKED`).
   - **Every problem and solution must include inline evidence** (log counts, file:line, actual vs expected values). No evidence = parking lot.
   - **Verify another agent's claims independently** before accepting. State what you checked and what you found. Do not take claims at face value.
4. Do NOT make code changes unless the debate file explicitly allows it or the user asks to implement a converged debate plan.

### When user says "start a debate on <topic>":
1. Create a new debate file in `./debates/` using the template at `~/.gemini/agent-debate/TEMPLATE.md`.
2. Auto-number: find the highest `N-` prefix in existing files and increment.
3. You are Agent 1. Write the initial proposal in the Proposal section.
4. If fewer than 4 agents, remove unused `**Agent 3:**` / `**Agent 4:**` lines from the file.

### When user says "implement debate N", "apply plan for debate N", or "implement it now":
1. Resolve target debate file:
   - If `N` is provided: use `debates/N-*.md`.
   - If user says "implement it now": pick the latest converged debate in `./debates/` (if ambiguous, ask which debate).
2. Verify readiness before coding:
   - Proposal must be converged (`STATUS: CONVERGED`).
   - Dispute Log must have no `OPEN` rows.
   - If `## Plan` exists, require `PLAN_STATUS: CONVERGED`.
3. If plan exists but is not converged, run plan phase first:
   - `./orchestrate.sh --resume "<debate-file>" --plan`
4. Implement the converged plan/proposal in code now.
5. After implementation, append an `## Implementation Results` section (or update it) in the debate file with:
   - Files changed
   - Commands/tests run
   - Any deviations from the plan

### Loop Mode

When user says "loop mode on" or "start loop mode":
1. Explain that loop mode is currently supported from Claude Code or Codex hosts only.
2. Do not run `loop.sh start` from Gemini.

When user says "loop mode off", "stop loop mode", "switch off loop mode", or "shut down loop mode":
1. Run `./loop.sh stop` if `./loop.sh` exists, else `~/.agent-debate/loop.sh stop`.

While loop mode is active:
- Loop mode is supported for Claude Code and Codex hosts. Gemini should use debate mode unless loop support is added.

### Auto Mode (orchestrator-assisted)

When user says "auto debate" or asks for an automated multi-agent debate:
1. Run: `~/.agent-debate/orchestrate.sh --topic "question" --agents opus,codex --rounds 3`
2. For 3 or 4 agents: `--agents opus,codex,gemini,copilot`
3. The orchestrator handles round-robin invocation, guardrail injection, and convergence detection for agents it invokes.
4. If your own provider is in the lineup, run host-direct rounds: write your turn directly, then run orchestrator for the other providers with `--skip-provider` for your host (Gemini example: `--skip-provider gemini`).

### Key files:
- `~/.gemini/agent-debate/agent-guardrails.md` — Behavioral rules for all agents (read this first)
- `~/.gemini/agent-debate/TEMPLATE.md` — Starting template for new debates
- `~/.agent-debate/config.json` — Agent aliases and defaults
- `~/.agent-debate/loop.sh` — Loop mode entrypoint
- `./debates/` — All debate files, numbered `1-`, `2-`, etc.
<!-- agent-debate:end -->
GEMINI_EOF
}

copilot_instructions() {
  cat <<'COPILOT_EOF'
<!-- agent-debate:start -->
## Agent Debate System

Multi-agent technical debate (2 to 4 agents) via shared markdown files. Supports Claude, Codex, Gemini, and Copilot as participants.

### Manual Mode (you are a participant)

When user says "continue debate N" or "respond to debate N":
1. Read the debate file at `debates/N-*.md` in the current project.
2. Read the guardrails at `~/.copilot/agent-debate/agent-guardrails.md`.
3. You are the responding agent. Follow the guardrails exactly:
   - Edit the document in-place (strikethrough + counter, not append).
   - Tag every edit with your agent name and round: `[A2-R1]`, `[A3-R1]`, `[A4-R1]`.
   - Update the Dispute Log table with a Status per row (`OPEN`, `CLOSED`, `PARKED`).
   - **Every problem and solution must include inline evidence** (log counts, file:line, actual vs expected values). No evidence = parking lot.
   - **Verify another agent's claims independently** before accepting. State what you checked and what you found. Do not take claims at face value.
4. Do NOT make code changes unless the debate file explicitly allows it or the user asks to implement a converged debate plan.

### When user says "start a debate on <topic>":
1. Create a new debate file in `./debates/` using the template at `~/.copilot/agent-debate/TEMPLATE.md`.
2. Auto-number: find the highest `N-` prefix in existing files and increment.
3. You are Agent 1. Write the initial proposal in the Proposal section.
4. If fewer than 4 agents, remove unused `**Agent 3:**` / `**Agent 4:**` lines from the file.

### When user says "implement debate N", "apply plan for debate N", or "implement it now":
1. Resolve target debate file:
   - If `N` is provided: use `debates/N-*.md`.
   - If user says "implement it now": pick the latest converged debate in `./debates/` (if ambiguous, ask which debate).
2. Verify readiness before coding:
   - Proposal must be converged (`STATUS: CONVERGED`).
   - Dispute Log must have no `OPEN` rows.
   - If `## Plan` exists, require `PLAN_STATUS: CONVERGED`.
3. If plan exists but is not converged, run plan phase first:
   - `./orchestrate.sh --resume "<debate-file>" --plan`
4. Implement the converged plan/proposal in code now.
5. After implementation, append an `## Implementation Results` section (or update it) in the debate file with:
   - Files changed
   - Commands/tests run
   - Any deviations from the plan

### Loop Mode

When user says "loop mode on" or "start loop mode":
1. Explain that loop mode is currently supported from Claude Code or Codex hosts only.
2. Do not run `loop.sh start` from Copilot.

When user says "loop mode off", "stop loop mode", "switch off loop mode", or "shut down loop mode":
1. Run `./loop.sh stop` if `./loop.sh` exists, else `~/.agent-debate/loop.sh stop`.

While loop mode is active:
- Loop mode is supported for Claude Code and Codex hosts. Copilot should use debate mode unless loop support is added.

### Auto Mode (orchestrator-assisted)

When user says "auto debate" or asks for an automated multi-agent debate:
1. Run: `~/.agent-debate/orchestrate.sh --topic "question" --agents opus,codex --rounds 3`
2. For 3 or 4 agents: `--agents opus,codex,gemini,copilot`
3. The orchestrator handles round-robin invocation, guardrail injection, and convergence detection for agents it invokes.
4. If your own provider is in the lineup, run host-direct rounds: write your turn directly, then run orchestrator for the other providers with `--skip-provider` for your host (Copilot example: `--skip-provider copilot`).

### Key files:
- `~/.copilot/agent-debate/agent-guardrails.md` — Behavioral rules for all agents (read this first)
- `~/.copilot/agent-debate/TEMPLATE.md` — Starting template for new debates
- `~/.agent-debate/config.json` — Agent aliases and defaults
- `~/.agent-debate/loop.sh` — Loop mode entrypoint
- `./debates/` — All debate files, numbered `1-`, `2-`, etc.
<!-- agent-debate:end -->
COPILOT_EOF
}

# --- Install for one agent ---

install_agent() {
  local agent_name="$1"    # "Claude" or "Codex"
  local config_dir="$2"    # ~/.claude or ~/.codex
  local config_file="$3"   # CLAUDE.md or AGENTS.md
  local instructions="$4"  # output of claude_instructions or codex_instructions

  local config_path="$config_dir/$config_file"
  local debate_dir="$config_dir/agent-debate"

  # Create directories
  mkdir -p "$debate_dir"

  # Copy protocol files
  get_file "agent-guardrails.md" "$debate_dir/agent-guardrails.md"
  get_file "TEMPLATE.md" "$debate_dir/TEMPLATE.md"

  # Append or replace instructions in config file
  if [[ -f "$config_path" ]]; then
    if grep -q "$SENTINEL_START" "$config_path" 2>/dev/null; then
      # Upgrade: strip old block (and trailing blank lines), then append new
      local tmp
      tmp=$(mktemp)
      awk -v start="$SENTINEL_START" -v end="$SENTINEL_END" '
        $0 == start { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
      ' "$config_path" | awk 'NF { for (i = 0; i < blank; i++) print ""; blank = 0; print; next } { blank++ }' > "$tmp"
      mv "$tmp" "$config_path"
      printf "\n%s\n" "$instructions" >> "$config_path"
      echo "  $config_path (updated)"
    else
      # Append
      printf "\n\n%s\n" "$instructions" >> "$config_path"
      echo "  $config_path (appended)"
    fi
  else
    # Create new
    echo "$instructions" > "$config_path"
    echo "  $config_path (created)"
  fi

  echo "  $debate_dir/ (2 files)"
}

# --- Uninstall for one agent ---

uninstall_agent() {
  local agent_name="$1"
  local config_dir="$2"
  local config_file="$3"

  local config_path="$config_dir/$config_file"
  local debate_dir="$config_dir/agent-debate"
  local changed=false

  # Remove instruction block from config file
  if [[ -f "$config_path" ]] && grep -q "$SENTINEL_START" "$config_path" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    awk -v start="$SENTINEL_START" -v end="$SENTINEL_END" '
      $0 == start { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$config_path" | awk 'NF { for (i = 0; i < blank; i++) print ""; blank = 0; print; next } { blank++ }' > "$tmp"
    mv "$tmp" "$config_path"
    echo "  $config_path (block removed)"
    changed=true
  fi

  # Remove protocol files
  if [[ -d "$debate_dir" ]]; then
    rm -rf "$debate_dir"
    echo "  $debate_dir/ (removed)"
    changed=true
  fi

  if [[ "$changed" == false ]]; then
    echo "  $agent_name: nothing to remove"
  fi
}

install_shared_config() {
  local shared_dir="$HOME/.agent-debate"
  mkdir -p "$shared_dir"
  mkdir -p "$shared_dir/hooks"
  get_file "debate.config.json" "$shared_dir/config.json"
  get_file "agent-guardrails.md" "$shared_dir/agent-guardrails.md"
  get_file "TEMPLATE.md" "$shared_dir/TEMPLATE.md"
  get_file "orchestrate.sh" "$shared_dir/orchestrate.sh"
  get_file "agent_response_parser.py" "$shared_dir/agent_response_parser.py"
  get_file "debate_lib.py" "$shared_dir/debate_lib.py"
  get_file "loop.sh" "$shared_dir/loop.sh"
  get_file "hooks/loop-stop.sh" "$shared_dir/hooks/loop-stop.sh"
  get_file "hooks/loop-git-check.sh" "$shared_dir/hooks/loop-git-check.sh"
  get_file "hooks/loop-task-check.sh" "$shared_dir/hooks/loop-task-check.sh"
  get_file "hooks/loop-prompt-log.sh" "$shared_dir/hooks/loop-prompt-log.sh"
  chmod +x "$shared_dir/orchestrate.sh"
  chmod +x "$shared_dir/agent_response_parser.py"
  chmod +x "$shared_dir/loop.sh"
  chmod +x "$shared_dir/hooks/loop-stop.sh"
  chmod +x "$shared_dir/hooks/loop-git-check.sh"
  chmod +x "$shared_dir/hooks/loop-task-check.sh"
  chmod +x "$shared_dir/hooks/loop-prompt-log.sh"
  echo "  $shared_dir/config.json (default config)"
  echo "  $shared_dir/agent-guardrails.md (auto mode rules)"
  echo "  $shared_dir/TEMPLATE.md (auto mode template)"
  echo "  $shared_dir/orchestrate.sh (auto mode)"
  echo "  $shared_dir/agent_response_parser.py (agent output parser)"
  echo "  $shared_dir/debate_lib.py (debate-file helpers)"
  echo "  $shared_dir/loop.sh (loop mode)"
  echo "  $shared_dir/hooks/ (loop mode hooks)"
}

uninstall_shared_config() {
  local shared_dir="$HOME/.agent-debate"
  if [[ -d "$shared_dir" ]]; then
    rm -rf "$shared_dir"
    echo "Shared config:"
    echo "  $shared_dir/ (removed)"
  fi
}

agent_has_block() {
  local config_path="$1"
  [[ -f "$config_path" ]] && grep -q "$SENTINEL_START" "$config_path" 2>/dev/null
}

any_agent_blocks_installed() {
  agent_has_block "$HOME/.claude/CLAUDE.md" \
    || agent_has_block "$HOME/.codex/AGENTS.md" \
    || agent_has_block "$HOME/.gemini/GEMINI.md" \
    || agent_has_block "$HOME/.copilot/AGENTS.md"
}

# --- Main ---

echo ""

if [[ "$UNINSTALL" == true ]]; then
  echo "Uninstalling agent-debate..."
  echo ""

  if [[ "$TARGET_AGENT" == "all" || "$TARGET_AGENT" == "claude" ]]; then
    echo "Claude:"
    uninstall_agent "Claude" "$HOME/.claude" "CLAUDE.md"
  fi

  if [[ "$TARGET_AGENT" == "all" || "$TARGET_AGENT" == "codex" ]]; then
    echo "Codex:"
    uninstall_agent "Codex" "$HOME/.codex" "AGENTS.md"
  fi

  if [[ "$TARGET_AGENT" == "all" || "$TARGET_AGENT" == "gemini" ]]; then
    echo "Gemini:"
    uninstall_agent "Gemini" "$HOME/.gemini" "GEMINI.md"
  fi

  if [[ "$TARGET_AGENT" == "all" || "$TARGET_AGENT" == "copilot" ]]; then
    echo "Copilot:"
    uninstall_agent "Copilot" "$HOME/.copilot" "AGENTS.md"
  fi

  if [[ "$TARGET_AGENT" == "all" ]]; then
    uninstall_shared_config
  else
    if any_agent_blocks_installed; then
      echo "Shared config:"
      echo "  $HOME/.agent-debate/ (kept; other agents still installed)"
    else
      uninstall_shared_config
    fi
  fi

  echo ""
  echo "Done."
else
  echo "Installing agent-debate..."
  if [[ "$LOCAL_MODE" == true ]]; then
    echo "  Source: local repo ($SCRIPT_DIR)"
  else
    echo "  Source: GitHub ($REPO_RAW)"
  fi
  echo ""

  installed=""

  if [[ "$TARGET_AGENT" == "all" || "$TARGET_AGENT" == "claude" ]]; then
    echo "Claude:"
    install_agent "Claude" "$HOME/.claude" "CLAUDE.md" "$(claude_instructions)"
    installed="${installed}Claude, "
  fi

  if [[ "$TARGET_AGENT" == "all" || "$TARGET_AGENT" == "codex" ]]; then
    echo "Codex:"
    install_agent "Codex" "$HOME/.codex" "AGENTS.md" "$(codex_instructions)"
    installed="${installed}Codex, "
  fi

  if [[ "$TARGET_AGENT" == "all" || "$TARGET_AGENT" == "gemini" ]]; then
    echo "Gemini:"
    install_agent "Gemini" "$HOME/.gemini" "GEMINI.md" "$(gemini_instructions)"
    installed="${installed}Gemini, "
  fi

  if [[ "$TARGET_AGENT" == "all" || "$TARGET_AGENT" == "copilot" ]]; then
    echo "Copilot:"
    install_agent "Copilot" "$HOME/.copilot" "AGENTS.md" "$(copilot_instructions)"
    installed="${installed}Copilot, "
  fi

  echo "Shared config:"
  install_shared_config

  installed="${installed%, }"

  echo ""
  echo "agent-debate installed for: $installed"
  echo ""
  echo "Usage: open any project and say \"start a debate on <topic>\""
  echo "Debates will be created in ./debates/ within the current project."
fi

echo ""
