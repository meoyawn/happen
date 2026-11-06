# Embedded QuickJS code-mode contract

Reference: Codex `5112ce6edeb95f2296a5ffec47dbab4764e65853`, matching
[`docs/codex-port.md`](../../docs/codex-port.md). Upstream paths below are relative
to `codex-rs/code-mode-runtime/`.

Happen keeps QuickJS embedded through Dart FFI. Each OpenAI cell evaluates an
actual async JavaScript module in its own QuickJS context; `CodeSession` owns
yielded cells and merges completed cells' explicit JSON writes. This is an
adaptation of Codex's observable contracts, not a port of its V8 runtime or remote
executor. QuickJS's native source pin is in [native/UPSTREAM.md](native/UPSTREAM.md).

The settlement combinators in `lib/src/settled.dart` retain upstream
`src/runtime/settled.js` with only its engine-specific comment changed. Other
runtime code is a modified Dart/JavaScript implementation. Codex is Copyright
2025 OpenAI, Apache-2.0; see [CODEX-LICENSE](../openai/tools/CODEX-LICENSE) and
[CODEX-NOTICE](../openai/tools/CODEX-NOTICE).

## Applicability and evidence

“Adapted” means implemented for QuickJS with the listed coverage. It does not
mean every upstream case in that family has been ported or independently rerun.

| Contract | Upstream source/cases | Status and Happen evidence |
| --- | --- | --- |
| Async modules, fresh globals, tool metadata | `src/runtime/{globals,module_loader}.rs`; `global_scope_contains_only_allowed_items`, `v8_console_is_not_exposed_on_global_this` | Adapted. `test/tool_interfaces_test.dart` checks module exports, undefined module `this`, sorted metadata and callable names. Complete global reflection and unsupported-import diagnostics remain unverified. |
| Tool input conversion | `src/runtime/callbacks.rs::tool_callback`, `value.rs::v8_value_to_json` | Adapted. Inputs are JSON snapshots at the call site; invalid input throws before admission. The nested-call regression checks mutation isolation, BigInt, cycles, throwing `toJSON`, recovery and actual host inputs. Full coercion/getter ordering remains unverified. |
| MCP and host failures | Tool callback/result contracts; `codex-rs/core/src/tools/handlers/mcp.rs` | Adapted. `test/tool_interfaces_test.dart` preserves complete MCP error/structured/text envelopes and printable rejected host errors. MCP `isError` is separate from promise rejection; exec instructions explain that text is not necessarily JSON. |
| Settlement streaming | `src/runtime/settled.js`, `tests/settled.rs` | Ported JavaScript, adapted Dart harness. All seven upstream cases are in `test/code_mode_settled_test.dart`: settlement ordering; iterables/thenables/duplicates; Map/empty inputs; awaited callbacks; callback errors/early close; identity; termination while pending. |
| Exec/wait, termination, observation ownership | `src/service_contract_tests.rs`; `src/service_tests.rs` | Adapted. `test/tool_interfaces_test.dart` checks incremental output, missing cells, pending host cancellation, concurrent-cell writes and completed success/failure taking precedence over late termination. `test/server_tools_test.dart` covers real server wait, notifications and cold resume. Observer preemption and the full callback lifecycle matrix remain open. |
| Exit and explicit stores | `exit_stops_the_whole_cell_and_preserves_only_prior_writes`, `stored_values_are_shared_between_cells_but_not_sessions`, `storing_undefined_preserves_the_previous_value` | Adapted. `test/code_mode_test.dart` checks JSON snapshots and large stored values; `test/tool_interfaces_test.dart` checks native exit through `finally` and timer callbacks. Full store-key conversion, failure/termination writes and session isolation matrices remain unverified. |
| Notifications and timers | `src/runtime/{callbacks,timers}.rs`; notification/cleanup cases in `src/service_contract_tests.rs` | Adapted. Server coverage exercises notification delivery, awaited timers and discarding unawaited timers. `notify` cleanup cancellation, timer argument conversion, duplicate observers and callback admission ordering need the remaining upstream cases. |
| Output retention, diagnostics and budgets | `src/service_output_collection_tests.rs` | Adapted. `test/code_mode_test.dart` covers byte/item head-tail retention, token budgets and UTF-8 boundaries. Full terminal-diagnostic caps, mixed-media retention and diagnostics across observation budgets remain open. |
| Image/audio/generated-image helpers | `src/service_tests.rs`, `src/service_audio_tests.rs` | Adapted. Helpers emit ordered content items. `test/fixtures/context_contract/cases.dart` contains generated-image/audio vectors; those vectors were not rerun in this change. Full accepted/rejected-input and audio-duration matrices remain open. |
| Interrupts and resource limits | `src/runtime/mod.rs`, service yield-grace cases | Adapted policies. CPU/native cancellation and host cleanup are covered in `test/code_mode_test.dart`. OpenAI cells use 256 MiB, a 1 s budget per native execution slice, 256 KiB source characters, 64 outstanding host calls and 32 uncollected cells. These are Happen limits; complete boundary/platform proof remains open. |
| V8/ICU and native serialization details | Locale/Intl cases; Serde marker/depth regressions | Engine-specific differences. QuickJS has no `Intl`; locale formatting/error strings/global built-ins differ. Serde private markers and its recursion bugs do not apply to Dart's decoder. Do not add V8, ICU shims or Rust-specific guards to claim engine identity. |
| Remote/pending-frontier execution | `execute_to_pending`, `wait_to_pending`, remote/delegate/UI runtime cases | Excluded where they require remote execution, subagents or upstream-only session options absent from Happen. Ordinary embedded lifecycle and cancellation cases remain applicable. |

## Remaining work

- Finish the applicable per-case lifecycle, timer, conversion, store and media
  inventories above. Port those cases before changing the corresponding behavior.
- Compare complete embedded workflows with the actual installed Codex, including
  cancellation/notification ordering, error observation and resume. The focused
  tests below are not a whole-runtime comparison.
- Rerun the complete strict context corpus and platform checks before claiming
  final-source or cross-platform parity. Keep the existing context vectors and
  request-equality assertions intact.

## Verification on November 6, 2026

The input-conversion and late-termination regressions failed on the original
source for the intended reasons. All seven settlement-helper cases first failed
because their globals were absent. After the fixes, **69 checks passed**:

```sh
dart --disable-dart-dev tool/test_isolated.dart test \
  test/code_mode_test.dart test/code_mode_settled_test.dart \
  test/tool_interfaces_test.dart test/server_tools_test.dart \
  test/provider_instructions_test.dart --concurrency 1 -r expanded
dart --disable-dart-dev tool/test_isolated.dart analyze \
  packages/code_mode packages/openai/lib/src/tool_specs.dart \
  test/code_mode_settled_test.dart test/tool_interfaces_test.dart
```

DTD hot reload succeeded. An independent CodeSession in the running app
reproduced the original mutated input and uncatchable serialization failure;
after reload it received the original input and caught BigInt, circular and
`toJSON` errors while continuing execution. Further probes confirmed settlement
streaming, updated MCP/QuickJS/helper guidance in both OpenAI tool modes, and the
expected absence of `Intl`. A late termination request preserved an already
completed error and its prior store. Focused analysis reported no issues and
`git diff --check` passed. All three owned probe sessions were closed. Probes use
separate interpreters without navigating or interacting with the desktop.
