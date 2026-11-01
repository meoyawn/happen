# "Happen" AI coding agent

## Dev app

`moonx dev` is probably already running, but if it's not feel free to run it yourself for verification

## Rules

- **No legacy. Delete obsolete code.** Support only the current design and
  contract. When behavior, APIs, or stored formats change, remove the replaced
  implementation and its obsolete tests. Do not add compatibility shims,
  fallback paths, dual formats, legacy flags, or migrations to preserve old
  behavior or state. Delete instead of carrying it forward.
- **Ask the human before restarting the app.** If changes cannot be hot
  reloaded, explain why and ask for explicit permission before stopping,
  hot restarting, cold rebuilding/relaunching, or replacing the running app.
  A request to implement a feature is not permission to restart. Finish the
  changes and all possible verification first, and keep the app running until
  the human approves that restart. Do not launch a second app instance to
  bypass this requirement.
- Native changes and incompatible interface or closure-signature changes require
  a cold rebuild and relaunch after the human approves; do not try to preserve
  the old live state across that rebuild.
- Do not save one-off operational code, migration scripts, probes, or data repairs
- **Test widgets offscreen. Never interrupt the human's work.** Run interactive
  widget verification in isolated, offscreen Flutter widget tests. The running
  desktop app is the human's workspace, not a test harness. Never inject keys,
  type or replace drafts, change focus, click, scroll, navigate, resize windows,
  open test overlays, or submit messages there for verification. Saving and
  restoring state afterward does not make these actions acceptable.
- Use Dart hot reload and read-only Dart MCP inspection to check the running
  app. Exercise keyboard handling, autocomplete, editing, focus, and other
  interactions in offscreen widget tests, including their real widget/action
  paths. Do not launch another desktop app instance for testing. If a check
  genuinely requires interacting with the human's live workspace, finish all
  offscreen verification first and ask for explicit permission.
