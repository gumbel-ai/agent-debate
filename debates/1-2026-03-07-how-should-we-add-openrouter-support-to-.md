# Debate: How should we add OpenRouter support to agent-debate? Currently only Claude, Codex, and Gemini CLIs are supported. OpenRouter would enable open-source models (Llama, DeepSeek, Mistral, etc.) to participate via its unified API. What is the minimum viable approach — wrapper script, config aliases, installer changes?

**Created:** 2026-03-07
**Agent 1:** Opus
**Agent 2:** Codex
**Agent 3:** Gemini (Auto)
**Max Rounds:** 5
**Status:** OPEN

## Context

How should we add OpenRouter support to agent-debate? Currently only Claude, Codex, and Gemini CLIs are supported. OpenRouter would enable open-source models (Llama, DeepSeek, Mistral, etc.) to participate via its unified API. What is the minimum viable approach — wrapper script, config aliases, installer changes?

### Evidence

Current alias system in `debate.config.json:1-41` defines 4 aliases (opus, sonnet, codex, gemini), all using first-party CLIs. The orchestrator resolves aliases via Python in `orchestrate.sh:150-178` (BUILTIN_ALIASES) and invokes them via `subprocess.run(command + [prompt])` at `orchestrate.sh:~795`. Transport is `"arg"` (prompt as CLI argument) or `"stdin"` (prompt piped). Model overrides use `{MODEL}` placeholder or fallback `--model` append (`orchestrate.sh:296-298`).

Provider auto-detection at `orchestrate.sh:300-303`:
```python
if cmd_base in ("claude", "codex", "gemini"):
    provider = cmd_base
```

OpenRouter has no CLI. It exposes an OpenAI-compatible REST API at `https://openrouter.ai/api/v1/chat/completions` with Bearer token auth. 200+ models available.

Additional code-path evidence from independent verification:
- `orchestrate.sh:285-295` builds `cmd` by direct string replacement only; there is no `expanduser`/`expandvars`.
- `orchestrate.sh:799-803` passes `command` directly to `subprocess.run(...)` (no shell), so `$HOME` and `~` are not expanded in alias command paths.
- `install.sh:52-60` copies files as-is; it does not template `debate.config.json`.
- `rg -n "jq" orchestrate.sh install.sh README.md debate.config.json` returns no `jq` usage; `orchestrate.sh` already depends on `python3` at lines `139`, `445`, `492`, `753`. [A2-R1]
- `install.sh:65-73` defines `get_file` which handles local copies or curl downloads, compatible with a new script deployment. [A3-R1]

### Relevant Files
- `debate.config.json:1-41` — alias definitions with command_template, reasoning, prompt_transport
- `orchestrate.sh:150-178` — BUILTIN_ALIASES (Python dict, fallback when no config file)
- `orchestrate.sh:240-304` — alias resolution: model/effort placeholders, transport validation
- `orchestrate.sh:~790-810` — invoke_agent: subprocess.run with command list, no shell=True
- `install.sh:278-290` — install_shared_config: deploys files to ~/.agent-debate/
- `README.md:39-44` — alias table in docs

### Constraints
- Must not break existing Claude/Codex/Gemini aliases
- Must work with existing `command_template` + `prompt_transport` mechanism
- API key via env var (OPENROUTER_API_KEY), never in config files
- Minimum viable — ship the smallest useful thing first

---

## Proposal

STATUS: CONVERGED [A3-R1]

### 1. Thin CLI wrapper: `openrouter-chat` [A1-R1]

Since OpenRouter has no CLI, we need a ~30 line bash script that matches the interface the orchestrator expects (prompt in → text out).

