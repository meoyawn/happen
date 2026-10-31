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
authentication references, `AGENTS.md`, and task databases. Global configuration
defaults to `~/.happen/config.yaml`, independently of the data directory.

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

## Desktop development

Run `moon run dev` from the repository root. The guarded launcher starts or reuses
one macOS debug session, including its Flutter supervisor during a build.
New sessions return a PID, log path, and input pipe; send `r` for stateful hot
reload with `printf r > .local/run/flutter-input` (`R` restarts; `q` quits).
Use `moon run dev -- --status` to inspect without launching. Existing sessions
started elsewhere keep their original terminal/VM controls. Logs and locks are
local tooling files outside the app bundle. The Dart server is embedded in the
same process; the UI uses its WebSocket API over a private Unix socket. Native
Swift/plugin changes and startup-only configuration need a rebuild/relaunch.

`moon run release` directly builds the macOS release without workflow logging,
locks, or process inspection/reuse. `moon run release-reinstall`
stops the installed release before replacing `/Applications/Happen.app` and
leaves it stopped, including after rollback.
One debug and one release may coexist; reinstallation leaves debug running.
See [the desktop README](../packages/desktop/README.md) for custom installation
paths and the guard's scope.

Open a project folder from the sidebar, then create a task and use the composer.
Enter sends; Shift+Enter inserts a newline. Model and reasoning controls stay in
the composer. Streamed responses appear as they arrive, and code-mode host calls
are nested beneath their parent code cell.

On macOS, paste images with Command+V or the composer's Paste menu, or drop images
and files onto the composer. Attachments have previews and removal controls and
can be sent without text. Failed sends retain the draft. The local desktop sends
image paths to its embedded server; the server prepares the pixels for the model
and stores the resulting image bytes with the message.

With a remote `AgentClient`, the desktop snapshots images into inline bytes.
It accepts source images up to 1 GiB and prepares oversized images off the UI
thread to fit Codex's 32 MiB encoded image budget before sending. Smaller sources
remain unchanged when the combined budget permits. Preparation and file uploads
are cancellable. Remote file attachments upload their contents; local files and
folders remain server path references. Server selection and SSH management still
need a client UI.

Open Settings from the gear or **Happen → Settings…** (Command+,). Accounts have
separate sign-in, sign-out, and switch-account actions for ChatGPT and OpenCode.
Successful browser authorization brings Happen forward and confirms the account
connection. The default provider and Steer/Queue behavior are app settings.
Existing tasks retain their provider/model and supported effort-change policy.

Archive a task from its sidebar menu. Archived tasks appear only in Settings,
where they can be viewed or restored. Archiving stops active work, discards
uncommitted pending messages, and preserves the conversation. The Undo toast
expires after three seconds; Restore remains available in Settings.

The desktop owns `desktop.sqlite` through one SQLite isolate. It stores project
checkout identities, task references, archive state, and settings. Task history
stays server-owned. A checkout keeps a stable key when its Git remote is added,
removed, or changed; its current project identity is the normalized remote URL,
or the absolute local path when no remote is available. Multi-server selection
and SSH forwarding management remain future client work.

## Global configuration

Create `~/.happen/config.yaml` with local commands, remote URLs, or both:

```yaml
mcp_servers:
  dart:
    command: dart
    args: [mcp-server, --disable, analysis]
  remote:
    url: https://example.com/mcp
    header_env:
      Authorization: MCP_AUTHORIZATION

# Optional provider defaults.
default_provider: gpt
providers:
  gpt:
    model: gpt-6.1-sol
    settings: {reasoning: low, transport: http}
  deepseek:
    model: deepseek-flash
    api_key_env: DEEPSEEK_API_KEY
    transport: messages
```

Use the global `--config PATH` option to select another YAML file, for example
`dart run bin/agent.dart --config /path/config.yaml serve`. Embedded applications
can pass `configPath` to `AgentServer.start` or `startEmbedded`; their default is
also `~/.happen/config.yaml`. A missing file at startup means empty configuration.
For compatibility, a missing YAML file falls back to the data directory's
`config.json`, validated against the same schema. Files are never merged, and an
invalid YAML file never falls back to JSON. Credentials and task data stay in
their existing directory.

The running server watches the file. Saving a valid edit adds new MCPs, stops
removed or disabled local processes, and replaces a local process when its command,
arguments, environment, or working directory changes. Unchanged entries keep their
processes and subscriptions. URL entries own client connections only; edits update
those connections without starting or stopping the remote server. Crashed local
processes retain the existing bounded restart policy.

