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

The watcher reads new `journal.md` entries, `git status --short`, and `git diff --stat`. If it sees a concrete issue, it appends feedback to `feedback.md`; otherwise it returns `NO_FEEDBACK`.

When started from Claude Code or Codex, watch mode also installs project-local hook entries for the active session:

- Claude Code: `.claude/settings.local.json` gets an advisory `Stop` hook, a `PreToolUse` hook that gates `TaskUpdate` completion, and a `PreToolUse` hook that gates `git commit`.
- Codex CLI: `.codex/hooks.json` gets an advisory `Stop` hook and a `PreToolUse` hook that gates `update_plan` when a new task is marked completed. Codex may require reviewing and trusting the project hooks with `/hooks` before they run.

`watch.sh stop` removes only the hook commands that watch mode installed and preserves unrelated settings.

## Timing

- **Primary logs:** the primary records ledger context. Before completing a todo/task, run `watch.sh intent "<what + why + expected validation>"`. Optional `watch.sh progress "..."` and `watch.sh outcome "..."` entries give the watcher more context. `watch.sh log "<one-line summary>"` remains available for free-form notes.
- **Watcher reviews:** interval-driven. Default is every 60 seconds. Override when starting:

  ```bash
  WATCH_INTERVAL=30 ./watch.sh start
  ```

- **Primary checks feedback:** hook-backed checkpoints. The task/todo hook calls `watch.sh gate`, which exits `2` if there is no `intent:` entry since the last successful completion checkpoint, or if watcher feedback has not been dispositioned. Use `watch.sh feedback accept|deny|park "<reason>"` to record a disposition and advance the feedback cursor. `watch.sh check` prints unread feedback but does not mark it handled.

Hook enforcement is intentionally coarse. It checks before todo/task completion and before Claude-run `git commit`, avoiding per-tool logging noise. The Stop hook is advisory and does not write mandatory ledger entries or block the turn. Gemini and Copilot are outside watch-mode hook support for v1.
