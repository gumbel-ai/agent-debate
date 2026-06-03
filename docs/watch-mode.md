# Watch Mode

Watch mode lets one model work as the primary agent while another model reviews progress in the background. It is for long-running coding sessions where the primary may drift from the original task, skip verification, or miss a risk.

## Start and Stop

From a supported agent session, say:

```text
start watch mode
```

The agent runs `./watch.sh start` if the repo script exists, otherwise `~/.agent-debate/watch.sh start`.

To stop:

```text
stop watch mode
```

The agent runs `watch.sh stop`, stops the background loop, and archives the session under `.agent-debate/watch/archive/`.

## How It Works

Watch mode stores project-local runtime files under `.agent-debate/watch/`:

- `journal.md` — primary agent activity notes
- `feedback.md` — watcher feedback
- `state.json` — machine-readable state
- `loop.pid` — background watcher process
- `archive/` — stopped-session snapshots

The watcher reads recent `journal.md` entries plus `git diff --stat`. If it sees a concrete issue, it appends feedback to `feedback.md`; otherwise it returns `NO_FEEDBACK`.

When started from Claude Code or Codex, watch mode also installs project-local hook entries for the active session:

- Claude Code: `.claude/settings.local.json` gets a `Stop` hook that logs/checks once per turn, plus a `PreToolUse` hook that gates `git commit`.
- Codex CLI: `.codex/hooks.json` gets a `Stop` hook that logs/checks once per turn. Codex may require reviewing and trusting the project hook with `/hooks` before it runs.

`watch.sh stop` removes only the hook commands that watch mode installed and preserves unrelated settings.

## Timing

- **Primary logs:** hook-backed plus optional manual notes. The Stop hook records a turn-completed entry. The primary can still run `watch.sh log "<one-line summary>"` after meaningful milestones to give the watcher better context.
- **Watcher reviews:** interval-driven. Default is every 60 seconds. Override when starting:

  ```bash
  WATCH_INTERVAL=30 ./watch.sh start
  ```

- **Primary checks feedback:** hook-backed checkpoints. Hooks call `watch.sh check --strict`, which exits `2` on unread watcher feedback or a stale watcher loop and exits `0` silently when clean. Non-strict `watch.sh check` remains available for manual feedback checks.

Hook enforcement is intentionally coarse. It checks once per turn and before Claude-run `git commit`, avoiding per-tool logging noise. Gemini and Copilot are outside watch-mode hook support for v1.
