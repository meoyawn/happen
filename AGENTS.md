# Environment

- Shell: fish.

# Dart and Flutter hot reload

- Never fix or work around Dart/Flutter hot-reload bugs in application code.
  Do not change architecture, APIs, state, or resource lifetimes to accommodate
  a broken live process.
- Before changing product code for a crash observed after hot reload, reproduce
  it in a fresh process built from the current source. A successful reload does
  not prove that the live process is valid.
- If the failure occurs only after hot reload, report the evidence and use a
  cold rebuild and relaunch. Do not add compatibility shims, defensive wrappers,
  retries, or lifecycle machinery for it.
- Native changes and incompatible interface or closure-signature changes require
  a cold rebuild and relaunch; do not try to preserve the old live state.

# Working in this repository

- Do not run `dart format`. Preserve existing formatting when editing Dart files.
- Read and follow [the technical decision log](docs/decisions.md) before changing
  architecture or interfaces.
- Record technical decisions in that log, not in AGENTS.md. Include supporting
  evidence, reproduction commands, environment, tradeoffs, and remaining uncertainty.
- Consult the pinned upstream source before changing a compatibility contract.
  Advertise only implemented capabilities.
- Never print authentication tokens or include them in telemetry or history.
- Do not save one-off operational code, migration scripts, probes, or data repairs
  in the repository. Use Dart MCP or temporary tooling outside the repository for
  ad hoc work, including one-time updates to existing tasks. Keep checked-in code
  focused on lasting product behavior and reusable verification.
