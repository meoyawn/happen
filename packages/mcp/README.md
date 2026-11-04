# MCP client and Events draft

This package connects configured MCP servers from Happen's shared network
isolate. It implements the experimental
[MCP Events proposal](https://github.com/modelcontextprotocol/experimental-ext-triggers-events),
separately from the core MCP protocol; no plugin system is involved.

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