Watching uses parent-directory notifications with a 200 ms debounce and a
two-second fallback check. It handles atomic editor saves and files/directories
created after startup. Invalid edits keep the running MCP configuration and send
`mcp.config.error` to connected clients. Once a file has been loaded, deleting it
keeps the running configuration; use `mcp_servers: {}` to remove all MCPs. After
YAML has been selected, deletion also does not reactivate an old JSON config.
`mcp.config.reloaded` reports applied MCP changes or recovery from a config error.
`mcp.reload` remains available to request an immediate validated reload.

Existing tasks refresh their MCP tools before the next model request, including
between steps of an active turn. GPT receives new or changed schemas as
developer-role `additional_tools` input items; the original request-level tools
stay fixed. Direct MCP calls use `mcp__SERVER.TOOL`, and code mode retains
`tools.mcp__SERVER__TOOL`. Removed tools receive an availability notice and calls
check the live registry. Updates persist in task history; compaction restores the
current catalog. A catalog refresh reconciles the config immediately, without
waiting for the file watcher's debounce. Invalid edits retain the live catalog.

Config edits made while the server is stopped also apply to existing tasks.
Startup discovers tools from the current config; resuming compares that catalog
with the task's persisted MCP snapshot before the first model request. Added and
changed definitions are appended to the saved conversation, and removed tools
remain unavailable. This also works when shutdown interrupted an active turn.

`header_env` supplies the complete header value from the named environment
variable; `headers` supplies literal HTTP header strings. Local MCP servers accept
`cwd`, `env`, and `inherit_env`; subprocesses inherit a small standard environment
plus `inherit_env`. Quote numeric or boolean environment values, such as
`env: {PORT: "3000"}`. Commands execute directly with their argument list. Shell
expansion requires an explicit shell command, such as `command: sh` with
`args: [-c, "exec my-server"]`. Both transports accept `enabled` and
`legacy_fallback`. A server needs exactly one of `command` or `url`.

`packages/config` owns YAML parsing, the embedded JSON Schema, and file watching
in Dart. Startup and reload validate types, supported fields, transport options,
and server-name collisions before changing connections. Diagnostics omit config
values. Export the schema for a YAML editor with
`dart run bin/agent.dart config-schema > /path/happen.schema.json`.
Provider-specific settings and model limits remain validated by their providers.
Provider configuration and `public_url` take effect at server startup; resolved
provider settings remain saved with each task.

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

Select OpenCode in desktop Settings, or use `--provider opencode` with the CLI.
Optional defaults in `~/.happen/config.yaml`:

```yaml
providers:
  opencode:
    model: deepseek-v4.1-flash-free
    settings: {reasoning: low}
```

Then run `dart run bin/agent.dart exec --provider opencode "Complete this task"`.
The route uses Chat Completions, with a 200,000-token context and a maximum output
of 32,000 tokens from the pinned OpenCode catalog. The exact free model is required;
there is no automatic paid fallback. Native DeepSeek remains available with
`backend: native` (the default), `deepseek-flash`, and `DEEPSEEK_API_KEY`.
The earlier `providers.deepseek.backend: opencode` configuration remains valid
for existing tasks and clients. The desktop presents it as the OpenCode choice.

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

Turns and model/compaction calls have no cumulative wall-clock deadline or model
step limit. Legacy `max_steps` fields in existing task configurations are ignored;
the CLI no longer accepts `--max-steps`. Stop, archive, and server shutdown cancel
owned work. Quitting the desktop stops its embedded server. GPT HTTP/SSE and WebSocket
responses have a five-minute idle limit between provider events; each event
starts a fresh wait. Tool-specific execution limits still apply.

Interrupted/idle GPT streams, connection failures, and retryable server errors
allow five retries with exponential backoff and cancellation. Explicit incomplete
responses and terminal provider failures are not retried. Already executed tools
retain their durable results; retrying a model request does not execute them
again. Ephemeral `model.retrying` notifications contain `task_id`, `turn_id`,
`attempt` (1–5), and `max_retries` (5). The desktop shows reconnecting progress,
discards abandoned partial response text, and retains terminal failures in the
conversation, including failures without a durable sequence number.

