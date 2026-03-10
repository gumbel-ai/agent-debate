# Debate: {TOPIC}

**Created:** {DATE}
**Agent 1:** {AGENT_1_NAME}
**Agent 2:** {AGENT_2_NAME}
**Agent 3:** {AGENT_3_NAME}
**Max Rounds:** {MAX_ROUNDS}
**Status:** OPEN

## Context

{PROBLEM_DESCRIPTION}

### Evidence

{What was observed, with concrete data. Include: run identifiers, log paths, event counts, actual vs expected values, error messages. A reader must be able to evaluate the problem without opening another file.}

### Relevant Files
{FILE_LIST_WITH_KEY_SECTIONS}

### Constraints
{ANY_CONSTRAINTS_OR_NON_NEGOTIABLES}

---

## Proposal

STATUS: OPEN

{Agent 1 writes the initial proposal here in Round 1.
 Other agents edit in-place starting Round 1 response.
 All agents continue editing in-place through subsequent rounds.
 See agent-guardrails.md for editing conventions.

 Every fix must cite exact file:line, what the code does now, and what it should do instead.
 Include verification data (log counts, runtime output) inline — not by reference.}

---

## Implementation Plan

PLAN_STATUS: PENDING

{This section is populated after the debate converges (when --plan is used).
 Agent 1 writes the initial implementation plan. Other agents review and edit
 in-place using the same guardrails. The plan must include: files to change,
 order of operations, and concrete code changes.}

### Changes

| # | File | What to change | Why |
|---|------|----------------|-----|
| | | | |

### Order of Operations
1. {step}

---

## Parking Lot

{Related issues noticed during debate that are out of scope.
 Any agent can add items here. Format: `- [A1-R2] <issue description>`}

---

## Dispute Log

| Round | Agent | Section | What Changed | Why | Status |
|-------|-------|---------|--------------|-----|--------|
| | | | | | |

**Status values:** `OPEN` = unresolved, needs further debate. `CLOSED` = all agents agree (accepted, conceded, or resolved). `PARKED` = deferred, not blocking convergence.
