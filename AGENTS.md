# Environment

- Shell: fish.

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