| Method | Parameters and behavior |
| --- | --- |
| `ping` | Returns the server version. |
| `files.search` | Absolute server `cwd`, `query` (empty allowed, at most 256 characters), optional `limit` (1–50, default 20). Returns relative `paths` (directories end in `/`) and `truncated`. No task ID or model call is required. |
| `task.start` | `prompt` and/or `attachments`, optional `cwd`, `provider`, `model`, `reasoning`, `settings`, `client_tools`. Returns `task_id`. |
| `task.send` | `task_id`, `prompt` and/or `attachments`, optional `delivery` (`steer` or `queue`; server default `queue`), `reasoning`. While idle, also accepts `cwd`, `instructions`. |
| `attachments.begin` | Client-generated `upload_id`, `type` (`image` or `file`), basename `name`, and byte `size` (up to 1 GiB). Reserves a connection-owned upload. |
| `attachments.append` | `upload_id`, exact byte `offset`, base64 `data` (up to 24 MiB decoded per block). Returns the acknowledged next `offset`. |
| `attachments.finish` | `upload_id`. Requires the declared byte count and returns an attachment containing its `upload_id`. |
| `attachments.cancel` | `upload_id`. Releases a pending upload and its staged bytes. |
| `task.compact` | `task_id`. Installs a checkpoint only after successful compaction. |
| `task.cancel` | `task_id`. Cancels the active operation and its owned tools. |
| `task.archive` / `task.unarchive` | `task_id`. Stops work and archives a task, or restores it. History is retained. |
| `task.subscribe` | `task_id`. Subscribes this connection to future task events and returns `running` and pending inputs. |
| `task.fork` | `task_id`, optional `through` event sequence. Copies an independent committed prefix; returns a new `task_id`. |
| `history.page` | `task_id`, optional `after` sequence and `limit` (1–500). |
| `history.export` | `task_id`, `path` on the server. Requires an idle task. |
| `history.import` | `path` on the server, optional `operation_id` for idempotent retries. Validates the bundle before publishing a task. |
| `tools.register` | `task_id`, `tools`. Replaces the caller's client tool catalog. |
| `telemetry` | Returns bounded counters and timing buckets. |
| `providers.list` | Returns available models, reasoning options, and credential status without credential values. |
| `auth.login` | `provider`, `login_id`. Starts browser/device authorization; `auth.login` events supply its URL and optional device code. |
| `auth.cancel` | `login_id`. Cancels this connection's active authorization. |
| `auth.logout` | `provider` (`gpt` or `opencode`). Cancels credential operations and removes Happen's login. |
| `auth.desktop` | Local Unix sockets only. Optional `refresh` boolean; returns `access_token` and `account_id` for the desktop's direct OpenAI requests. Never returns a refresh token. TCP listeners reject it. |
| `maintenance.run` | Runs the same coalesced maintenance sweep used at startup and every 24 hours. |

Steer messages join the active turn before its next model request. Queue messages
start subsequent turns in order. Pending input is bounded to 32 messages and
512 KiB of text plus a 64 MiB serialized budget per task, and becomes durable only
when committed to history. Cancellation,
archive, or a failed turn discards remaining pending input. Clients receive
`input.pending`, `input.committed`, and `input.discarded` events.

Attachments use one of these shapes:

```json
{"type":"image","name":"screenshot.png","mime_type":"image/png","data":"BASE64","detail":"high"}
{"type":"image","name":"photo.jpg","path":"/absolute/server/photo.jpg"}
{"type":"file","name":"report.pdf","path":"/absolute/server/report.pdf"}
{"type":"file","name":"report.pdf","upload_id":"RETURNED_UPLOAD_ID"}
```

Inline images accept PNG, JPEG, GIF and WebP. Server paths and uploads also accept
formats decoded by the image package, such as BMP and TIFF. The macOS clipboard
bridge converts HEIC/HEIF snapshots to PNG. Images default to `high`: maximum
2,048-pixel edge and 2,500 32-pixel patches. `original` uses a 6,000-pixel edge and
10,000 patches. GIFs become a static PNG frame; JPEG resizing uses quality 85.
Image-only inputs are valid; text is limited to 512 KiB. Client WebSocket messages
are bounded to 64 MiB. History pages obey that byte budget as well as their row
limit, so clients must continue until an empty page.

