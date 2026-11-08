# MCP client and Events draft

This package connects configured MCP servers from Happen's shared network
isolate. It implements the experimental
[MCP Events proposal](https://github.com/modelcontextprotocol/experimental-ext-triggers-events),
separately from the core MCP protocol; no plugin system is involved.

## Core transports and configuration

Core stdio/Streamable HTTP behavior and ordinary OAuth follow Codex, not its
ChatGPT connectors, enterprise-managed authorization or plugins.

- Global config is `~/.config/happen/config.yaml` (or `--config`).
- Project MCP config uses `.happen/config.yaml` layers from repository root to
  the thread's cwd. As in Codex, tables merge recursively and arrays/scalars
  replace; explicit relative `cwd` values resolve beside their config file.
  Only MCP settings are reloaded from project files.
- Equivalent stdio launches share one process across names, threads and config
  scopes, including equivalent global/local declarations and legacy peers.
  Identity includes command/arguments, effective cwd/environment and executable
  generation, not the server's display name. Catalog namespaces and cancellation
  remain binding-local. Config retains ownership after a client disconnects.
- `threadId` on MCP inventory/status/auth/events requests selects that saved
  thread's cwd without loading or subscribing to the thread. Desktop status,
  resource discovery and auth requests carry the selected project's cwd.
  Requests without a thread or cwd see global config only. Internal agent
  catalog/call/resource requests carry cwd.
- Invalid reloads retain the last accepted connections and expose a sanitized
  `config_error` on inventory. Removing a project layer restores inheritance.
- Modern stdio messages, HTTP JSON bodies and SSE events use Codex's 8 MiB wire
  bound. Legacy local/HTTP codecs retain their uncapped wire behavior; IPC,
  catalog and model-facing output budgets remain separate. A discovery timeout
  alone never authorizes a legacy handshake on the same process.
- Codex timeouts apply on the server-owned path used by desktop: startup gets
  30 seconds across discovery, fallback and retries; ordinary operations default
  to 300 seconds; collecting a catalog gets one 30-second deadline across all
  pages and retries. Tool callers may shorten the 300-second budget. Proactive
  OAuth preparation has its own deadline and precedes the operation clock;
  caller input pauses only its own operation. A timed-out call leaves the shared
  connection available. Explicitly unbounded raw streams still obey cancellation.
- Modern HTTP redirects are rejected with their status. Legacy requests follow
  at most ten same-origin redirects; cross-origin destinations are never
  contacted. Authentication challenges preserve scope/error distinctions and a
  rejected tool call is not replayed during credential repair.
- Stdio inherits Codex's core environment and nonempty CA bundle variables.
  Inherited relative CA paths resolve against the host launch cwd; explicit
  `env` overrides stay literal and replace CA casing variants. Host-only
  workload/identity and process-control credentials are scrubbed even from
  explicit overrides. This same effective environment keys process sharing.
- On macOS/Linux, stdio launch atomically establishes an owned process group
  and excludes unrelated descriptors. Final ownership release cleans up the
  group even if a wrapper exits first. Stderr remains a separate, bounded local
  diagnostic stream; teardown drains queued diagnostics without waiting forever
  for an escaped descendant's EOF.

OAuth discovery uses GET without initializing an MCP session. Same-origin
metadata redirects are bounded; cross-origin redirects are rejected before
contact. Resource headers remain on their origin. Metadata issuer, endpoint,
callback state/issuer, PKCE and refresh-issuer checks precede credential exchange.
Tokens remain outside config and history in private server-owned files.
Pasted and loopback callbacks reject ambiguous parameters before consuming a
login, so an invalid callback cannot discard a later valid response. OIDC
fallback preserves terminal failures and shares one discovery deadline. DCR
redirects retain the original time/body bounds and do not forward resource-only
headers to another origin; code/token exchanges are never redirect-replayed.
Confidential DCR replies that omit their auth method negotiate Basic/Post from
the discovered metadata and retain that choice for refresh. Codex's two
provider-compatibility exceptions require the exact HTTPS issuer and both
endpoint origins; hostname suffixes and different issuer paths do not qualify.
Credential transactions serialize across owners, isolates and processes. Unix
uses descriptor-owned locks; lock acquisition has its own 60-second budget,
separate from provider timeouts. A failed read/save cannot publish new or empty
runtime authority. Logout waits for admitted refresh, and a bound replacement
login is preserved without replaying the rejected tool call. JSON formatting
alone does not create a new credential generation.

## Continuations and caller input

`McpConnection.request` preserves raw protocol results when no handler is
provided. `requestWithInput` and the manager's high-level operations use one
continuation driver. An explicit `McpInputHandler` receives validated raw form,
URL, rich-form, or native verification requests and a caller cancellation token.
Advertise only the capabilities the host can serve (`mcpInputCapabilities` is
available to capable hosts); roots and sampling are not synthesized.

Each operation has its own active-time clock. Human-input waits pause that clock,
not another caller's timeout; network rounds consume its remaining budget. The
driver validates every input in a round before prompting, preserves opaque state
and caller metadata, and permits at most ten wire rounds with fresh IDs. An
answered operation is never restarted or retransmitted after a continuation
failure. Native proof validation is bounded structural validation, not proof
generation. No URL opening, default answer, or hardware approval is automatic.

The server exposes these interactions only to clients opting in with
`client.capabilities {"mcp_inputs": true}`. Public inputs belong to their exact
caller; agent inputs belong to subscribed clients of that thread. See
[the input API](../../docs/api.md#mcp-requests-and-caller-input) for events,
pending requests, replies, cancellation, and lifetimes.

## Experimental Events

- Discover event definitions with `events/list`.
- Poll with `events/poll`, or open `events/stream` and handle activation,
  correlated occurrences, heartbeats, gaps, termination, and reconnect cursors.
- Register and refresh signed webhook delivery with `events/subscribe`; stop it
  with `events/unsubscribe`. Verify Standard Webhooks signatures and timestamps
  before processing callback bodies.
- Deduplicate accepted occurrences, bound delivery queues, and propagate caller
  cancellation. A rejected admission is retryable and does not advance its cursor
  or poison deduplication.

Delivery selection follows the draft: configured webhook, then push, then poll,
intersected with the event's advertised modes; `mode` overrides the preference.
An omitted cursor clears replay state just like an explicit `null`. Poll commits
its response cursor only after accepting the whole batch. Provider termination
removes the subscription and its durable intent, preserving the protocol error.
Request rejection (`InvalidParams`, `NotFound`, or `Unsupported`) instead leaves
desired thread state available for explicit repair.

Polling retries transient transport, API, and inbox errors for the subscription's
lifetime, using exponential backoff capped at one minute and honoring the
provider's longer `retryAfterMs` advice. Reconnecting subscriptions retain their
cursor and expose the latest sanitized `error`; a successful poll clears it.
Unsubscribe and shutdown cancel the backoff immediately. Reconnect notifications
do not wake a thread or start a model turn.

`notifications/events/list_changed` refreshes the event registry. A typed
`schema_changed` rejection or termination rediscovers the descriptor, validates
the saved arguments and reconnects the subscription. Incompatible arguments or
delivery modes leave desired thread state available for repair. Provider
termination for event removal or authorization revocation ends the subscription.

Agents can discover event types with `list_mcp_events`, create a saved-thread
watch with `subscribe_mcp_events`, inspect `list_mcp_event_subscriptions`, and stop
it with `unsubscribe_mcp_events`. The host supplies thread ownership; the model
cannot choose another thread. The Happen server maintains subscriptions between
turns and admits occurrences durably before waking an idle thread.

The server exposes `mcpSubscriptionCount` and `mcpSubscriptionCounts` for saved
subscriptions on unarchived threads, emits `mcp.subscriptions.changed` with
per-thread and total counts, and includes `active_mcp_subscriptions` in telemetry.
Counts change after durable membership commits and include watches awaiting
reconnect. Desktop holds its local sleep assertion while these watches exist,
even when their threads are unloaded; removal, archive, and shutdown release it.

Webhook TTLs are suggestions: the server may clamp them to its own floor or cap.
Every grant must include `refreshBefore`; `null` is accepted only when the caller
explicitly requested `ttl_ms: null`. Grants are validated before activation.
No-expiry subscriptions still refresh occasionally for cursor and delivery health.
Signed verification challenges work before activation; early occurrences receive
`503` until the initial grant is known, so the server can retry them safely.

Servers may also expose tools such as `poll_events` and `wait_for_event`. These
are discovered and called through ordinary `tools/list` and `tools/call`;
Happen's background subscriptions use the draft's `events/*` methods.

To verify against the real [Hookdeck bridge](https://github.com/hookdeck/mcp-events-bridge#github),
install dependencies in its checkout with `aube install --ignore-scripts`, then run
`dart tool/verify_mcp_events_bridge.dart /path/to/mcp-events-bridge` from Happen.
The Dart runner launches the upstream server with `aube exec tsx` and supplies a
local Event Gateway fixture API and signed synthetic GitHub Actions webhooks.
It checks discovery, filters, protocol polling, both poll tools, replay and
cancellation without service credentials. An optional second argument saves its
JSON report; the recorded [0.10.0 result](../../docs/evidence/mcp-events-bridge-live.json)
identifies the upstream commit and the fixture boundary.

`packages/server` can bind a subscription to a saved thread and supply the
`acceptThreadEvent` callback. That owner survives desktop disconnection and
thread unloading. Occurrences cold-load the thread and enter its durable inbox;
webhook success waits for admission, not model completion. Protocol control
notifications never start a model turn. Thread identity is local metadata and
is not sent as an extra draft parameter to the upstream server.

Thread-owned subscriptions and cursors are stored in the thread's existing
SQLite file and restored at server startup, using its saved project scope.
The server-wide `server.sqlite` stores shared thread metadata and a recovery index
with one dedicated writer. Startup queries that index and restores unarchived
owners independently; opening a desktop tab or starting an agent is unnecessary.
Fresh installations start with an empty catalog. Startup uses the catalog and
repairs only journaled incomplete updates, without discovering history folders.
Index membership commits before
private subscription/admission state, and survives while acknowledged event input
is pending even if its watch was removed. Cursor, receipt and inbox authority stay
in the thread's database, preserving their single-transaction durability.
Restoring control state does not load a thread or run a model. An occurrence's
cursor and bounded receipt join its inbox admission transaction; an acknowledged
event left pending at process death wakes after restart without another event.
Webhook IDs/signing material stay private and survive restart; an authenticated
re-registration can replace an expired provider identity. Unsubscribe, archive
and provider termination remove durable intent. Connection-owned subscriptions
remain ephemeral. Storage uses one writer isolate per saved session, no writer
lock files, and independent read-only connections.
See [the API guide](../../docs/api.md#mcp-events) for configuration and lifetimes,
[`test/mcp_test.dart`](../../test/mcp_test.dart) for transport contracts, and
[`thread_unsubscribe_test.dart`](../server/test/thread_unsubscribe_test.dart)
for real server/inference/SQLite wake-up and retry coverage.
[`mcp_events_restart_test.dart`](../server/test/mcp_events_restart_test.dart) exercises
graceful and killed process restarts, offline polling catch-up,
archived exclusions, persisted cursors, deduplication, and pending event recovery.
