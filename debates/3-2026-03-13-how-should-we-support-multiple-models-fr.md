# Debate: How should we support multiple models from the same provider in a single debate?

**Created:** 2026-03-13
**Agent 1:** Opus
**Agent 2:** Codex
**Agent 3:** Gemini (Auto)
**Max Rounds:** 3
**Status:** OPEN

## Context

How should we support multiple models from the same provider in a single debate? Currently debates are between different providers, but providers like GitHub Copilot expose many models (GPT-4o, GPT-5, o3, etc.). We should allow e.g. `--agents copilot:gpt-5,copilot:o3,opus` to pit two Copilot models against each other (or against other providers). What config/orchestrator changes are needed?

### Evidence

**Current state — model override already works for single use:**
The `alias:model` syntax exists (`orchestrate.sh:248-253`):
```python
if ":" in token:
    alias_raw, model_override = token.split(":", 1)
    model_override = model_override.strip()
```
Model override is injected into the command at `orchestrate.sh:314-337` — replaces existing `--model` value or inserts `--model <override>` before the prompt flag.

**Current blocker — uniqueness check prevents same-alias duplicates:**
`participant_key = (provider, tuple(cmd), transport)` at `orchestrate.sh:344`. Two `copilot:gpt-5` and `copilot:o3` would produce different commands (different `--model` values), so they'd pass the uniqueness check. This already works.

**Current blocker — display name collision:**
Both `copilot:gpt-5` and `copilot:o3` would get `name = "Copilot"` (from `debate.config.json:36`). The debate file header would show:
```
**Agent 1:** Copilot
**Agent 2:** Copilot
```
This makes the debate unreadable — you can't tell which agent said what.

**Current blocker — skip-provider with multiple same-provider agents:**
If both agents are `copilot` provider and you're running inside a Copilot host session, `--skip-provider copilot` would skip ALL copilot turns, not just the host's. The host-provider skip logic at `orchestrate.sh:361-367` counts all agents with the host provider and requires `--skip-provider` — but it would skip every copilot agent, not just one.

**Copilot CLI model override verified:**
`debate.config.json:38` shows `--model gpt-5-mini` in the command template. The Copilot CLI `--model` flag selects which model to use. So `copilot:o3` would produce `["copilot", "-s", "--yolo", "--no-ask-user", "--model", "o3", "--output-format", "json", "-p"]` — the model override injection at `orchestrate.sh:317-323` would replace `gpt-5-mini` with `o3`.

### Relevant Files
- `orchestrate.sh:244-358` — agent resolution, uniqueness, model override injection
- `orchestrate.sh:361-367` — host-provider skip enforcement
- `debate.config.json` — alias definitions with command templates

### Constraints
- Must not break existing single-model-per-provider usage
- Display names must be distinguishable in debate file headers and dispute logs

---

## Proposal

STATUS: CONVERGED

### 1. The model override syntax already works mechanically [A1-R1]

`--agents copilot:gpt-5,copilot:o3,opus` already produces correct, distinct commands. The `alias:model` parser at `orchestrate.sh:248-253` splits the token, and model injection at `orchestrate.sh:314-337` replaces or inserts `--model`. The uniqueness check at `orchestrate.sh:344` uses `(provider, tuple(cmd), transport)` which will differ because the commands contain different `--model` values.

**No changes needed for command resolution.**

Verified independently: `orchestrate.sh:317-323` mutates existing `--model` argument, and uniqueness is based on full `tuple(cmd)` at `orchestrate.sh:344` (actual), so `copilot:gpt-5` vs `copilot:o3` are distinct participants (expected). [A2-R1]

### 2. Auto-disambiguate display names when same alias used multiple times [A1-R1]

~~When the same alias appears more than once with different model overrides, append the model name to the display name. Change in `orchestrate.sh` resolver, after building `cmd` (around line 347):~~

~~[A2-R1] Modify: disambiguate repeated aliases for **all** duplicates, including the one using default model.~~
[A3-R1] Modify: disambiguate based on final **display name** collisions instead of alias counts. This covers cases where different aliases share the same name (e.g., `sonnet` and `sonnet-3-5` both named "Sonnet").  
Evidence: `debate.config.json` uses the `name` field for the header (`orchestrate.sh:273,349`). Collisions on this field are the root cause of unreadability.  
Implementation: Store the `effective_model` during the first pass, then perform a second pass to update names for any colliding display names.

```python
# Pass 1: existing loop (orchestrate.sh:244-358)
for token in requested:
    ...
    # [A2-R1] logic to derive effective model
    effective_model = model_override
    if not effective_model:
        # Check spec for default_model first (e.g. orchestrate.sh:293)
        effective_model = spec.get("default_model", "")
    if not effective_model:
        # Fallback: search the built command for --model (useful for hardcoded templates)
        for i, part in enumerate(cmd):
            if part == "--model" and i + 1 < len(cmd):
                effective_model = cmd[i + 1]
                break

    resolved.append({
        "name": name.strip(),
        "_effective_model": effective_model or "default",
        ...
    })

# [A3-R1] Pass 2: Disambiguate colliding names
name_counts = {}
for r in resolved:
    n = r["name"]
    name_counts[n] = name_counts.get(n, 0) + 1

for r in resolved:
    if name_counts[r["name"]] > 1:
        suffix = r.get("_effective_model", "default")
        r["name"] = f"{r['name']} ({suffix})"
```

