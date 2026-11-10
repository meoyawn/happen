# Apply-patch port

Modified Dart port of OpenAI Codex, Copyright 2025 OpenAI, Apache-2.0.
Source: `/Users/meoyawn/Developer/github/codex`, revision
`0598a96e9361485fd4cd02f9c287aca627ad6ee1`.
See [license](../openai/tools/CODEX-LICENSE) and
[notice](../openai/tools/CODEX-NOTICE).

`lib/src/patch_parser.dart` ports the completed-input behavior of
`codex-rs/apply-patch/src/{parser,streaming_parser}.rs`.
`patch_text.dart` ports `seek_sequence.rs`, `file_update.rs`, and `text_file.rs`.
`patch.dart` owns filesystem effects and committed deltas from `lib.rs`.
The previous parser and in-place matching implementation have been removed.

The shared applier commits file operations in order, preserving committed
prefixes on later failure. OpenAI's adapter also requests verification before
effects, corresponding to `invocation.rs::try_verify_apply_patch_args` and the
core apply-patch handler. It checks every source and rejects duplicate source
operations before writing. Changes are computed again during execution, so
verification does not authorize writing from stale source contents.

Context matching follows Codex's pass ordering: exact, trailing whitespace,
surrounding whitespace, then normalized Unicode punctuation. Chunks locate
original source lines; replacements are applied in source order. Explicit
context retains its original text and line ending. Insertions use the first
existing line ending, and updates terminate every remaining line. Pure
addition chunks append at EOF without advancing the source cursor.

Native file previews use one line of diff context. Turn diffs retain their
existing three-line context. Success summaries group additions, modifications,
and deletions, preserve supplied path spelling, and use move destinations.
The direct OpenAI adapter uses that summary instead of reparsing raw input.
Nested Code Mode calls retain their existing empty-object success result.

## Test ownership

[`test/apply_patch_test.dart`](../../test/apply_patch_test.dart) exercises the
shared applier against real temporary files. All 25 upstream scenario
directories are copied unchanged to `test/fixtures/apply_patch`, including
their byte-preserving `.gitattributes`. Tests compare complete file/directory
trees and assert success or failure. No checkout of Codex is needed to run them.

| Upstream coverage | Dart coverage |
| --- | --- |
| `tests/suite/scenarios.rs`, all 25 fixture directories | Every fixture runs against the shared applier; input, patch and expected bytes are unchanged. |
| `tests/suite/tool.rs`: operations, multiple chunks, moves, overwrites, missing files/context, invalid and empty hunks, deletion, trailing newline, partial success | Scenario runner plus summary, path, diagnostic, and committed-delta cases. Overlapping filesystem assertions share the scenario owner. |
| `tool.rs`: CRLF, CR, trailing blank lines, repeated lines/context, mixed endings, missing terminator | Update table asserts exact output bytes. |
| `lib.rs`: add/delete/update/move, relative/absolute paths, interleaved changes | Scenarios and path/summary cases. |
| `lib.rs`: pure addition then removal, Unicode punctuation | Update table; also protects match priority and untouched fuzzy context. |
| `lib.rs`: failed write, failed move removal, unreadable destinations, deleted symlink | Real filesystem and permission cases assert exactness and the committed prefix, including the already-written move destination. |
| `file_update_tests.rs`: all five native unified diffs | Exact independently specified diffs through file-change events, with committed content checked in the delta callback. |
| `seek_sequence.rs`: exact/rstrip/trim/oversized pattern | Application cases, extended with match priority, Unicode quotes/spaces, skip-ahead context and EOF selection. |
| `parser.rs`: boundaries, padded markers, empty updates/chunks, omitted first `@@`, EOF, relative/absolute paths, three heredoc forms and malformed wrappers | Scenario, update and rejection cases at the real filesystem boundary. No test-only parser export. |
| `streaming_parser.rs`: complete-input syntax, indented markers as context, bare empty context, EOF blanks, malformed lines and missing final newline | Completed-input application/rejection cases. Streaming segmentation and partial-progress events are excluded: Happen currently invokes the patch tool after receiving complete arguments. |
| `invocation.rs`: verified paths, unreadable move/add destinations, symlink deletion | Path cases and filesystem cases; the OpenAI adapter enables the same verification before effects. |
| `invocation.rs`: duplicate source operations | Real OpenAI runtime integration test rejects the proposal without writes. |
| `tests/suite/no_follow.rs`: default follows links | Leaf and ancestor symlink updates preserve links and update their target. The opt-in no-follow policy is excluded: Happen has no corresponding filesystem policy or sandbox API. |
| `tests/suite/cli.rs` | Add/update behavior shares the application scenarios and provider contract. Standalone argv/stdin dispatch is excluded: Happen exposes a native tool rather than an `apply_patch` executable. |
| `invocation.rs`: shell detection/interception, PowerShell/Cmd classification, implicit shell invocations | Excluded: the process runtime does not intercept shell source. This port handles the explicit native patch tool. |
| Environment preamble | Empty/duplicate identifiers are rejected by the parser. A valid identifier receives the core handler's single-environment rejection instead of selecting an unsupported environment. |
| Legacy preserve-line-endings environment variable | Excluded. The current line-ending behavior is unconditional. |

[`test/tool_interfaces_test.dart`](../../test/tool_interfaces_test.dart) owns
the Code Mode integration regression: a later invalid chunk reports the missing
text, commits no files, and a corrected call succeeds. It also covers direct
receipts for lenient syntax and duplicate-source verification.
[`packages/server/test/turn_diff_tracker_test.dart`](../server/test/turn_diff_tracker_test.dart)
covers the consumer of committed deltas. Failed writes are conservatively
inexact, as in Codex; the tracker invalidates its diff while committed files
remain on disk.

## Verification

The initial 74 application checks were run before the port: 56 failed,
including eight upstream scenario fixtures. The same 74 passed after the port.
All three new provider integration regressions were also run against the
unchanged pre-port runtime and failed for the intended reasons. The focused
suite passed 114 checks, including all five native diffs, symlinks, cancellation,
provider integration and turn-diff checks:

```sh
dart --disable-dart-dev tool/test_isolated.dart test test/apply_patch_test.dart test/tool_interfaces_test.dart test/tool_cancellation_test.dart test/server_tools_test.dart packages/server/test/turn_diff_tracker_test.dart
```

The real Codex context comparison passed six targeted variants: JavaScript
errors, patch-and-shell, and patch-context recovery, each with ranked discovery
off and on. Each variant exercises both execution orders. The new recovery
contract was then run against the original patch runtime, with only the eager
declaration fix retained: both discovery variants failed specifically on the
missing diagnostic and recovery gates, while Codex passed them. Full request
and shared tool-declaration equality remain strict.

The broader server, instruction-update, MCP-output and unsubscribe/event suites
passed another 39 tests, with one existing unsupported MultiAgentV2 case skipped.
The 100-thread socket test required raising the check process's inherited
256-descriptor soft limit to 4096; the application process and system settings
were unchanged. Scoped analysis and `git diff --check` passed.

Dart MCP reloaded an isolated backend successfully and replayed the three
actual saved JavaScript calls against the saved pre-edit file contents in a
temporary directory. Every patch arrived byte-for-byte unchanged. Both invalid
patches reported their specific missing context and left the files unchanged;
the corrected patch succeeded. MCP reported no runtime errors. The running
desktop release was not restarted or replaced.

Happen retains its existing 1 MiB patch input limit, caller cancellation,
native item events, and committed-delta callback. Filesystem error wrappers use
Dart exceptions; missing context and parser diagnostics carry Codex's messages.
