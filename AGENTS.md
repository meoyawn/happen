# "Happen" AI coding agent

This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.

## Rules

- Never use Python. Use Dart for everything.
- Never use `mise exec`. Run project commands through named `moon.yml` tasks.
- No legacy. Delete obsolete code
- Test widgets offscreen. Never interrupt the human's work
- `moonx dev` is probably already running; verify changes through dart mcp: hot reloading and probing it. You seldom should write and run tests because of that

## State machines

- Prefer native Dart state machines: sealed immutable states with state-specific
  payloads and a pure `switch ((current, next))` declaring allowed transitions.
  Keep state private; reject invalid transitions.
- Owner methods handle events and run async effects. Cancellation is an event
  whose effect cancels the operation's token; ignore stale completions.
- Keep I/O, including SQLite, in effects. Model pending writes, success and failure
  explicitly; acknowledge persistence after commit. Persist durable data, not
  tokens or resource handles. Authoritative data stays with its owner; caches
  remain disposable.
