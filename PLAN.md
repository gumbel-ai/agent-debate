# agent-debate — OSS Project Plan

**Repo:** https://github.com/gumbel-ai/agent-debate

## What It Is

A structured protocol for two AI coding agents to debate technical decisions via a shared markdown file. Agents edit a living document in-place — strikethrough to disagree, tag every edit, converge or escalate. The human makes the final call.

This is NOT a chatbot. It's adversarial code review with convergence rules.

## What We Have (from TrueLoop)

Copied to this repo:

| File | What It Is | OSS-Ready? |
|------|-----------|------------|
| `agent-guardrails.md` | Behavioral rules injected into every agent | Yes — needs TrueLoop-specific examples swapped for generic ones |
| `TEMPLATE.md` | Starting template for new debates | Yes — already generic |
| `orchestrate.sh` | Bash script that runs the debate loop | Partially — hardcoded to `claude` and `codex` CLI commands |
| `examples/vertex-ai-migration.md` | Real converged debate (10 rounds, 2 agents) | Needs light sanitization |
| `examples/dead-code-cleanup.md` | Simpler converged debate | Needs light sanitization |

## Target Users

- Teams using multiple AI coding agents (Claude Code + Codex, Claude + Cursor, etc.)
- Solo developers who want adversarial review of their own proposals
- Anyone who wants structured technical decision-making, not vibes-based "LGTM"

## Repo Structure (Target)

```
agent-debate/
├── README.md                # The pitch + quickstart
├── LICENSE                  # MIT
├── agent-guardrails.md      # Core protocol rules (the heart of the project)
├── TEMPLATE.md              # Debate file template
├── orchestrate.sh           # Shell-based orchestrator (v1)
├── examples/
│   ├── vertex-ai-migration.md   # Real-world example: infrastructure migration
│   └── dead-code-cleanup.md     # Real-world example: code cleanup
├── docs/
│   ├── how-it-works.md      # Detailed protocol explanation
│   ├── customization.md     # How to adapt guardrails for your team
│   └── agent-setup.md       # How to configure different AI agents
└── PLAN.md                  # This file (remove before v1 release)
```

## What Needs to Be Built

### Phase 1: Publishable MVP

1. **Sanitize guardrails** — Replace TrueLoop-specific examples (log paths, file references) with generic ones. Keep the same rules, just swap the illustrations.

2. **Sanitize examples** — Remove any proprietary code references. Keep the debate structure and flow intact — that's the value.

3. **Write README.md** — This is the most important file. Needs:
   - One-paragraph pitch (what + why)
   - 30-second quickstart (how to run your first debate)
   - Before/after comparison (unstructured AI review vs. debate protocol)
   - Link to guardrails and examples

4. **Make orchestrator agent-agnostic** — Current `orchestrate.sh` hardcodes `claude` and `codex` CLI commands. Should support:
   - Any CLI that accepts a prompt and returns text
   - Configuration via env vars or flags (`--agent1-cmd`, `--agent2-cmd`)
   - Manual mode (human copies prompt, pastes response) for agents without CLI

5. **Add CLAUDE.md instructions** — So Claude Code users can drop this into any project and say "start a debate on X". This is the zero-friction entry point.

### Phase 2: Polish (after initial feedback)

6. **CLI wrapper** — `npx agent-debate new "topic"` or `pip install agent-debate`. Depends on where adoption comes from. Don't build until Phase 1 gets traction.

7. **VS Code extension** — Side-by-side debate viewer. Markdown is fine for now.

8. **Debate analytics** — Track convergence rate, rounds-to-resolution, dispute patterns. Only if people ask for it.

## Key Design Decisions

### Keep as-is (battle-tested from 10 debates):
- Markdown as the format — no database, no web app, no JSON
- Living document editing (strikethrough + counter) — NOT append-only chat
- Dispute log with explicit OPEN/CLOSED/PARKED statuses
- Evidence-based rules — the single most valuable part
- Simplicity & scope-creep resistance rules
- Human has final authority

### Change for OSS:
- Remove TrueLoop-specific language from guardrails examples
- Make agent invocation pluggable (not just Claude + Codex)
- Add "manual mode" for people who paste prompts into web UIs
- Add CLAUDE.md snippet so Claude Code users get it for free

## What Makes This Different

Most AI code review tools:
- Ask ONE model and accept the answer
- Use chat format (context gets lost, no convergence)
- Don't require evidence (vibes-based agreement)
- Don't track disputes (disagreements get buried)

agent-debate:
- TWO agents with different perspectives
- Living document (current state is always visible)
- Evidence is mandatory (no claim without proof)
- Disputes are tracked and must be explicitly resolved
- Scope creep is actively resisted by the protocol
- Human decides — agents converge, you choose

## Open Questions

- **License:** MIT seems right. Any reason not to?
- **Package registry:** npm? PyPI? Or just a GitHub repo with copy-paste instructions?
- **Name collision:** Check if `agent-debate` is taken on npm/PyPI before committing to the name.
