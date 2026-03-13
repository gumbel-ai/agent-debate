# Debate: How should we add direct support for Qwen models from Alibaba (without OpenRouter) as a debate participant in agent-debate?

**Created:** 2026-03-11
**Agent 1:** Opus
**Agent 2:** Codex
**Agent 3:** Copilot
**Max Rounds:** 5
**Status:** CONVERGED

## Context

How should we add direct support for Qwen models from Alibaba (without OpenRouter) as a debate participant in agent-debate?

### Evidence

**Qwen Code CLI exists and is viable:**
- Binary name: `qwen` (https://github.com/QwenLM/qwen-code)
- Non-interactive mode: `qwen -p` — documented as "ideal for scripts, automation, and CI/CD"
- Auth methods: (1) Qwen OAuth — 1,000 free requests/day, browser login, cached credentials; (2) API-KEY via `DASHSCOPE_API_KEY` env var or `~/.qwen/settings.json`
- OAuth limitation: Cannot work in headless environments (CI, SSH, containers) — requires browser
- Config file: `~/.qwen/settings.json` with `modelProviders`, `env`, `security.auth.selectedType`, `model.name`

**DashScope API (alternative — direct HTTP, no CLI):**
- OpenAI-compatible endpoint: `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` (Singapore)
- Models: `qwen3-max`, `qwen3.5-plus`, `qwen-plus`, `qwen-flash`, `qwen3-coder`
- Pricing: Qwen-Plus at $0.40/M input, $1.20/M output tokens
- Free tier: limited, Singapore region only
- Auth: `DASHSCOPE_API_KEY` header

**Current provider architecture** (`orchestrate.sh:336-339`, `orchestrate.sh:972-975`):
- Provider auto-detection from binary basename: `if cmd_base in ("claude", "codex", "gemini", "copilot"): provider = cmd_base`
- Provider-specific env cleanup: `orchestrate.sh:981-990` — claude, codex, gemini each clear session env vars
- Provider-specific output parsing: copilot has JSON extraction at `orchestrate.sh:1004-1050`
- Builtin aliases defined in Python BUILTIN_ALIASES dict

**Current alias pattern** (`debate.config.json`):
```json
"copilot": {
  "name": "Copilot",
  "provider": "copilot",
  "command_template": ["copilot", "-s", "--yolo", "--no-ask-user", "--model", "gpt-5-mini", "--output-format", "json", "-p"],
  "prompt_transport": "arg"
}
```

### Relevant Files
- `orchestrate.sh` — orchestrator, provider maps at lines 336-339, 972-975, env cleanup 981-990
- `debate.config.json` — alias definitions
- `install.sh` — agent-specific install blocks
- `README.md` — documentation

### Constraints
- No OpenRouter — direct Alibaba access only
- Must follow existing provider pattern (alias → command_template → provider wiring)
- Qwen Code CLI (`qwen -p`) is the preferred integration path (consistent with how we integrate claude, codex, gemini, copilot)

---

## Proposal

STATUS: CONVERGED

### 1. Integration approach: Qwen Code CLI (`qwen -p`) [A1-R1]

Use the `qwen` CLI binary, same pattern as all other providers. The Qwen Code CLI already supports `-p` for non-interactive mode, making it directly compatible with our `prompt_transport: "arg"` pattern.

**Why not raw DashScope API?** Every other provider uses its native CLI (claude, codex, gemini, copilot). Adding a curl+python HTTP wrapper would be a different integration pattern and add maintenance burden. The `qwen` CLI handles auth, model selection, and output formatting.

### 2. Alias definition [A1-R1] [A3-R1]

Add to `debate.config.json` and BUILTIN_ALIASES.

Evidence: current `debate.config.json` aliases (excerpt):
```json
21.     "codex": { ... },
30.     "gemini": { "name": "Gemini (Auto)", "command_template": ["gemini", "-p"], "prompt_transport": "arg" },
35.     "copilot": { ... }
```
(Full file: `debate.config.json:1-47`)

Proposed minimal alias (add this object under `aliases` in `debate.config.json`) — minimal, no effort placeholders for v1: [A3-R1]
```json
"qwen": {
  "name": "Qwen",
  "provider": "qwen",
  "command_template": ["qwen", "-p"],
  "prompt_transport": "arg"
}
```
Rationale: This follows existing alias shape (see `gemini`, `copilot`) and defers model selection to `~/.qwen/settings.json`.

### 3. Provider wiring in orchestrate.sh [A1-R1] [A3-R1]

Minimal modifications to match existing patterns. Verified evidence from `orchestrate.sh`:

- Auto-detection in resolver (current lines) — `orchestrate.sh:336-339`:
```python
336.     if not provider and cmd:
337.         cmd_base = os.path.basename(cmd[0]).lower()
338.         if cmd_base in ("claude", "codex", "gemini", "copilot"):
339.             provider = cmd_base
```
- Auto-detection in executor (current lines) — `orchestrate.sh:972-975`:
```python
972. if not provider and isinstance(command[0], str):
973.     cmd_base = os.path.basename(command[0]).lower()
974.     if cmd_base in ("claude", "codex", "gemini", "copilot"):
975.         provider = cmd_base
```

a) Auto-detection change [A3-R1]
- Replace both tuples to include `"qwen"`:
```python
if cmd_base in ("claude", "codex", "gemini", "copilot", "qwen"):
    provider = cmd_base
```
Files/lines to change:
- `orchestrate.sh` — modify resolver block at ~`336-339`
- `orchestrate.sh` — modify executor block at ~`972-975`