~~```bash
#!/usr/bin/env bash
set -euo pipefail

# Dependency checks
for dep in curl jq; do
  type "$dep" >/dev/null 2>&1 || { echo "Error: $dep required but not installed." >&2; exit 1; }
done

MODEL=""
PROMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    *) PROMPT="$1"; shift ;;
  esac
done

[[ -z "$PROMPT" ]] && PROMPT=$(cat)
[[ -z "$MODEL" ]] && { echo "Error: --model required" >&2; exit 1; }
[[ -z "${OPENROUTER_API_KEY:-}" ]] && { echo "Error: OPENROUTER_API_KEY not set" >&2; exit 1; }

RESPONSE=$(curl -sS -w "\n%{http_code}" https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg model "$MODEL" --arg prompt "$PROMPT" '{
    model: $model,
    messages: [{role: "user", content: $prompt}],
    max_tokens: 16384
  }')")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
  echo "Error: OpenRouter API returned HTTP $HTTP_CODE" >&2
  echo "$BODY" | jq -r '.error.message // .' >&2 2>/dev/null || echo "$BODY" >&2
  exit 1
fi

CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content // empty')
[[ -z "$CONTENT" ]] && { echo "Error: No content in API response" >&2; exit 1; }
printf '%s' "$CONTENT"
```~~  
~~Why a wrapper: the orchestrator expects a CLI command → text interface (`orchestrate.sh:~795`). A wrapper keeps `command_template` clean. Dependencies are just `curl` + `jq`, both standard on macOS/Linux. [A1-R1]~~  
Wrapper is correct, but `jq` is unnecessary dependency surface for v1. Evidence: repo currently has no `jq` dependency (`rg -n "jq" orchestrate.sh install.sh README.md debate.config.json` -> 0 matches), while `python3` is already required by orchestrator (`orchestrate.sh:139,445,492,753`). Minimum viable should be a Python wrapper (`openrouter-chat.py`) using stdlib `json` + `urllib.request`, with same interface (`--model`, prompt from arg or stdin), and no hardcoded `max_tokens` so model-specific limits don’t fail unexpectedly. [A2-R1]

**Verified Python Wrapper (v1 Minimal):** [A3-R1]
```python
import json, os, sys, urllib.request
def main():
    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key: sys.exit("Error: OPENROUTER_API_KEY not set")
    model, prompt, args = None, "", sys.argv[1:]
    while args:
        arg = args.pop(0)
        if arg == "--model" and args: model = args.pop(0)
        else: prompt = arg
    if not prompt and not sys.stdin.isatty(): prompt = sys.stdin.read()
    if not model or not prompt: sys.exit("Usage: openrouter-chat.py --model <model> [prompt]")
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}]}).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req) as res:
            print(json.loads(res.read())["choices"][0]["message"]["content"], end="")
    except Exception as e: sys.exit(f"Error: {e}")
if __name__ == "__main__": main()
```

### 2. Single generic alias: `openrouter` [A1-R1]

Add one alias — no model-specific convenience aliases (Llama, DeepSeek, etc.) in v1. Users specify the model explicitly via `openrouter:<model-id>` syntax (e.g., `--agents openrouter:meta-llama/llama-4-maverick,opus`).

~~Config addition to `debate.config.json` and `orchestrate.sh` BUILTIN_ALIASES:
```json
"openrouter": {
  "name": "OpenRouter",
  "provider": "openrouter",
  "command_template": ["$HOME/.agent-debate/openrouter-chat", "--model", "{MODEL}"],
  "prompt_transport": "arg"
}
```~~
Merged v1 alias (consistent with Python wrapper and no execute-bit requirement):
```json
"openrouter": {
  "name": "OpenRouter",
  "provider": "openrouter",
  "command_template": ["python3", "$HOME/.agent-debate/openrouter-chat.py", "--model", "{MODEL}"],
  "prompt_transport": "arg"
}
```
Evidence: invocation path is `subprocess.run(command + [prompt], ...)` (`orchestrate.sh:802`) and does not use shell expansion; command element 0 must be executable (`python3` is). This avoids relying on wrapper file mode. [A2-R1] Verified: `orchestrate.sh` already executes `python3` directly at lines 445 and 492. [A3-R1]

~~Note: uses `$HOME` not `~` because `orchestrate.sh:~795` uses `subprocess.run(command_list)` with no `shell=True` — tilde expansion does not occur in argv lists. The installer should resolve `$HOME` to an absolute path at install time. [A1-R1]~~  
`$HOME` and `~` both fail today because alias parts are passed literally from config to `subprocess.run` without shell expansion. Evidence: command parts are appended directly at `orchestrate.sh:285-295`; invocation is `subprocess.run(command, ...)` / `subprocess.run(command + [prompt], ...)` at `orchestrate.sh:799-803`. Also installer copies static config (`install.sh:52-60`, `278-285`) and does not template paths. Minimum fix: in alias resolution, expand each command part before append:  
```python
part = os.path.expandvars(os.path.expanduser(part))
cmd.append(part)
```  
Then alias can safely use `"command_template": ["python3", "$HOME/.agent-debate/openrouter-chat.py", "--model", "{MODEL}"]`. [A2-R1]

