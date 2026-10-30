# Running Happen

Initialize the pinned QuickJS submodule, then resolve the Dart workspace:

```sh
git submodule update --init --recursive
dart pub get
dart run bin/agent.dart login --from-codex
dart run bin/agent.dart exec --cwd /path/to/repo "Complete this task"
```

`exec` starts an embedded server and connects through a private temporary Unix
socket. The server and CLI remain in one process. `login --from-codex` stores a
reference to Codex's credential file; Codex remains responsible for refreshing
that login. `login` and `login --device` create an independently owned login.

The default data directory is `~/.local/share/agent-server`. Set `AGENT_DATA_DIR`
or pass the global `--data-dir PATH` option to select another directory. It holds
global configuration, authentication references, `AGENTS.md`, and task databases.

For a remote server, run the loopback listener on the remote machine and forward
its port with SSH:

```sh
dart run bin/agent.dart serve --host 127.0.0.1 --port 8765
ssh -N -L 8765:127.0.0.1:8765 user@remote
dart run bin/agent.dart exec --url ws://127.0.0.1:8765/ws "Complete this task"
```

The first command runs remotely; the remaining commands run locally. SSH process
management belongs to the future client. An explicit local socket is also
available through `serve --socket /absolute/path` and
`exec --url unix:///absolute/path`. Existing socket paths are never overwritten.
The IP listener uses HTTP/1.1 WebSocket upgrades and rejects browser Origin
headers. Non-loopback binding requires a bearer token.

Dart applications can embed `AgentServer.startEmbedded(directory: ...)` and
connect to its `uri`. Call `close()` on the client and server when their owner
exits. Build a distributable CLI with its native libraries using:

```sh
dart build cli --target=bin/agent.dart --output=build/agent
```

Keep the resulting `bundle/bin` and `bundle/lib` directories together.

## Global configuration

`config.json` in the data directory selects provider defaults and global MCP
servers. For example:

```json
{
  "default_provider": "gpt",
  "providers": {
    "gpt": {
      "model": "gpt-6.1-sol",
      "settings": {"reasoning": "low", "transport": "http"}
    },
    "deepseek": {
      "model": "deepseek-flash",
      "api_key_env": "DEEPSEEK_API_KEY",
      "transport": "messages"
    }
  },
  "mcp_servers": {
    "local": {
      "command": "/absolute/path/to/mcp-server",
      "args": [],
      "inherit_env": ["SERVICE_API_KEY"]
    },
    "remote": {
      "url": "https://example.com/mcp",
      "header_env": {"Authorization": "MCP_AUTHORIZATION"}
    }
  }
}
```

`header_env` supplies the complete header value from the named environment
variable. Local MCP servers also accept `cwd`, `env`, and `enabled`; subprocesses
inherit a small standard environment plus `inherit_env`. Each configured process
is shared across tasks. `mcp.reload` reloads MCP configuration. Provider defaults
are read at server startup and resolved settings are saved when a task is created.

GPT supports `http` and `websocket` model transports. Its catalog supplies the
model prompt, effort defaults, and context limits. DeepSeek supports the native
Messages route and an explicitly configured `chat` adapter. Messages represents
ordered tool additions natively; Chat rebuilds its request catalog and retains a
textual notice at each update's position. Model aliases for third-party services
are not inferred. Credentials are environment
references or private authentication files, never task settings.

## DeepSeek through OpenCode Console

Create Happen's own Console login:

```sh
dart run bin/agent.dart login --provider opencode
```

Open the displayed URL in your signed-in browser, confirm the device code, and
authorize the workspace. The DeepSeek package saves `opencode-auth.json` privately
and refreshes its own tokens. It does not require the OpenCode executable or use
the CLI's refresh token.

Select the Console backend in the data directory's `config.json`:

```json
{
  "providers": {
    "deepseek": {
      "backend": "opencode",
      "model": "deepseek-v4.1-flash-free",
      "settings": {"reasoning": "low"}
    }
  }
}
```

Then run `dart run bin/agent.dart exec --provider deepseek "Complete this task"`.
The route uses Chat Completions, with a 200,000-token context and a maximum output
of 32,000 tokens from the pinned OpenCode catalog. The exact free model is required;
there is no automatic paid fallback. Native DeepSeek remains available with
`"backend": "native"` (the default), `deepseek-flash`, and `DEEPSEEK_API_KEY`.

Login and model availability are separate. In the recorded live check, Happen's
device authorization succeeded, but its authenticated inference request received
`FreeUsageLimitError` (HTTP 429). The OpenCode CLI returned `READY` for the same
model. Happen reports `free_usage_limit` for that hosted denial; live tool execution
through this route is still unverified. See the [evidence](evidence/deepseek-console.json).

