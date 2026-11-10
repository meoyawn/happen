# Shell snapshot port

The apply-patch port and test applicability ledger are documented in
[APPLY_PATCH_UPSTREAM.md](APPLY_PATCH_UPSTREAM.md).

Modified Dart port of OpenAI Codex, Copyright 2025 OpenAI, Apache-2.0.
Source revision: `ddd1812a51f4aded35c3ec5446672474d5cb546b` in
`/Users/meoyawn/Developer/github/codex`. Paths below are relative to `codex-rs/`.
See [license](../openai/tools/CODEX-LICENSE) and
[notice](../openai/tools/CODEX-NOTICE).

The production sources are `shell-command/src/startup.rs`,
`shell-command/src/shell_snapshot{,_capture,_render}.rs`, and
`exec-server/src/shell_snapshot{,_file,_process}.rs`.
`lib/src/shell_snapshot_scripts.dart` retains their native shell serialization.
`lib/src/shell_snapshot.dart` adapts capture ownership, in-memory caching and
replay to Dart's existing process supervisor. `openai/lib/src/tools.dart` owns
speculative warmup and selected-cwd eligibility.

## Test ownership and baseline

`../../test/shell_snapshot_test.dart` exercises the actual OpenAI tool runtime
in subprocesses with private startup files, HOME and environment. Its compiled
host is `../../test/fixtures/shell_snapshot_host.dart`. There are no test-only
production exports or injected shell-state implementations.

The initial Bash, Zsh and sh state-restoration ports failed against the unchanged
runtime with exit 127: the startup-defined function was unavailable. They were
written before the implementation. Tests check observable command output, real
process lifetimes, capture side effects, stdin, exit status and concurrent replay;
they do not assert implementation source or timing performance.

## Applicability ledger

