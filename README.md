# agent-debate

<p align="center">
  <img src="assets/banner.png" alt="agent-debate banner" width="700">
</p>

A structured protocol for AI coding agents to debate technical decisions via a shared markdown file. Agents edit a living document in-place — strikethrough to disagree, tag every edit, converge or escalate. The human makes the final call.

This is not a chatbot. It's adversarial code review with convergence rules.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gumbel-ai/agent-debate/main/install.sh | bash
```

This installs the debate protocol into your Claude Code (`~/.claude/CLAUDE.md`), Codex (`~/.codex/AGENTS.md`), and Gemini (`~/.gemini/GEMINI.md`) global configs, plus a shared config at `~/.agent-debate/config.json`. Install for one agent only with `--agent claude`, `--agent codex`, or `--agent gemini`.

## Usage

Just tell any agent what you want in plain English. Here are real examples:

### Start a debate from any agent

> **On Claude:** "I found a race condition in the auth module. Start a debate on how to fix it, and add Codex and Gemini too."

> **On Codex:** "I think we should use WebSockets instead of polling. Start a debate on this — add Claude to the debate too."

> **On Gemini:** "Let's debate whether to split the monolith into microservices. Add Claude and Codex."

The agent creates a debate file in `./debates/`, writes the opening proposal, and stops. The other agents respond when you tell them to.

### Continue an existing debate

> **On Codex:** "Continue debate 3."

> **On Claude:** "I don't agree with Codex's approach in debate 3. Continue it and argue for the simpler solution."

The agent reads the debate file, responds in-place per the protocol, and stops. Keep alternating until they converge or you've seen enough to decide.

### Run a fully automated debate

> **On any agent:** "Start a debate on whether to migrate from REST to GraphQL. Run it in auto mode for 5 rounds."

> **On Claude:** "Auto debate this auth refactor with Codex and Gemini, max 3 rounds."

The orchestrator handles all agent invocations, round-robin turns, and convergence detection automatically.

## Configuration

The installer ships a default config at `~/.agent-debate/config.json` with built-in agent aliases:

| Alias | Agent | Transport | Effort support |
|-------|-------|-----------|----------------|
| `opus` | Claude Opus | arg | `--effort` (low/medium/high) |
| `sonnet` | Claude Sonnet | arg | `--effort` (low/medium/high) |
| `codex` | Codex | arg | `-c model_reasoning_effort` (low/medium/high) |
| `gemini` | Gemini (auto) | arg | none |

Default pair: `opus` + `codex`. Claude and Codex aliases default to `medium` reasoning effort. Gemini CLI has no effort flag. Override per-project by placing a `debate.config.json` in your project root.

### Custom agent pairs

Edit `~/.agent-debate/config.json` to add aliases or change defaults:

```json
{
  "aliases": {
    "opus": {
      "name": "Opus",
      "command_template": ["claude", "-p", "--model", "opus", "--effort", "{EFFORT}"],
      "reasoning": { "default": "medium", "allowed": ["low", "medium", "high"] },
      "prompt_transport": "arg"
    },
    "codex": {
      "name": "Codex",
      "command_template": ["codex", "exec", "-c", "model_reasoning_effort=\"{EFFORT}\""],
      "reasoning": { "default": "medium", "allowed": ["low", "medium", "high"] },
      "prompt_transport": "arg"
    }
  },
  "debate": {
    "default_agents": ["opus", "codex"],
    "min_agents": 2,
    "max_agents": 3
  }
}
```

- Gemini alias defaults to CLI auto-routing (Gemini 3 family). You can still try `alias:model` overrides when your local Gemini CLI supports that model ID.
- `{EFFORT}` in `command_template` gets replaced with `reasoning.default` value.
- In host sessions, if your own provider is in the lineup, run host-direct rounds and call orchestrator with `--skip-provider <host>` so it runs only the other providers.

3-agent debates are supported. Use `--agents opus,codex,gemini` to include a third agent.
Use `--skip-provider claude|codex|gemini` for host-direct rounds when that provider is participating in the same host session.

## How It Works

Both agents follow the same [guardrails](agent-guardrails.md) — rules for how to edit the shared document:

- **Living document** — agents edit in-place with strikethrough + counter, not append-only chat
- **Evidence required** — every claim must cite file:line, log data, or runtime output inline
- **Disputes tracked** — tabular log with OPEN/CLOSED/PARKED statuses
- **Convergence** — all agents must mark `STATUS: CONVERGED`; any can revert to `STATUS: OPEN`
- **Scope creep resistance** — new ideas go to Parking Lot unless required for the fix

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/gumbel-ai/agent-debate/main/install.sh | bash -s -- --uninstall
```

## License

MIT
