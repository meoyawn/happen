# Session traces

Tracing is always recorded locally. The server writes `telemetry.sqlite` and
desktop writes `telemetry-desktop.sqlite`, separately from session history and
desktop state. Each database has a dedicated writer isolate, WAL, prepared
inserts and bounded transaction batches. Trace writes never trace themselves.

Desktop creates the trace identity before sending a prompt. Explicit carriers
cross the desktop/server WebSocket and every worker mailbox. Storage statements,
agent execution and model HTTP/WebSocket operations inherit that identity.
Responses return it to desktop event application and frame presentation.
Queued prompts retain their identity when execution begins later.

The context window exports a standard Chrome Trace Event JSON document,
readable by Perfetto and other trace viewers. Export pages both databases into
an atomic file without loading the whole session into the UI isolate. Each
source's sequence boundary is frozen during export. Running spans remain open:
the document is a snapshot, not a signal to stop the session.

Recorded data includes operation names, SQL templates, timings, HTTP status,
stream/chunk sizes, model event types, retries, transport flows, backpressure,
disconnects and scrubbed error details. Prompt/output content, SQL bindings,
credentials, HTTP headers and URL query strings are excluded. Traces are
retained across restarts; export does not clear them.

This uses SQLite for local storage and Chrome JSON for interchange. OTLP is a
collector transport, not a storage engine; exporting a session requires no
collector or external service. OpenCode's request spans and model transport
lifecycle instrumentation informed the design. Happen also records each SQL
operation and propagates context across desktop and worker boundaries.