This remains minimal and robustly handles all duplication scenarios (same alias, or different aliases with same name).

### 3. Skip-provider with multiple same-provider agents [A1-R1]

Current behavior at `orchestrate.sh:361-367`: if `host_provider == "copilot"` and `skip_provider == "copilot"`, ALL copilot agents get skipped (host-direct turns). This is actually correct for the host scenario — if you're running inside Copilot, you can't invoke any Copilot CLI subprocess (it would conflict).

For the non-host scenario (e.g., running from Claude with `--agents copilot:gpt-5,copilot:o3`), no skip is needed and the orchestrator invokes both Copilot agents normally. This already works.

**No changes needed for skip-provider.**

Verified behavior: execution loop skips every matching provider (`orchestrate.sh:1399-1401`) and usage text says "`--skip-provider` Skip invoking one provider" (`orchestrate.sh:59`). This is consistent with provider-wide host-direct mode, not per-participant skipping. [A2-R1]
[A3-R1] Concur. Verified in `orchestrate.sh:1399-1401`: `if [[ -n "$SKIP_PROVIDER" && "$provider" == "$SKIP_PROVIDER" ]]; then ...`. The skip is strictly provider-based to avoid subprocess conflicts in host-direct sessions.

### 4. Debate file header — Agent names [A1-R1]

The template uses `{AGENT_1_NAME}`, `{AGENT_2_NAME}`, etc. These are populated from `AGENT_NAMES` array which comes from the resolved display names. If we disambiguate names in §2, the headers automatically show the right names.

**No template changes needed.**

Verified path: names are populated from resolver output into `AGENT_NAMES` (`orchestrate.sh:392-403`) and then substituted into template tokens (`orchestrate.sh:1030-1036`). [A2-R1]

### 5. Tag disambiguation [A1-R1]

Tags like `[A1-R1]`, `[A2-R1]` are agent-index-based, not name-based. Two Copilot agents would be `[A1-R1]` and `[A2-R1]` — already distinct.

**No tag changes needed.**

Verified by prompt construction: tag instructions are index-driven (`orchestrate.sh:1063-1071`, `orchestrate.sh:1116-1123`), independent of display name collisions. [A2-R1]

### 6. Summary of actual changes needed [A1-R1]

~~Only ONE change: auto-append model name to display name when `model_override` is provided.~~

[A2-R1] ~~One change is still sufficient, but scope must be slightly broader: disambiguate repeated aliases using effective model (override or existing `--model` value), not override-only.~~

[A3-R1] Implementation requires updating the Python resolver in `orchestrate.sh` to:
1. Extract `effective_model` during the alias resolution loop.
2. Store `effective_model` in the temporary `resolved` objects.
3. Perform a second pass to suffix names if duplicate display names exist.
4. (Optional) Cleanup temporary `_effective_model` key before JSON dump.

---

## Plan

PLAN_STATUS: CONVERGED [[A2-R2]], [[A3-R2]]

[[A2-R2]] Replaced placeholder with executable plan. Evidence the prior plan was incomplete: the `Changes` table contained only an empty row `| | | | |` and `Order of Operations` was `1. {step}` (actual), while guardrails require exact files, concrete edits, and ordered steps (expected).

### Changes

| # | File | What to change | Why |
|---|------|----------------|-----|
| 1 | `orchestrate.sh` | In resolver loop (`orchestrate.sh:244-358`), compute `effective_model` after model override injection (`orchestrate.sh:314-337`) and before `resolved.append(...)` (`orchestrate.sh:349`). Source order: `model_override` if present; else `spec.get("default_model")`; else scan final `cmd` for `--model <value>`; else `"default"`. Store as temporary key (e.g., `"_effective_model"`). [[A2-R2]] | Proposal §2/§6 requires suffixing duplicates with effective model, including default participant when no override is provided. |
| 2 | `orchestrate.sh` | Add second pass after resolver loop completes and before name export (`orchestrate.sh:392-403`): count collisions on final `name` string, and for names with count > 1, rewrite `name` to `"{name} ({_effective_model})"`. [[A2-R2]] | Root issue is display-name collision (`orchestrate.sh:273,349`), not alias duplication only. Two-pass collision handling fixes same-name across different aliases too. |
| 3 | `orchestrate.sh` | Optional cleanup: remove `"_effective_model"` from each `resolved` entry once names are finalized (before values are consumed by downstream arrays/JSON). [[A2-R2]] | Keeps temporary planning field from leaking into outputs while preserving minimal implementation footprint. |
| 4 | `orchestrate.sh` (manual verification points) | Validate no behavior regressions in skip/tag/template paths referenced in proposal: skip logic (`orchestrate.sh:361-367`, `1399-1401`) untouched; template substitution (`orchestrate.sh:1030-1036`) untouched; tag generation (`orchestrate.sh:1063-1071`, `1116-1123`) untouched. [[A2-R2]] | Debate agreed no changes are needed in these paths; verification ensures scope remains minimal and avoids accidental creep. |