No `default_model` — OpenRouter model availability/pricing changes frequently. Requiring explicit model selection avoids stale defaults. [A1-R1]  
Verified with resolver logic: if `{MODEL}` exists and neither override nor `default_model` is set, run fails fast (`orchestrate.sh:286-289`), which is acceptable for explicit-model v1. [A2-R1]

### 3. Provider field instead of auto-detection [A1-R1]

The alias sets `"provider": "openrouter"` explicitly. This is cleaner than extending the basename auto-detection at `orchestrate.sh:300-303` because:
- `openrouter-chat` is our wrapper, not a well-known CLI name
- The `provider` field is already read at `orchestrate.sh:246-251`
- Keeps the auto-detection list small (only first-party CLIs)

Verified: provider from alias is persisted into runtime config (`orchestrate.sh:308-315`) and consumed in invocation (`orchestrate.sh:774-797`) without requiring basename detection. [A2-R1]

### 4. Installer changes [A1-R1]

Add to `install_shared_config()` in `install.sh:278-290`:
~~```bash
get_file "openrouter-chat" "$shared_dir/openrouter-chat"
chmod +x "$shared_dir/openrouter-chat"
```~~
The wrapper script lives in the repo root and gets deployed to `~/.agent-debate/openrouter-chat` alongside `orchestrate.sh`. [A1-R1]  
~~If wrapper is Python, install as `openrouter-chat.py` (no `chmod` required unless using shebang execution). Keep deployment in shared dir to avoid PATH assumptions. [A2-R1]~~  
If wrapper is Python and alias uses `["python3", "$HOME/.agent-debate/openrouter-chat.py", ...]`, installer only needs:
```bash
get_file "openrouter-chat.py" "$shared_dir/openrouter-chat.py"
```
No `chmod` is required in this mode because `python3` is the executed binary (`subprocess.run` executes argv[0], `orchestrate.sh:799-803`). If we execute the script directly instead, then shebang + `chmod +x` are required. [A2-R1] Verified: `get_file` in `install.sh:65-73` correctly supports both local and remote sourcing for this new file. [A3-R1]

### 5. README update [A1-R1]

Add to alias table:
```
| `openrouter` | Any OpenRouter model | arg | none |
```

Add note: "Set `OPENROUTER_API_KEY` env var to use OpenRouter. Specify model with `openrouter:<model-id>` syntax (e.g., `--agents openrouter:meta-llama/llama-4-maverick,opus`)."

Also update the `--skip-provider` docs currently listing only `claude|codex|gemini` (`README.md:95`, `orchestrate.sh:56`) to clarify OpenRouter is supported but does not need host-direct handling unless a future OpenRouter host session exists. [A2-R1]

### 6. Required orchestrator code change (missing in A1) [A2-R1]

Smallest required code delta beyond alias+installer:
1. In alias resolution loop (`orchestrate.sh:285-295`), expand env/home in each command part before append.
2. Add built-in alias entry in `BUILTIN_ALIASES` (`orchestrate.sh:150-178`) so OpenRouter still works when no config file is present.
3. Keep `prompt_transport: "arg"` for consistency in v1; wrapper should still support stdin fallback.

Why required: without step 1, configured path `$HOME/.agent-debate/openrouter-chat*` is passed literally and executable lookup fails (`FileNotFoundError` equivalent at subprocess exec boundary). Current behavior is actual literal path; expected is absolute home path.

### Claude accepts Codex's corrections [A1-R2]

**Python wrapper over bash+jq:** Codex is right. Verified: `orchestrate.sh` already requires `python3` at 4+ callsites (lines 139, 445, 492, 753). Adding `jq` as a new dependency when Python stdlib `json` + `urllib.request` can do the same job is unnecessary dependency surface. The wrapper should be `openrouter-chat.py` using only Python stdlib. Conceding this — Codex [A2-R1] is correct. [A1-R2]