This is minimal and mirrors existing provider detection.

b) Env cleanup [A3-R1]
- Current per-provider env cleanup in executor (`orchestrate.sh:980-991`) clears session vars for `claude`, `codex`, and `gemini`; there is no evidence of stable `QWEN_*` session envs in repository. Excerpt:
```python
980. env = os.environ.copy()
981. if provider == "claude":
982.     env.pop("CLAUDECODE", None)
983.     for key in list(env.keys()):
984.         if key.startswith("CLAUDE_CODE_"):
985.             env.pop(key, None)
986. elif provider == "codex":
987.     env.pop("CODEX_THREAD_ID", None)
988. elif provider == "gemini":
989.     env.pop("GEMINI_SESSION_ID", None)
990.     env.pop("GEMINI_CLI_SESSION", None)
```
- Decision: DO NOT add qwen env cleanup in v1. Add later if testing shows persistent session vars that interfere. This follows Simplicity & Brittleness (minimum viable fix).

c) Output parsing [A3-R1]
- Copilot has special JSON extraction (`orchestrate.sh:1004-1050`). Qwen `qwen -p` outputs plain text to stdout by default — no special parsing needed. Keep generic logic (send prompt as arg, read stdout). If testing finds wrappers/noise, add a thin sanitization step later.

d) Host-provider skip support — ACCEPT Codex's expanded recommendation [A3-R1]
- Usage string evidence (current `orchestrate.sh:48-60`):
```text
58.   --skip-provider name        Skip invoking one provider (claude|codex|gemini|copilot) in this run; required when host provider is in lineup
59.                              For Copilot host sessions, set AGENT_DEBATE_HOST_PROVIDER=copilot
```
- Host detection evidence (`orchestrate.sh:127-138`):
```bash
127. detect_host_provider() {
128.   if [[ -n "${AGENT_DEBATE_HOST_PROVIDER:-}" ]]; then
129.     HOST_PROVIDER="$(printf '%s' "$AGENT_DEBATE_HOST_PROVIDER" | tr '[:upper:]' '[:lower:]')"
130.     return
131.   fi
132. 
133.   if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
134.     HOST_PROVIDER="codex"
135.   elif [[ -n "${CLAUDE_CODE_SSE_PORT:-}" || -n "${CLAUDECODE:-}" ]]; then
136.     HOST_PROVIDER="claude"
137.   elif [[ -n "${GEMINI_CLI_SESSION:-}" || -n "${GEMINI_SESSION_ID:-}" ]]; then
138.     HOST_PROVIDER="gemini"
139.   else
140.     HOST_PROVIDER=""
141.   fi
142. }
```
- Action: Update help text `--skip-provider` to include `qwen`, and add `qwen` to the host-provider guard tuple used in `resolve_agents()` (current guard: `if host_provider in ("claude", "codex", "gemini", "copilot"):` at `orchestrate.sh:358`). Proposed minimal change:
  - `orchestrate.sh:58` help: mention `(claude|codex|gemini|copilot|qwen)`
  - `orchestrate.sh:358` guard: `if host_provider in ("claude", "codex", "gemini", "copilot", "qwen"):`