### Order of Operations
1. Implement `effective_model` derivation in the existing participant resolution loop in `orchestrate.sh:244-358`, directly after current model injection logic (`314-337`). [[A2-R2]]
2. Implement name-collision second pass before `AGENT_NAMES` population (`392-403`) so headers inherit disambiguated names without template changes. [[A2-R2]]
3. Remove temporary `_effective_model` key (optional hygiene) and run syntax check: `bash -n orchestrate.sh`. [[A2-R2]]
4. Run smoke tests to validate expected outputs:  
   - `./orchestrate.sh --topic "t" --agents copilot:gpt-5,copilot:o3,opus --rounds 1` should render distinct names like `Copilot (gpt-5)` and `Copilot (o3)` in debate header.  
   - `./orchestrate.sh --topic "t" --agents copilot,copilot:o3 --rounds 1` should render both names disambiguated (default + override).  
   - Existing single-provider usage (e.g., `--agents opus,codex`) should remain unchanged. [[A2-R2]]

### Non-trivial code sketch

```python
# in resolver, after cmd finalized and before resolved.append(...)
effective_model = model_override.strip() if model_override else ""
if not effective_model:
    effective_model = str(spec.get("default_model", "")).strip()
if not effective_model:
    for i, part in enumerate(cmd):
        if part == "--model" and i + 1 < len(cmd):
            effective_model = cmd[i + 1].strip()
            break
if not effective_model:
    effective_model = "default"

resolved.append({
    "name": name.strip(),
    "_effective_model": effective_model,
    ...
})

# second pass before AGENT_NAMES extraction
name_counts = {}
for r in resolved:
    name_counts[r["name"]] = name_counts.get(r["name"], 0) + 1

for r in resolved:
    if name_counts[r["name"]] > 1:
        r["name"] = f"{r['name']} ({r.get('_effective_model', 'default')})"
    r.pop("_effective_model", None)
```

[[A2-R2]] Verified this plan matches converged proposal scope: only resolver naming behavior changes; no skip-provider, tag, or template logic changes.
[[A3-R2]] Independently verified against `orchestrate.sh:244-358`. The plan accurately identifies the resolution loop and the correct injection points for `effective_model` derivation and the subsequent name-collision pass.

---

## Parking Lot

- [A1-R1] Per-participant effort overrides (e.g., `copilot:gpt-5:high`) — not needed for v1, model override is enough.
- [A1-R1] README documentation for multi-model syntax — add after implementation is tested.

---

## Dispute Log

| Round | Agent | Section | What Changed | Why | Status |
|-------|-------|---------|--------------|-----|--------|
| 1 | A2 | Proposal §2 | Replaced override-only naming with duplicate-alias naming using effective model for all duplicates. | Evidence from `orchestrate.sh:349` shows current duplicate aliases both resolve to identical `name.strip()`; `copilot,copilot:o3` remains partially ambiguous without labeling the default participant model. | CLOSED |
| 1 | A2 | Proposal §6 | Reframed “one change” to require effective-model disambiguation (override or existing `--model`) rather than override-only suffix. | Keeps single-change scope while meeting “distinguishable display names” constraint for mixed default+override duplicate aliases. | CLOSED |
| 1 | A3 | Proposal §2 | Refined disambiguation check to trigger on **display name** collisions instead of alias counts. | Handles scenarios where different aliases have the same name (e.g. `opus` and `opus-legacy` both named "Opus"). | CLOSED |
| 1 | A3 | Proposal §6 | Updated summary to reflect 2-pass name disambiguation logic in the Python resolver. | Ensures the implementation correctly handles name collisions by verifying counts after all aliases are resolved. | CLOSED |
| 2 | A1 | All | Verified Gemini's 2-pass approach is strictly better than my original override-only proposal — handles cross-alias name collisions. Codex's effective_model extraction (override → default_model → command --model) covers all cases. Marking CONVERGED. [A1-R2] | All three agents agree on: (1) command resolution already works, (2) 2-pass name disambiguation with effective_model, (3) no skip-provider/tag/template changes needed. | CLOSED |
| 2 | A2 | Plan | Replaced placeholder-only Plan with concrete implementation plan and switched `PLAN_STATUS` to `CONVERGED`. [[A2-R2]] | Independent verification: prior Plan had no actionable content (`| | | | |` and `1. {step}`), which violated plan requirements; new plan now specifies exact file (`orchestrate.sh`), line-scoped edits (`244-358`, `314-337`, `392-403`), order, and validation commands. | CLOSED |
| 2 | A3 | Plan | Verified the plan against `orchestrate.sh` code structure. [[A3-R2]] | Confirmed that `effective_model` derivation covers all logic paths (override, default_model, and CLI flag scan) and that the 2-pass collision logic correctly addresses the proposal's requirements. | CLOSED |