**Path expansion in orchestrator:** Codex is right. Verified: `orchestrate.sh:285-295` does direct string replacement on `{MODEL}` and `{EFFORT}` but no `os.path.expandvars`/`os.path.expanduser`. And `subprocess.run` at lines 799-803 uses no `shell=True`. A literal `$HOME/...` in the command list would cause `FileNotFoundError`. The fix is exactly what Codex proposed — add `os.path.expandvars(os.path.expanduser(part))` in the command-building loop. This also benefits any future alias that uses env vars in paths. Conceding this — Codex [A2-R1] is correct. [A1-R2]

**Required orchestrator code change (section 6):** Agreed. My original proposal missed this. The `expandvars`/`expanduser` addition is required for OpenRouter to work and is a 1-line change in the right place. Conceding this — Codex [A2-R1] is correct. [A1-R2]

**Hardcoded max_tokens removal:** Agreed. Different OpenRouter models have wildly different context windows. Omitting `max_tokens` lets the API use each model's default, which is the safest v1 behavior. Can add a `--max-tokens` flag to the wrapper later if needed. [A1-R2]

~~All three disputes are resolved. Marking CONVERGED. [A1-R2]~~  
~~One blocking inconsistency remains: alias/template choice must match installer/runtime invocation strategy (direct-exec script vs `python3 script.py`). Current merged minimum is `python3 + openrouter-chat.py` to avoid execute-bit/shebang coupling. Keeping this dispute OPEN until all agents explicitly accept the merged command template and installer snippet. [A2-R1]~~  
**Gemini accepts and verifies the merged approach:** [A3-R1] Verified that `orchestrate.sh` already uses `python3` for internal logic, and `subprocess.run(command + [prompt])` will correctly invoke `python3` with the script as an argument if `command` is `["python3", "path/to/script.py", ...]`. This is the most portable approach as it avoids dependency on `chmod` or shebang behavior across different OS environments. Evidence: `orchestrate.sh:139` calls `python3 -c`, confirming the dependency is already present. Dispute 4 is resolved. [A3-R1]

### What v1 does NOT include [A1-R1]

- No convenience aliases (llama, deepseek, etc.) — defer until real usage shows stable defaults
- No streaming — orchestrator reads full response, curl waits
- No token/cost tracking — defer to parking lot
- No reasoning effort support — most OpenRouter models don't expose it

---

## Parking Lot

- [A1-R1] Token/cost tracking for OpenRouter (pay-per-use unlike free-tier CLIs). Needs OpenRouter billing API investigation.
- [A1-R1] Per-model `max_tokens` config override. 16384 default may not suit all models.
- [A1-R1] Convenience aliases (llama, deepseek, mistral) once real usage shows stable model defaults.
- [A2-R1] `prompt_transport: "stdin"` for OpenRouter alias to avoid potential argv-size limits on very large debate files. Defensive — no evidence this currently occurs.

---

## Dispute Log

| Round | Agent | Section | What Changed | Why | Status |
|-------|-------|---------|--------------|-----|--------|
| 1 | A2 | 1. Thin CLI wrapper | Replaced `curl+jq` recommendation with Python stdlib wrapper and removed hardcoded `max_tokens` | Evidence shows existing repo already depends on `python3` (`orchestrate.sh:139,445,492,753`) and has zero `jq` usage; smallest dependency footprint is Python-only | CLOSED |
| 1 | A2 | 2. Single generic alias | Rejected installer-time `$HOME` resolution assumption; added required `expandvars/expanduser` in orchestrator alias resolution | Current code passes literal command parts (`orchestrate.sh:285-295`) into `subprocess.run` with no shell expansion (`799-803`); without expansion, `$HOME/...` path fails | CLOSED |
| 1 | A2 | 6. Required orchestrator change | Added explicit minimal code-change section | Path expansion gap is a blocking runtime issue not covered by alias+installer-only plan | CLOSED |
| 1 | A2 | 2 + 4 (alias/installer consistency) | Replaced direct script execution template with `python3 openrouter-chat.py` and aligned installer snippet; struck inconsistent guidance | Evidence: orchestrator executes argv directly (`orchestrate.sh:799-803`), so direct `.py` execution requires shebang+execute bit; `python3` first token avoids that coupling and is smaller-risk v1 | CLOSED |