- Rationale: This documents and prevents accidental host-direct collisions. Per Codex's point, prefer manual `AGENT_DEBATE_HOST_PROVIDER=qwen` + `--skip-provider qwen` until we observe stable session env vars for Qwen (no auto-detect added beyond detection by binary basename).

### 4. Provider instruction [A1-R1] [A3-R1]

No qwen-specific output contract for v1. The generic output instruction at `orchestrate.sh:932-935` applies to all providers. Only add a provider-specific block if `qwen -p` produces non-clean output in testing.

Evidence: the orchestrator injects the same guardrail prompt for all providers (see `orchestrate.sh:927-935`).

### 5. Install support [A1-R1] [A3-R1]

Defer `--agent qwen` install target for v1. Evidence in `install.sh` usage and validation (excerpt):
```bash
5. #   ./install.sh                        # Install for all detected agents
6. #   ./install.sh --agent claude          # Install for Claude only
7. #   ./install.sh --agent codex           # Install for Codex only
8. #   ./install.sh --agent gemini          # Install for Gemini only
9. #   ./install.sh --agent copilot         # Install for Copilot only
...
43. case "$TARGET_AGENT" in
44.   all|claude|codex|gemini|copilot) ;;
45.   *)
46.     echo "Error: --agent must be one of: claude, codex, gemini, copilot, all"
47.     exit 1
48.     ;;
49. esac
```
No qwen-specific installer exists. Defer until a stable host-side instruction path or `~/.qwen/` convention is confirmed.

### 6. README updates [A1-R1] [A3-R1]

- Add Qwen to the participant list and alias table.
Evidence: README currently lists "Claude, Codex, Gemini, Copilot" and shows alias table rows (README:85-94). Proposed README edits:
  - Update intro to include "Qwen" in the list.
  - Add `qwen` row to alias table (name: Qwen, Effort support: —).
  - Add Known Limitation note: "Qwen OAuth requires browser login; for headless/CI, configure `DASHSCOPE_API_KEY` in `~/.qwen/settings.json`".
  - Document manual host usage: `AGENT_DEBATE_HOST_PROVIDER=qwen` + `--skip-provider qwen` (evidence: detect_host_provider supports manual override via `AGENT_DEBATE_HOST_PROVIDER`).

### 7. Auth guidance [A1-R1]

For local use: Qwen OAuth — run `qwen`, type `/auth`, browser login, done. 1,000 free requests/day.

For headless: Set `DASHSCOPE_API_KEY` env var or configure in `~/.qwen/settings.json`.

Document both paths in README Known Limitations.

### 8. Scope — what we are NOT doing [A1-R1]

- NOT adding model/effort override support. Users configure model in `~/.qwen/settings.json`.
- NOT adding DashScope HTTP fallback. CLI-only for v1.
- NOT adding Qwen-specific output parsing unless testing shows it's needed.
- NOT adding `--agent qwen` install target until host instruction path is confirmed.

### 9. Independent verification of A1 implementation targets [A3-R1]

Verified by reading repo files:

- `orchestrate.sh` auto-detection locations confirmed:
  - Resolver: `orchestrate.sh:336-339` (missing `qwen`)
  - Executor: `orchestrate.sh:972-975` (missing `qwen`)
  - Evidence pasted above.
- `orchestrate.sh` builtin aliases exist in the embedded Python dict `BUILTIN_ALIASES` but currently do NOT include `qwen` (excerpt `orchestrate.sh:159-193` shows `opus`, `sonnet`, `codex`, `gemini`, `copilot`).
- `debate.config.json` alias list currently omits `qwen` (file: `/Users/maruti/work/agent-debate/debate.config.json` — full aliases excerpt shown in Evidence).
- `README.md` supported tools text omits Qwen (`README.md:47,85-94`).
- `install.sh` `--agent` validation excludes qwen (`install.sh:43-47`) and installer has no qwen block.

