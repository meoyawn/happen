# "Happen" AI coding agent

## Dev app

`moonx dev` is probably already running, but if it's not feel free to run it yourself for verification

## Rules

- Native changes and incompatible interface or closure-signature changes require
  a cold rebuild and relaunch; do not try to preserve the old live state.
- Do not save one-off operational code, migration scripts, probes, or data repairs
- bias towards dart hot reload and dart mcp for verification. write/run tests ONLY when you can't hot reload and dart mcp the changes (which you almost always can)