## WebSocket API

Requests are JSON objects with `id`, `method`, and `params`. Replies contain the
same `id` and either `result` or `error`. Notifications use `{"event": {...}}`.
Task operations acknowledge admission before emitting their durable events;
wait for `turn.completed`, `turn.failed`, or `turn.cancelled` to learn the outcome.

| Method | Parameters and behavior |
| --- | --- |
| `ping` | Returns the server version. |
| `task.start` | `prompt`, optional `cwd`, `provider`, `model`, `reasoning`, `settings`, `max_steps`, `client_tools`. Returns `task_id`. |
| `task.send` | `task_id`, `prompt`, optional `reasoning`, `cwd`, `instructions`. Appends input and starts a turn. |
| `task.compact` | `task_id`. Installs a checkpoint only after successful compaction. |
| `task.cancel` | `task_id`. Cancels the active operation and its owned tools. |
| `task.subscribe` | `task_id`. Subscribes this connection to future task events. |
| `task.fork` | `task_id`, optional `through` event sequence. Copies an independent committed prefix; returns a new `task_id`. |
| `history.page` | `task_id`, optional `after` sequence and `limit` (1–500). |
| `history.export` | `task_id`, `path` on the server. Requires an idle task. |
| `history.import` | `path` on the server, optional `operation_id` for idempotent retries. Validates the bundle before publishing a task. |
| `tools.register` | `task_id`, `tools`. Replaces the caller's client tool catalog. |
| `telemetry` | Returns bounded counters and timing buckets. |

The model is fixed for each task. GPT effort updates are appended to history;
DeepSeek effort is fixed. Automatically loaded `AGENTS.md` snapshots are restored
after compaction. Compaction keeps the full durable transcript available through
code mode's `history__list_windows`, `history__list_items`, `history__read_item`,
and `history__search_contents`. Forks and imports preserve historical item IDs.

Clients acknowledge consumed notifications with
`{"method":"events.ack","params":{"count":1}}`. Each connection starts with
256 event credits. Slow clients are disconnected when credits are exhausted;
reconnect and read durable task events with `history.page`. `AgentClient` handles
these acknowledgements automatically. Event subscriptions themselves belong to
the live connection.

## Client tools

Register a tool with `tools.register`, or include `client_tools` in `task.start`:

```json
{
  "id": 1,
  "method": "tools.register",
  "params": {
    "task_id": "TASK_ID",
    "tools": [{
      "name": "browser_title",
      "description": "Read the title of the current browser tab",
      "inputSchema": {"type": "object", "properties": {}}
    }]
  }
}
```

One connection owns a task's catalog. The server sends that connection a request
with a string `id`, `method: "tools.call"`, and parameters `task_id`, `call_id`,
`namespace`, `tool`, and `arguments`. Reply using that request ID:

```json
{"id":"CALL_ID","result":{"success":true,"contentItems":[{"type":"inputText","text":"Example title"}]}}
```

The server sends `tools.cancel` with `call_id` when a pending call is cancelled.
Disconnecting, changing a called definition, or unregistering with an empty
catalog fails affected pending calls without retrying them. Their side effects
may already have happened. Model declarations are appended between steps, and
code mode exposes the same tools as `tools.client__NAME`.

## MCP Events

The core protocol is `2026-07-28`; Events follows the pinned experimental draft
listed in [decisions.md](decisions.md). Push, polling, and signed webhooks are
implemented. Discovery and event delivery are distinct from model execution.

| Method | Parameters |
| --- | --- |
| `mcp.status` / `mcp.reload` | No parameters. |
| `mcp.request` | `server`, `method`, optional `arguments`; supports event discovery/polling, resources, and prompts. |
| `mcp.events.subscribe` | `server`, `name`, optional `arguments`, `mode` (`push`, `poll`, `webhook`), `cursor`, `max_age_ms`, `ttl_ms`, `task_id`. |
| `mcp.events.subscriptions` | Lists this connection's subscriptions. |
| `mcp.events.unsubscribe` | `subscription_id`. |

Subscription creation waits for activation. `mcp.event` notifications carry
`subscription_id`, `server`, and the draft `notification` method and parameters.
Clients receive activation, events, heartbeat, gap, and termination messages.
Transport recovery preserves cursors and bounds retries; explicit termination
ends the subscription. A client disconnect cancels its subscriptions. An arriving
event does not start a model turn.

Webhook delivery requires an HTTPS `public_url` in global configuration, routed
to this server's `/mcp-events/...` callback paths. The server verifies webhook
signatures and timestamps before delivery; signing secrets remain in the network
owner. The ordinary SSH port-forward setup supports push and polling without a
public webhook endpoint.

See [verification.md](verification.md) for executable checks and measured limits.