Actionable minimal edits to implement v1 support:
- `debate.config.json`: add `qwen` alias object under `aliases` (as shown above) — one-line insertion location: after `gemini`/before `copilot` to keep ordering consistent.
- `orchestrate.sh`:
  - Add `"qwen"` to provider autodetect tuples at resolver (`:336-339`) and executor (`:972-975`); add `"qwen"` to host_provider guard tuple at `:358`; update `usage()` help at `:58` to include `qwen` in `--skip-provider` list.
- `README.md`: add Qwen to participant list and alias table; add Known Limitation note about Qwen OAuth vs API key + host usage hint.
- `install.sh`: no edits to add install target; keep deferral.

These are minimal and reversible; they do not add new runtime assumptions (no env cleanup or parsing changes).

---

## Plan

PLAN_STATUS: ~~PENDING~~ CONVERGED [[A2-R2]] [[A3-R2]]

### Plan Review [[A2-R2]]

Independent verification against source confirms the plan exactly matches the converged proposal and uses minimum viable scope:

- `orchestrate.sh` provider autodetect still excludes qwen in both paths:
  - Resolver tuple: `338: if cmd_base in ("claude", "codex", "gemini", "copilot")`
  - Executor tuple: `974: if cmd_base in ("claude", "codex", "gemini", "copilot")`
  - Expected for v1: add `"qwen"` to both tuples.
- Host-provider guard/help still exclude qwen:
  - Help text: `58: --skip-provider ... (claude|codex|gemini|copilot)`
  - Guard tuple: `358: if host_provider in ("claude", "codex", "gemini", "copilot"):`
  - Expected for v1: include `qwen` in both.
- `debate.config.json` aliases omit qwen:
  - Existing aliases include `gemini` and `copilot`; no `"qwen"` key in file (`debate.config.json:2-47`).
  - Expected for v1: add minimal `"qwen": {"name":"Qwen","provider":"qwen","command_template":["qwen","-p"],"prompt_transport":"arg"}`.
- `README.md` support/docs omit qwen:
  - Supported list currently names Claude/Codex/Gemini/Copilot (`README.md:47`, alias table `README.md:85-94`).
  - Expected for v1: add qwen participant/alias row + auth/host caveats.
- `install.sh` currently excludes qwen from supported `--agent` values:
  - Validation tuple `44: all|claude|codex|gemini|copilot`
  - Error string `46: ... claude, codex, gemini, copilot, all`
  - This matches planned deferral in Change #4 (no v1 install target), so no mismatch.

Result: plan is complete, proportional, and implementable without speculative additions (no qwen-specific parsing/env-cleanup/install plumbing in v1). No OPEN disputes remain.

### Changes

| # | File | What to change | Why |
|---|------|----------------|-----|
| 1 | debate.config.json | Add `qwen` alias object under `aliases` (see Proposal §2) | Register Qwen as an alias consistent with other providers |
| 2 | orchestrate.sh | Add `"qwen"` to provider detection tuples at resolver (`:336-339`) and executor (`:972-975`); add `"qwen"` to host_provider guard tuple at `:358`; update `usage()` help at `:58` to include `qwen` in `--skip-provider` list | Minimal wiring so orchestrator recognizes qwen by binary basename and documents host-skip usage |
| 3 | README.md | Add `qwen` to participant list and alias table; add Known Limitation note about Qwen OAuth vs API key + host usage hint | User-facing docs to avoid surprise and explain headless auth path |
| 4 | install.sh | NO CHANGE for v1 — defer adding `--agent qwen` until host instruction path confirmed | Avoid speculative host integrations per Simplicity & Brittleness rules |

### Order of Operations
1. Update `debate.config.json` (easy, safe).
2. Update `orchestrate.sh` detections & usage help.
3. Update `README.md`.
4. Smoke test: run `./orchestrate.sh --topic "Qwen smoke" --agents qwen,codex --rounds 1` locally with a configured `qwen` CLI (or use `AGENT_DEBATE_HOST_PROVIDER=qwen --skip-provider qwen` if running inside a qwen host).
5. If output is noisy, add a tiny output sanitization step for `qwen -p` (only after evidence).

