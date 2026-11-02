# Desktop pending message actions

Environment: macOS arm64, Dart 3.13.7, Flutter desktop debug process.
Happen base: `ee62e89badfbd70f23d95027011dc37c60a013c8`, with existing local changes.
OpenCode current HEAD when inspected and rechecked:
`bbd08b61de3094e6576825dcc5b2e6e45921a0af`.
These revisions identify the observation; neither is a compatibility pin.

Compared `packages/session-ui/src/message/message-content.tsx`,
`packages/app/src/session/composer/region.tsx`, and
`packages/schema/src/session-event.ts` in the OpenCode checkout.
The delivery notification uses OpenCode's exact
`session.inbox.delivery.changed` name and inbox reference fields.

Implemented Move to queue and Delete for pending steering; queued messages offer
Steer during execution or Send when idle, plus Delete. Copy remains available
for text. Pending controls remain visible without hover, including attachment-only
messages, and disable during a mutation. Errors use the existing conversation
error display and preserve pending inputs.

Validation:

- `dart test test/session_model_test.dart test/server_test.dart --reporter expanded`:
  all 21 tests passed. The fixtures use a local HTTP provider, without a real model
  or external credentials.
- Tests exercise actual WebSocket mutations, SQLite reopen, cancellation of one
  prompt during a blocked response, queue-to-steer delivery, an idle session's
  Send operation, and rejection after an input starts or is delivered.
- The session writer test checks stale offers after deletion and delivery changes,
  duplicate offers, attachments, and reasoning selection. Deleted or queued input
  cannot enter the model buffer through a stale steering offer.
- Dart MCP hot reload succeeded. Separate offscreen render trees in the live VM
  verified Move to queue, Delete, Steer, Send, and file-only pending messages at
  a 240-pixel viewport. Button callbacks dispatched the expected action; both
  mutation controls disabled while awaiting completion. These probes did not
  change the selected session, visible widget tree, or window focus.
- Targeted `dart analyze` completed without errors or warnings; existing
  informational diagnostics remain. `git diff --check` passed.

Scope: pending input controls. Delivered-message rewind/fork and the upstream
composer queue's editing/reordering interface are outside this change.
