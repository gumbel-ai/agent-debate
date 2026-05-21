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

## Timing

- **Primary logs:** event-driven. The primary should run `watch.sh log "<one-line summary>"` after meaningful actions such as edits, test runs, completed steps, or blockers.
- **Watcher reviews:** interval-driven. Default is every 60 seconds. Override when starting:

  ```bash
  WATCH_INTERVAL=30 ./watch.sh start
  ```

- **Primary checks feedback:** checkpoint-driven. The primary should run `watch.sh check` before claiming completion, before commits, or at natural pause points.

There is no hard interrupt. The watcher writes asynchronously; the primary reads feedback at checkpoints and decides how to act.