Upload identifiers work only on the connection that created them. Interrupted
uploads are removed on cancellation/disconnection; retry starts a fresh upload
from the retained client file. Uploaded ordinary files receive durable server
paths. Accepted image uploads are removed after their prepared bytes are handed
to the task. Images survive restart, fork and export/import; ordinary file
references require their server paths to remain available. GPT receives
`input_image`, DeepSeek Messages receives base64 image blocks, and DeepSeek Chat
receives `image_url` content. File references become quoted path context.

On GPT models advertising `reasoning_updates`, reasoning can be selected while
the task runs. The desktop sends the selected level with the next message.
Each pending message retains its own `reasoning`: Steer applies it before that
message at the next model boundary; Queue applies it when that message starts
its turn. Invalid levels are rejected before admission. A changed level appends
a durable `configuration.updated` immediately before its user message, with
`effective_reasoning` committed in the same transaction. The GPT adapter encodes
this as `configuration_update`, preserving the original request-level effort
and earlier input prefix. Choosing a level alone does not start a model request.
DeepSeek/OpenCode effort and every task's model/provider stay fixed.

Pending messages include `created_at`, the server's UTC receipt time in ISO 8601
format. On commitment, `data.sent_at` preserves this time for queued and steered
messages; direct inputs also record their receipt time. This metadata is outside
the model-facing conversation item. Event `created_at` remains the commit time.
Older histories may omit `sent_at`; clients fall back to event `created_at`.
Clients can derive turn/tool elapsed times from their durable start and terminal
event timestamps. Missing times remain unknown rather than being replaced with
the time history was loaded.

Maintenance checkpoints archived SQLite WALs and removes abandoned staging
directories older than one day while no history transfer is active. It does not
expire archived conversations or delete project files. Idle task owners and their
isolates are released after each turn. Telemetry includes active/resident task,
connection, pending-message, and maintenance counts for monitoring long runs.

The model is fixed for each task. GPT effort updates are appended to history;
DeepSeek effort is fixed. Automatically loaded `AGENTS.md` snapshots are restored
after compaction. Compaction keeps the full durable transcript available through
code mode's `history__list_windows`, `history__list_items`, `history__read_item`,
and `history__search_contents`. Forks and imports preserve historical item IDs.

Clients acknowledge consumed notifications with
`{"method":"events.ack","params":{"count":1}}`. Each connection starts with
256 event credits. When credits are exhausted, notifications wait in an ordered
queue bounded to 1,024 events and 64 MiB. Acknowledgements drain that queue;
RPC replies bypass it, so a file search can finish while task events are waiting.
Clients exceeding either backlog bound are disconnected; reconnect and read
durable task events with `history.page`. `AgentClient` handles
these acknowledgements automatically. Event subscriptions themselves belong to
the live connection.

Requests are dispatched concurrently and replies are correlated by `id`; replies
may arrive out of request order. The 32-request admission bound counts pending
RPCs, not running task streams. Task start/send acknowledge admission promptly,
so 100 running tasks do not consume 100 request slots. There is no separate
WebSocket or task execution slot for autocomplete.

File search operates on the server's filesystem, including for new-task drafts.
Git checkouts include tracked and untracked files and their parent directories,
with Git's standard exclusions for untracked files. Empty Git directories and
directories containing only ignored files are not indexed. Plain folders or hosts without Git use an asynchronous
directory walk that skips `.git`, `.hg`, `.svn`, `node_modules`, `.dart_tool`,
`build`, and `.cache`, without following directory symlinks. Only names are
searched; no file contents are read or attached to prompts. Exact basenames and
paths rank first, so `desktop` surfaces `packages/desktop/` before its descendants
or files like `desktop-guide.md`. Prefixes, substrings and compact subsequences
follow. Selection inserts the relative reference, including the trailing `/` for
a directory. Plain-folder scans include empty directories too.

The server reuses a filename index for up to ten seconds and retains at most four
indexes. Each scan
is bounded to 100,000 paths/entries and 8 MiB of filename data, and each result's
path payload is bounded to 32 KiB. `truncated` means more matches or unscanned files
may exist. File search has a five-second server deadline. A newer search on the
same connection cancels its predecessor; different connections are independent.
Clients may send `{"method":"files.cancel","params":{"request_id":101}}`
without an `id` to cancel their search request 101. Late cancellation cannot
cancel a newer request. Cancellation, disconnection, and shutdown terminate the
owned scan; none of them cancel a running task. `AgentClient.searchFiles` accepts
a cancellation token and uses a ten-second deadline including network time.

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