---

## Parking Lot

- [A1-R1] Model/effort override support for Qwen — defer unless users request it. The CLI's own config handles model selection.
- [A1-R1] DashScope HTTP API as alternative to CLI — different integration pattern, defer unless Qwen Code CLI proves unreliable.
- [A1-R1] Qwen-specific output cleanup/parsing — defer unless `qwen -p` produces non-clean output in testing.
- [A1-R1] `install.sh --agent qwen` host integration path — no evidence yet for Qwen equivalent of `~/.codex/AGENTS.md` / `~/.claude/CLAUDE.md`; defer until path and behavior are verified.
- [A2-R1] Qwen host auto-detection via `QWEN_*` env vars in `detect_host_provider()` — no evidence yet that stable session vars exist; manual `AGENT_DEBATE_HOST_PROVIDER=qwen` is enough for v1.

---

## Dispute Log

| Round | Agent | Section | What Changed | Why | Status |
|-------|-------|---------|--------------|-----|--------|
| 1 | Codex | Proposal §3(d) | Replaced host-provider wiring item with expanded version: keep A1’s two changes (`orchestrate.sh:58`, `:358`) and add explicit manual host override doc (`AGENT_DEBATE_HOST_PROVIDER=qwen`) | Independent verification found host auto-detect only includes codex/claude/gemini (`orchestrate.sh:133-138`), while manual override exists (`:127-130`); without docs, Qwen host-direct usage is brittle — Verified by Copilot: `orchestrate.sh:127-138` shows manual override plus auto-detect set; `orchestrate.sh:58` help string needs qwen mention | CLOSED |
| 1 | Copilot | Proposal §2 & §3 | Added explicit minimal edits to register qwen: (1) add `qwen` alias to `debate.config.json`; (2) add `"qwen"` to provider autodetect tuples (resolver `:336-339`, executor `:972-975`); (3) add `"qwen"` to host_provider guard tuple at `:358`; (4) update README help text for `--skip-provider` | Minimal, reversible wiring to make CLI-based qwen integration behave like other providers. Evidence: `debate.config.json` currently lacks qwen (aliases: opus/sonnet/codex/gemini/copilot), `orchestrate.sh` autodetect tuples lack qwen at the two locations cited, and `install.sh` does not provide a qwen install path (hence deferral) — see file excerpts in Proposal | CLOSED |
| 2 | Opus | All sections | Verified Copilot's §9 edits and Codex's §3(d) changes. All three agents agree on: (1) `qwen -p` CLI approach, (2) minimal alias, (3) 4-location provider wiring in orchestrate.sh, (4) no env cleanup/output parsing for v1, (5) defer install.sh, (6) README + auth docs. Marking CONVERGED — no remaining disagreements. | All proposals independently verified against `orchestrate.sh`, `debate.config.json`, `install.sh`, and `README.md`. Evidence cited inline throughout. [A1-R2] | CLOSED |
| 2 | Codex | Plan | Changed `PLAN_STATUS` from `PENDING` to `CONVERGED` and added evidence-backed plan review notes [[A2-R2]] | Independently verified all target gaps still exist in source (`orchestrate.sh:58,338,358,974`; `debate.config.json` aliases omit qwen; `README.md:47,85-94` omit qwen) and verified planned `install.sh` deferral matches current constraints (`install.sh:44-46`) | CLOSED |
| 2 | Copilot | Plan Review | Reviewed plan and confirmed it implements the converged proposal; appended tag [[A3-R2]] to PLAN_STATUS | Verified orchestrate.sh detection locations and usage help (`orchestrate.sh:58,336-339,358,972-975`), confirmed `debate.config.json` needs `qwen` alias addition, README needs qwen rows, and `install.sh` deferral is correct; no OPEN disputes remain | CLOSED |

**Status values:** `OPEN` = unresolved, needs further debate. `CLOSED` = all agents agree (accepted, conceded, or resolved). `PARKED` = deferred, not blocking convergence.

<reminder>
<sql_tables>No tables currently exist. Default tables (todos, todo_deps) will be created automatically when you first use the SQL tool.</sql_tables>
</reminder>
