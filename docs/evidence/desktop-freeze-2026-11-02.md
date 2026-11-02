# Desktop freeze investigation — 2026-11-02

Environment: macOS 26.4 arm64, Flutter 3.47.9
(`c197ca5199e9ee5661e865596c9c07294dfab51c`), Dart 3.13.7, debug/JIT.

## Reproduced application defect

The Context panel's custom `SliverPersistentHeaderDelegate` declared both extents
as 32, but returned an unconstrained row which measured 17 high. Scrolling the
message headers into view produced:

```text
SliverGeometry is not valid: The "layoutExtent" exceeds the "paintExtent".
The paintExtent is 17.0, but the layoutExtent is 32.0.
```

The pre-fix renderer was reproduced in an isolated package snapshot, without
reverting the working tree or touching the running window. The regression test
failed on that geometry error. Flutter's `MouseTracker._deviceUpdatePhase` sets
its debug reentrancy flag before hit testing and resets it only on normal return;
a subsequent hit-test failure can therefore leave mouse input asserting on every
update. The repeating mouse assertion is secondary, not a diagnosis by itself.
See the long-standing [Flutter issue #84241](https://github.com/flutter/flutter/issues/84241).

The panel now uses `PinnedHeaderSliver` with a 32-high child, deriving scroll and
paint extents from the same measured size instead of maintaining a separate
delegate contract. The narrow-panel Raw messages label also flexes instead of
overflowing. No mouse-tracker reset or assertion suppression was added to the app.

Validation from `packages/desktop`:

```sh
flutter test --no-pub test/context_window_test.dart --reporter expanded
```

All seven tests passed, including scrolling, mouse hover, expanding/collapsing
headers across framework reassembly, complete snapshots, and export. Analysis of
the changed Dart files and `git diff --check` passed. Dart MCP hot reload through
the existing launcher's DTD connection succeeded with no runtime errors.

## Separate native crash

Incident `6D2F6193-EC67-490D-B0A6-069829640A7E` killed PID 29733 at
07:03:15 +03:00. Its stack is a Dart VM abort in
`Class::EnsureDeclarationLoaded`, `ClassFinalizer::LoadClassMembers`, and JIT
static-call compilation, not the sliver assertion or a SQLite frame.

Immediately preceding it, the Flutter log recorded a newly added
`ConversationMarkdown.reasoning` field returning null after a hot reload.
The process also had both the original `flutter run` controller and a separate
`flutter attach` controller. Neither observation alone proves the native trigger.
The crash report lacks the VM's stderr identifying the unloaded class, so the
exact triggering class remains unknown. [Dart issue #55235](https://github.com/dart-lang/sdk/issues/55235)
documents a similar hot-reload JIT failure; this is not proof of a new 3.47.9
regression or that the UI fix repairs the VM crash. No application-level
workaround for VM reload state was introduced.

## Interrupted sessions

Both histories remain under `~/.local/share/agent-server/tasks/<id>/history.sqlite`
and both returned `ok` from SQLite `PRAGMA quick_check`:

| Task | Last durable event | Time (+03:00) |
| --- | --- | --- |
| `01a19a59-8de7-7529-94be-dc0453c3a341` (Context UI) | 418, tool started | 07:03:15.565 |
| `01a19a5a-a4df-7507-944f-7503acd1a519` (images/composer) | 397, model started | 07:03:10.923 |

Both are also present in `desktop.sqlite`. Their historical `status: running`
metadata has no terminal event because the process aborted. The restarted server
reported zero active and zero resident task owners, and successfully served both
histories with `running: false`. Thus history and execution ownership are
different: the histories were not lost, but live isolates cannot survive the
embedded process. Startup currently does not resume interrupted turns. The
investigation did not resubmit either turn or manufacture live registry entries.

Follow-up: durable `session.list`/`session.active` discovery and the Inbox's
interrupted-session filter now restore both rows automatically. Dart MCP confirmed
both `inbox:<session-id>` keys in the running app after restart, without creating
live agents. See the durable-session-discovery entry in `docs/decisions.md`.
