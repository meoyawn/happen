# Session traces

Tracing is opt-in for each session. Check **Trace this session** in desktop's
new-session composer before sending the first prompt. New drafts start unchecked;
the choice is saved with each draft and then in the session's configuration.
Reopening a traced session resumes recording. Forks and side chats inherit their
parent's choice and get independent traces. Unchecked sessions send no trace
carrier and record no timings, even while another session is being traced.

Enabled sessions record locally. The server writes `telemetry.sqlite` and desktop
writes `telemetry-desktop.sqlite`, separately from session history and desktop
state. The databases open lazily when tracing is needed. Each has a dedicated
writer isolate, WAL, prepared inserts and bounded transaction batches. Trace
writes never trace themselves.

Desktop creates the trace identity before sending a prompt. Explicit carriers
cross the desktop/server WebSocket and every worker mailbox. Storage statements,
agent execution and model HTTP/WebSocket operations inherit that identity.
Responses return it to desktop event application and frame presentation.
Queued prompts retain their identity when execution begins later.

Each fork starts a separate trace at the fork request, before reading the
parent's snapshot or copying history. Once the child ID is allocated, that
trace is bound to the child, including the earlier preparation spans. The
parent ID is a relationship attribute; its previous traces are not inherited.
This applies to both point-in-time forks and temporary side chats.

Side-chat telemetry follows the same retention as other diagnostic traces.
Closing a side chat cancels its turn and fork preparation, terminates its
workers and in-memory history store, and records disposal in the child's trace.
Its telemetry remains readable after closure and across restarts; keeping
diagnostics does not retain the side conversation or restore its session.

The context window shows whether tracing was enabled and exports a standard
Chrome Trace Event JSON document,
readable by Perfetto and other trace viewers. Export pages both databases into
an atomic file without loading the whole session into the UI isolate. Each
source's sequence boundary is frozen during export. Running spans remain open:
the document is a snapshot, not a signal to stop the session.
Zero-duration transport slices anchor flow arrows in viewers, including when
exporting records captured by earlier versions.

Recorded data includes operation names, SQL templates, timings, HTTP status,
stream/chunk sizes, model event types, retries, transport flows, backpressure,
disconnects and scrubbed error details. Prompt/output content, SQL bindings,
credentials, HTTP headers and URL query strings are excluded. Traces are
retained across restarts; export does not clear them.

This uses SQLite for local storage and Chrome JSON for interchange. OTLP is a
collector transport, not a storage engine; exporting a session requires no
collector or external service. OpenCode's request spans and model transport
lifecycle instrumentation informed the design. Happen also records each SQL
operation and propagates context across desktop and worker boundaries. Codex's
disabled-by-default trace exporter informed the explicit opt-in.
