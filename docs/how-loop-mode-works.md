# How Loop Mode Works

One agent codes. A second model reviews it in the background. The coder cannot claim "done" while review feedback sits unread.

**Start:** Say "loop mode on". The coding agent (Claude or Codex) becomes the primary; the other model becomes the reviewer. A background loop starts, and runtime files appear in `.agent-debate/loop/`: `journal.md` (activity log), `feedback.md` (reviewer notes), `state.json` (task + cursors).

**You just talk.** A hook journals every message you type. The loop distills them into a single evolving task statement — give the task late, change it 10 times, it stays current.

**Every 60 seconds, the reviewer:**

1. Skips if nothing changed — no cost.
2. Otherwise reads the task statement, new journal entries, and the actual `git diff`.
3. Replies `NO_FEEDBACK`, or writes one short note with file:line evidence.

**The coder is gated.** Before completing a todo, committing, or ending a turn, hooks require: a task statement, a logged `intent` ("what + why + how I'll validate"), and no unread feedback. Feedback must be read (`check`) and dispositioned (`accept|deny|park "reason"`) — you can't ack what you haven't read.

**Stop:** Say "loop mode off" — hooks removed, session archived. Forgot? It shuts itself down after 2 hours of inactivity.

For commands, timing, configuration, and internals, see [Loop Mode reference](loop-mode.md).