| Upstream test | Dart treatment |
| --- | --- |
| `shell-command/src/shell_snapshot_tests.rs`: `snapshot_capture_requires_marker_and_complete_records` | Adapted at the runtime boundary: incomplete/nonzero/oversized captures retain ordinary login fallback; no parser-only public seam. |
| `snapshot_capture_selects_declarations_and_environment` | Adapted: V2 captures native state and environment without credential declarations. Declaration and broker variants are excluded; current execution metadata is checked through real replay. |
| `bash_snapshot_filters_invalid_exports`, `bash_snapshot_preserves_multiline_exports` | Adapted: native shell serialization and UTF-8/NUL-delimited environment transport; multiline values and metadata exclusion are asserted through commands. Legacy declaration rendering is excluded. |
| `snapshot_environment_preserves_native_path_exports_and_shell_level`, `sh_declarations_preserve_path_export_state` | Native `env -0` serialization is retained. Declaration-only, V1 export-attribute rendering is excluded. Tied PATH and executable resolution are checked at replay. |
| `posix_startup_path_expansion_preserves_supported_forms` | Ported at actual sh startup: all ten upstream path forms, unset/empty/set defaults, missing variables and injection rejection. |
| `zsh_literal_bytes_match_native_modifiers` | Excluded: it tests the credential scanner's literal decoder. Ordinary snapshots retain native shell source without decoding literals. |
| `zsh_snapshot_checks_functions_before_restoring_quote_options`, `zsh_snapshot_checks_deferred_quote_modes`, `zsh_snapshot_checks_rcquotes_without_changing_alias_behavior` | Their broker credential checks are excluded. Ordinary quote/alias/option parse-order behavior is ported in streamed and concurrent replay tests. |
| `zsh_snapshot_restores_tied_path` | Ported through lookup of a real executable on the startup-configured tied PATH. |
| `streamed_snapshot_preserves_alias_and_option_parse_order` | Ported through actual Bash/Zsh replay, including shadowing functions, RC_QUOTES and aliases. V1 replay is excluded. |
| All `brokered_*` cases in `shell-command/src/shell_snapshot_tests.rs` | Excluded: Happen has no managed network credential broker, dummy credentials, credential alias scanner or credential policy overrides. No replacement broker API is introduced. |
| `exec-server/src/shell_snapshot_tests.rs`: `snapshot_failure_retries_are_bounded_and_single_flight` | Ported: real failed captures, concurrent callers, retry backoff, recovery on attempts 1–3, exhaustion, and failed-prewarm release without consuming command attempts. Codex-only telemetry assertions are excluded. |
| `snapshot_size_limit_counts_state_and_environment_before_filtering`, `snapshot_replay_size_limits` | Adapted to actual capture/replay: 4 MiB file state, 512 KiB environment replay and bounded capture. No injected parser or synthetic memory metrics. |
| `snapshot_filters_profile_exports_after_capture`, `snapshot_preserves_profile_exports_with_restrictive_inheritance` | Excluded policy variants: Happen has no shell-environment policy schema. Its inherited environment behavior is preserved; per-execution metadata is excluded from captured exports. |
| `snapshot_caches_only_unmanaged_proxy_state` | Excluded: managed network proxy environment is outside Happen's schema. |
| `exec-server/src/shell_snapshot_file_tests.rs`: `unnamed_snapshot_preserves_stdin_and_closes_read_only_carrier` | Adapted to Dart's supervisor: independent readers, preserved stdin, closed carrier before shadowing functions, and original nonzero exit status are checked through pipe and PTY tools. Native CLOEXEC and sandbox-root assertions are excluded; see transport adaptation below. |
| `exec-server/tests/exec_process/shell_snapshot.rs`: `shell_snapshot_preserves_successful_startup_output_and_services` | Ported for Bash/Zsh: redirected startup output completes capture, the initialized service survives validation and a second command uses the same capture. |
| `shell_snapshot_concurrent_replays_keep_independent_readers` | Ported for Bash/Zsh, pipe and PTY, eight concurrent stdin exchanges, 480 KiB functions, source origin, quoting/options, shadowing functions and exit 7. Restricted-sandbox and remote descriptor variants are excluded. |
| `core/tests/suite/shell_snapshot.rs`: `shell_snapshot_v2_warms_after_hooks_without_blocking_the_model` | Adapted: runtime construction prewarms without blocking independent tools; a gated profile is captured once and reused. Happen has no Codex hook lifecycle or shell-secret policy. |
| `shell_snapshot_v2_recovers_after_failed_prewarm` | Adapted in default-shell retry/recovery tests. |
| `shell_snapshot_v2_prewarm_stops_on_shutdown` | Ported through owner cancellation with the real capture shell and its descendant. |
| `shell_snapshot_v2_returns_before_inherited_output_closes` | Ordinary command descendant cleanup is already owned by Happen's process supervisor and cancellation siblings. Snapshot capture itself is checked with a startup descendant retaining stdout. |
| `shell_snapshot_v2_prewarm_preserves_the_sandbox`, `shell_snapshot_v2_prewarm_skips_ineligible_sessions`, `shell_snapshot_v2_does_not_warm_a_hook_stopped_turn`, `shell_snapshot_v2_guardian_uses_its_resolved_permissions_and_tools` | Excluded: Codex trust maps, approval policies, managed networking, hooks and guardian/subagent execution are not Happen features. Non-login commands and alternate cwd eligibility are covered. |
| `shell_snapshot_v2_filters_profile_secrets_without_creating_files`, `unified_exec_snapshot_preserves_shell_environment_policy_set` | Managed/policy filtering is excluded. Cache bytes stay in memory, metadata is per execution, and Happen's existing environment contract remains authoritative. |
| `macos_unified_exec_resolves_command_from_tied_path_snapshot`, `macos_unified_exec_uses_shell_snapshot`, `linux_unified_exec_uses_shell_snapshot` | Adapted to portable real-shell runtime cases and tied executable lookup. Local verification does not claim execution on another OS. |
| `unified_exec_snapshot_still_intercepts_apply_patch` | Excluded: Happen's patch tool is a separate native tool; it does not intercept shell source. Existing patch and command siblings remain authoritative. |
| `legacy_snapshot_omits_filtered_and_overridden_exports`, `shell_snapshot_v2_preserves_legacy_snapshots_for_user_shell`, `shell_snapshot_deleted_after_shutdown_with_skills` | Excluded: no legacy persisted snapshot format or skill-owned snapshot files are introduced. This port has only the current in-memory cache. |
| `windows_unified_exec_uses_shell_snapshot` | Excluded, as upstream: PowerShell/Cmd snapshot capture is unsupported. Ordinary process tools remain available. |
| `core/src/shell_snapshot_tests.rs`: legacy file creation/generation/name parsing, rollout cleanup and section-string tests | Excluded: V1 persisted snapshots are obsolete for this port. Observable V2 restoration is owned by the runtime tests above. |
| `snapshot_shell_does_not_inherit_stdin`, `timed_out_snapshot_shell_is_terminated`, `snapshot_rejects_nul_script_before_execution` | Adapted to stdin, timeout/cancellation process-group cases and existing command argument validation. |
| Remaining `core/src/shell_snapshot_tests.rs` provider context, network sandbox and credential discovery/alias tests | Excluded: V1/provider credential policy machinery absent from Happen. Current inherited environment and ordinary capture/replay are exercised instead. |

