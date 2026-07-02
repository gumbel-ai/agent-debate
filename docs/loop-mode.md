# Loop Mode

Loop mode lets one model work as the primary agent while another model reviews progress in the background. It is for long-running coding sessions where the primary may drift from the original task, skip verification, or miss a risk.

New here? Read [How Loop Mode Works](how-loop-mode-works.md) first — this page is the full reference.

It works in both directions: when Claude Code is the primary, Codex reviews by default; when Codex is the primary, Claude (Opus) reviews by default. Override with `--reviewer <alias>` — aliases: opus, sonnet, codex, gemini (copilot is debate-only: its CLI emits JSON that loop mode does not parse).

## Start and Stop

From a supported agent session, in any project (the system installs globally), say:

```text
loop mode on
```

(or "start loop mode"). The agent runs `./loop.sh start --task "<task statement>"` if the repo script exists, otherwise `~/.agent-debate/loop.sh start --task "..."`. The `--task` statement is what the reviewer judges the work against. If the user has not stated the task yet, start anyway — the task statement evolves automatically (see below), and the completion gate blocks until one exists.

To stop:

```text
loop mode off
```

(or "stop loop mode" / "switch off loop mode" / "shut down loop mode").

The agent runs `loop.sh stop`, stops the background loop, and archives the session under `.agent-debate/loop/archive/`.

## How It Works

Loop mode stores project-local runtime files under `.agent-debate/loop/`:

- `journal.md` — primary agent activity notes
- `feedback.md` — reviewer feedback
- `state.json` — machine-readable state
- `loop.pid` — background reviewer process
- `archive/` — stopped-session snapshots

Each pass, the reviewer receives:

- the task statement
- new `journal.md` entries since its last pass
- `git status --short` and `git diff HEAD --stat` (staged + unstaged)
- the actual changed content (`git diff HEAD`, capped at 20 KB)
- its own recent feedback, so it does not repeat itself

The reviewer runs inside the project directory and is told it may read files to verify a concern. If it sees a concrete issue, it appends at most one concise note to `feedback.md`; otherwise it returns `NO_FEEDBACK`. A pass is skipped entirely (no model call) when nothing changed since the previous pass. If the reviewer CLI fails, the failure is recorded once as a `[loop-system]` note (not repeated), and the loop backs off while failures continue; system notes never block the completion gate.

When started from Claude Code or Codex, loop mode also installs project-local hook entries for the active session:

- Claude Code: `.claude/settings.local.json` gets a `Stop` hook that blocks once per turn when actionable feedback is unread, a `PreToolUse` hook that gates `TaskUpdate`/`TodoWrite` completion, and a `PreToolUse` hook that gates `git commit`.
- Codex CLI: `.codex/hooks.json` gets the `Stop` hook and a `PreToolUse` hook that gates `update_plan` when a new task is marked completed. Codex may require reviewing and trusting the project hooks with `/hooks` before they run.

Hooks installed mid-session may need a session restart or `/hooks` review before the host agent enforces them — `loop.sh start` prints a reminder. Codex gates project hooks behind trust: review them with `/hooks`, or set `bypass_hook_trust=true` in Codex config.

`loop.sh stop` removes only the hook commands that loop mode installed and preserves unrelated settings.

## Evolving Task Statement

The task statement is a single field that keeps evolving as the user talks:

- A `UserPromptSubmit` hook (installed on both Claude Code and Codex) appends every user utterance to the journal as a `user:` entry — flattened to one line, truncated at 500 characters; slash commands and empty prompts are skipped.
- Each reviewer pass, if new `user:` entries exist since the last distillation, the loop first makes one small model call that rewrites the task statement from the current statement plus the new utterances (preserving standing constraints), stores it in state, and logs a `task(auto):` journal entry. If the utterances do not change the task, the model answers `NO_CHANGE` and the statement stays.
- The primary agent can still set the statement explicitly at any time with `loop.sh task "..."` — useful at start or on a clean pivot.
- The reviewer therefore judges against current intent even across many tasks in one session, and it also sees the raw `user:` lines in the journal delta, so it can flag drift between what the user asked and what the code does.

## Idle Auto-Stop

Forgotten sessions shut themselves down. The loop tracks activity — journal writes (user prompts, intents, logs, dispositions) and repo changes — and when nothing has happened for `LOOP_IDLE_TIMEOUT` seconds (default 7200 = 2 hours, `0` disables), it removes its hooks, archives the session, and exits. Override at start:

```bash
LOOP_IDLE_TIMEOUT=14400 ./loop.sh start
```

## Timing

- **Primary logs:** the primary records ledger context. Before completing a todo/task, run `loop.sh intent "<what + why + expected validation>"`. Optional `loop.sh progress "..."` and `loop.sh outcome "..."` entries give the reviewer more context. `loop.sh log "<one-line summary>"` remains available for free-form notes, and `loop.sh task "..."` updates the task statement.
- **Reviewer passes:** interval-driven. Default is every 60 seconds (unchanged sessions are skipped without a model call). Override when starting:

  ```bash
  LOOP_INTERVAL=120 ./loop.sh start
  ```

- **Primary checks feedback:** hook-backed checkpoints. The task/todo hook calls `loop.sh gate`, which exits `2` if no task statement is set, if there is no `intent:` entry since the last successful completion checkpoint, or if actionable reviewer feedback has not been dispositioned. Use `loop.sh check` to read unread feedback (this marks it as *seen*), then `loop.sh feedback accept|deny|park "<reason>"` to record a disposition. A disposition only acknowledges feedback you have actually seen — notes appended after your last `check` stay unread.
- **Stop checkpoint:** the Stop hook blocks the end of a turn once (exit 2) when actionable feedback is unread, so the primary reads it before finishing. It does not re-block the continuation turn.

## Escape Hatches

- `loop.sh bypass "reason"` — the next ledger gate passes once without checks (logged to the journal).
- `LOOP_LEDGER_OFF=1` in the host CLI's environment disables the gate for the session (works only if set when the host agent was launched, since hooks inherit that environment).

Gemini and Copilot are outside loop-mode hook support for v1.
