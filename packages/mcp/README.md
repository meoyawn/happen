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
  thread's cwd without loading or subscribing to the thread. Threadless requests
  see global config only. Internal agent catalog/call/resource requests carry cwd.
- Invalid reloads retain the last accepted connections and expose a sanitized
  `config_error` on inventory. Removing a project layer restores inheritance.
- Modern stdio messages, HTTP JSON bodies and SSE events use Codex's 8 MiB wire
  bound. Legacy local/HTTP codecs retain their uncapped wire behavior; IPC,
  catalog and model-facing output budgets remain separate. A discovery timeout
  alone never authorizes a legacy handshake on the same process.
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

`packages/server` can bind a subscription to a saved thread and supply the
`acceptThreadEvent` callback. That owner survives desktop disconnection and
thread unloading. Occurrences cold-load the thread and enter its durable inbox;
webhook success waits for admission, not model completion. Protocol control
notifications never start a model turn. Thread identity is local metadata and
is not sent as an extra draft parameter to the upstream server.

Subscriptions and cursors are not yet restored after a server process restart.
See [the API guide](../../docs/api.md#mcp-events) for configuration and lifetimes,
[`test/mcp_test.dart`](../../test/mcp_test.dart) for transport contracts, and
[`thread_unsubscribe_test.dart`](../server/test/thread_unsubscribe_test.dart)
for real server/inference/SQLite wake-up and retry coverage.