## Runtime adaptations

- One cache belongs to one task tool runtime. It has at most 16 entries, keyed
  by shell executable and selected cwd. Concurrent callers share capture.
  Failed commands retry at most three times with one-second backoff; speculative
  failure does not consume the command retry budget.
- Capture has a ten-second deadline, an 8 MiB file-replay bound and a 4 MiB
  environment-replay bound. Native shell state has a 4 MiB file-replay bound;
  environment and env-only replay retain the upstream
  512 KiB bounds. Capture never reads command stdin. Success releases startup
  helpers; failure, timeout and owner cancellation terminate the capture group.
  The supervisor reports exit status separately from shell stdout so redirected
  startup output cannot interleave status bytes with serialized state.
- Dart's existing launcher cannot receive Codex's arbitrary inherited native
  descriptors. A private temporary directory transports each launch's state to
  the existing supervisor, which opens an independent reader and unlinks the
  path before starting the user shell. The sourced prefix closes the carrier
  before restoring functions. This is local process behavior, not a claim of
  Codex's protected sandbox-root or remote-executor transport.
- sh retains the upstream environment replay path and dialect limitations:
  its upstream serializer clears aliases before capture, and function
  serialization requires `typeset -f` or `declare -f`. Alias restoration tests
  therefore belong to Bash/Zsh; Bash-backed sh checks functions and environment.
  ENV expansion uses the upstream non-evaluating resolver. Bash/Zsh skip repeated
  automatic startup during replay. The original requested command, argv
  ownership, stdin, output, PTY status and cancellation remain owned by
  `CommandRunner`.
- PowerShell/Cmd, managed credential brokers, shell environment policy YAML,
  remote executors, hook/trust/guardian workflows and V1 disk snapshots are not
  invented to simulate Codex-only features.

## Verification

Verified on macOS arm64, November 6, 2026, in isolated copies of the dirty
checkout, with private startup files and HOME:

- `test/shell_snapshot_test.dart`: 63 passed, one explicit sh process-substitution
  exclusion. The capture-limit regression also failed against the preceding
  8 MiB environment-capture limit before passing with the upstream 4 MiB limit.
- `test/tool_interfaces_test.dart`, `test/tool_cancellation_test.dart`,
  `test/server_tools_test.dart`, `packages/server/test/command_execution_test.dart`:
  16 passed.
- Scoped analysis of `packages/tool_runtime`, `packages/openai/lib/src/tools.dart`
  and both shell snapshot test files: no issues.
- Dart MCP hot reload succeeded on an isolated backend probe using the final
  runtime source. After changing its startup file, later commands retained the
  captured function, alias and environment, with exactly one startup capture.
  The Zsh `NOMATCH` option remained enabled.

These checks establish the local shell behavior above, not a timing benchmark
or verification on Linux/Windows.
