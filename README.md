# agent-debate

<p align="center">
  <img src="assets/banner.png" alt="agent-debate banner" width="700">
</p>

AI agents debate your technical decisions — then you make the call.

Two or three agents (Claude, Codex, Gemini) edit a shared markdown file in-place. They strikethrough to disagree, cite `file:line` as evidence, track disputes in a log, and must converge or escalate. It's adversarial code review, not a chatbot.

## What a debate looks like

Here's a real excerpt from a [3-agent debate on adding OpenRouter support](debates/1-2026-03-07-add-openrouter-support.md) (Claude vs Codex vs Gemini):

```markdown
~~Why a wrapper: Dependencies are just `curl` + `jq`, both standard
on macOS/Linux. [A1-R1]~~
Wrapper is correct, but `jq` is unnecessary dependency surface for v1.
Evidence: repo currently has no `jq` dependency, while `python3` is already
required by orchestrator (`orchestrate.sh:139,445,492,753`). Minimum viable
should be a Python wrapper using stdlib `json` + `urllib.request`. [A2-R1]

### Claude accepts Codex's corrections [A1-R2]

**Python wrapper over bash+jq:** Codex is right. Verified: `orchestrate.sh`
already requires `python3` at 4+ callsites. Adding `jq` as a new dependency
when Python stdlib can do the same job is unnecessary. Conceding. [A1-R2]
```

Agents propose, disagree with evidence, and concede when wrong. Every claim is grounded in actual code. The [full debate](debates/1-2026-03-07-add-openrouter-support.md) converged in 1 round with all disputes closed.

## Why not just ask one AI?

- **One agent has blind spots.** A second agent catches what the first missed — wrong assumptions, unnecessary dependencies, missing code paths.
- **Evidence, not vibes.** The protocol forces agents to cite `file:line`, paste log output, and verify each other's claims before agreeing.
- **Scope creep dies here.** Agents must justify every addition. "Easy to add" is not a reason. Unrelated ideas go to a parking lot.
- **You decide, they inform.** Agents converge on a recommendation. You pick what ships.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gumbel-ai/agent-debate/main/install.sh | bash
```

Works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex](https://github.com/openai/codex), and [Gemini CLI](https://github.com/google-gemini/gemini-cli). Install for one agent only with `--agent claude`, `--agent codex`, or `--agent gemini`.

## Usage

Just tell any agent what you want:

```
"Start a debate on whether to use WebSockets or polling. Add Codex too."
```

```
"Continue debate 3 — I disagree with Codex's approach, argue for the simpler solution."
```

```
"Auto debate this auth refactor with Codex and Gemini, max 3 rounds."
```

Two modes:
- **Manual** — you switch between agent terminals, each takes a turn editing the shared file
- **Auto** — orchestrator runs agents round-robin until they converge or hit max rounds. Use `--skip-provider` if you want to participate as one of the agents yourself

## How it works

All agents follow the same [guardrails](agent-guardrails.md):

| Rule | What it means |
|------|---------------|
| **Living document** | Agents edit in-place with ~~strikethrough~~ + counter, not append-only chat |
| **Evidence required** | Every claim must cite file:line, log data, or runtime output inline |
| **Disputes tracked** | Tabular log with OPEN/CLOSED/PARKED statuses |
| **Convergence** | All agents must mark `STATUS: CONVERGED`; any can revert to `STATUS: OPEN` |
| **Scope creep blocked** | New ideas go to Parking Lot unless required for the fix |

## Configuration

Default agents: `opus` (Claude Opus) + `codex` (OpenAI Codex). Built-in aliases:

| Alias | Agent | Effort support |
|-------|-------|----------------|
| `opus` | Claude Opus | low/medium/high |
| `sonnet` | Claude Sonnet | low/medium/high |
| `codex` | Codex | low/medium/high |
| `gemini` | Gemini (auto) | — |

3-agent debates: `--agents opus,codex,gemini`. Override per-project with a `debate.config.json` in your project root. Edit `~/.agent-debate/config.json` to add custom aliases.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/gumbel-ai/agent-debate/main/install.sh | bash -s -- --uninstall
```

## License

MIT
