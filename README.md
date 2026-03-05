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

Open any project in Claude Code or Codex and say:

```
start a debate on "Should we migrate from REST to GraphQL?"
```

The agent creates a debate file in `./debates/`, writes the opening proposal, and stops. Switch to the other agent and say:

```
continue debate 1
```

The second agent reads the file, responds in-place per the protocol, and stops. Keep alternating until they converge or you've seen enough to decide.

## Configuration

The installer ships a default config at `~/.agent-debate/config.json` with built-in agent aliases:

| Alias | Agent | Transport | Effort support |
|-------|-------|-----------|----------------|
| `opus` | Claude Opus | arg | `--effort` (low/medium/high) |
| `sonnet` | Claude Sonnet | arg | `--effort` (low/medium/high) |
| `codex` | Codex | arg | `-c model_reasoning_effort` (low/medium/high) |
| `gemini` | Gemini 2.5 Pro | arg | none |

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
      "command_template": ["codex", "exec"],
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

- `{MODEL}` in `command_template` supports runtime model overrides (e.g., `gemini:gemini-2.5-flash`).
- `{EFFORT}` in `command_template` gets replaced with `reasoning.default` value. Only Claude CLI supports `--effort` currently.

3-agent debates are supported. Use `--agents opus,codex,gemini` to include a third agent.

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
