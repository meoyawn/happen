# "Happen" AI coding agent

pack

## Rules

- Never use Python. Use Dart for everything.
- No legacy. Delete obsolete code
- OpenCode is a moving target. Compare against the current HEAD of `/Users/meoyawn/Developer/github/opencode`, not a pinned version. Keep capture revisions and hashes only as evidence; preserve strict checks.
- Test widgets offscreen. Never interrupt the human's work
- `moonx dev` is probably already running; verify changes through dart mcp: hot reloading and probing it. You seldom should write and run tests because of that
