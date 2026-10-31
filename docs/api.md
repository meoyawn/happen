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
defaults to `~/.config/happen/config.yaml`, independently of the data directory.

Skills are discovered only in `~/.agents/skills/` globally and `.agents/skills/`
locally. Local discovery walks from the nearest Git repository root down to the
task working directory, or checks only that directory outside a repository.
Install each skill in its own subdirectory with a `SKILL.md` file.

Each `SKILL.md` needs YAML frontmatter with a `description`; `name` is optional
and defaults to the containing directory. Only a bounded name/description/path
catalog enters model context automatically: at most 2% of the task's context
limit, shared across catalog updates until compaction. Descriptions can be
shortened and entries omitted. Full bodies stay on disk and load when selected,
including files omitted from the catalog. OpenCode uses its native
`skill({id: "/full/path/to/SKILL.md"})` tool; OpenAI uses file tools. Compaction
refreshes the catalog, and skills can be read again as needed.

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
connection. The composer lists models from both subscriptions in one menu;
choosing a model selects its provider and reasoning options. DeepSeek API-key
accounts are not offered. Steer/Queue behavior remains an app setting.
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

If you used the previous `~/.happen/config.yaml` default, move that file to the
new location and restart the server.

Create `~/.config/happen/config.yaml` with local commands, remote URLs, or both:

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
default_provider: openai
providers:
  openai:
    model: gpt-6.1-sol
    settings: {reasoning: low, transport: http}
  opencode:
    model: deepseek-v4.1-flash-free
    settings: {reasoning: low}
```

Use the global `--config PATH` option to select another YAML file, for example
`dart run bin/agent.dart --config /path/config.yaml serve`. Embedded applications
can pass `configPath` to `AgentServer.start` or `startEmbedded`; their default is
also `~/.config/happen/config.yaml`. A missing file at startup means empty
configuration.
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

Existing tasks check catalog revisions before the next model request, including
between steps of an active turn. New tools remain deferred; only namespace
summaries and changes to already loaded native schemas enter context. OpenAI appends
changed loaded schemas as developer-role `additional_tools` items; the original
request-level tools stay fixed. OpenAI MCP calls use `mcp__SERVER.TOOL`, and code
mode uses `tools.mcp__SERVER__TOOL`. OpenCode calls MCP tools inside `execute`
through `tools.SERVER.TOOL`, preserving bracket notation for hyphens. Its native
catalog stays fixed; external schemas remain inside Code Mode. Namespace removals
append availability notices, and calls check the live registry. OpenAI compaction
restores only currently available native tools that were already loaded. A catalog check
reconciles config immediately, without waiting for the file watcher's debounce.
Unchanged catalogs return a revision response without copying their schemas.
Invalid edits retain the live catalog.

Config edits made while the server is stopped also apply to existing tasks.
Startup discovers tools from the current config; resuming compares that catalog
with the task's persisted MCP snapshot before the first model request. New
definitions stay discoverable, changed loaded definitions are appended, and
removed tools remain unavailable. This also works when shutdown interrupted an
active turn.

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

## Tool discovery

Tool interfaces and instructions belong to `packages/openai` and
`packages/opencode`. The agent supplies shared execution services; the providers
own discovery, declarations, catalog updates, and result formatting. Both reuse
the process runner, patch engine, and JavaScript engine. OpenAI search is entirely
Dart and has no native build hook.

OpenAI follows Codex: `await tools.tool_search({query, limit})` uses English BM25
over deferred metadata and returns `{tools: [{name, description}]}`. Descriptions
include TypeScript declarations and MCP guidance. The default limit is 8; there
is no additional maximum or exact-name boost. Normalization, NLTK stop words,
stemming, token hashes, and float32 scores follow the pinned upstream runtime.
Equal-score ordering is unspecified upstream; Dart uses registration order.
Search output enters model context when printed and does not load native schemas.
`ALL_TOOLS` supports exact lookup and filtering.

The host registry is read when a cell starts and again when `tool_search` runs,
so a search after an in-cell config edit sees the current tools. `ALL_TOOLS`
remains the cell's starting snapshot. Use search to retrieve server guidance
before calling an MCP tool found through that snapshot.

Calling OpenAI's `tool_search` directly returns matching native schemas in every
client-executed `tool_search_output`, including repeated searches. Loaded schemas
survive restart and compaction. Earlier OpenAI tasks acquire discovery through an
ordered declaration while retaining their frozen prefix.

OpenCode follows its own runtime: inside `execute({code})`, call
`await search({query, namespace, limit, offset})`. Query and namespace are optional;
the default page size is 10. Results contain `items` with exact callable `path`,
`description`, and `signature`, plus `remaining` and `next`. Matching scores exact
paths, path words, substrings, descriptions, and parameter metadata. It supports
plural forms and sorts ties by path. This is a catalog snapshot for that execution.
It does not load native schemas. The catalog shares a 2,000-token estimate across
namespaces and always includes pinned entries. MCP server instructions render
separately. File/shell/web tools are ordinary native calls outside `execute`.

In OpenAI code mode, `store(key, value)` saves an explicit JSON snapshot for `load(key)` in later
cells. Successful cells persist these values with the task; model output includes
only what the cell prints. Stored values have no separate serialized-size cap.
They still share the cell's default 32 MiB QuickJS memory budget and execution
limits, so retaining large results increases the memory needed by later cells.

## Web search

OpenAI exposes Codex-style `web.run` and `tools.web__run` in code mode, using
the pinned OpenAI parameter schema:
`search_query`, `image_query`, `open`, `click`, `find`, `screenshot`, `finance`,
`weather`, `sports`, `time`, and optional `response_length` (`short`, `medium`,
or `long`). The schema, including field descriptions and required fields, lives
in `packages/openai/lib/src/web_search_schema.dart`. OpenAI reserves `web.run`
and rejects a changed schema before inference. OpenCode exposes its upstream
`websearch({query, num, ...})` and `webfetch({url, format, timeout})` tools, plus
`fetch` inside `execute`.

GPT uses OpenAI-hosted search with the existing ChatGPT login. DeepSeek and the
OpenCode model route use OpenCode Console's hosted HTTP search with the selected
Console organization. This requires Hosted Web Search access in that workspace;
the current public endpoint returned HTTP 404 during verification. Failed access
is reported to the model so it can choose an available configured search tool.
There is no embedded MCP client or automatic search-provider fallback.

OpenCode search uses the requested result count (default 8). Its page tools fetch
public text/HTML directly without Console credentials. OpenAI can also use opaque
references returned by its hosted reader and forwards its full command set to
that service. Neither provider advertises the other's web interface.

When OpenAI's reader reports that a requested source URL is inaccessible,
`open` and `find` try a direct HTTP GET for text/HTML. Recovered results identify
the source URL and direct retrieval, with zero-based lines and absolute links.
Use that URL for follow-up reads; these lines belong to the directly retrieved
page. Requests carry no provider credentials and retain the existing cancellation,
60-second request deadline, 2 MiB response limit, and 64 KiB tool output limit.
Successful hosted results are preserved. If direct retrieval also fails, the
original hosted error remains visible.

`providers.deepseek.web_search.endpoint` and
`providers.opencode.web_search.endpoint` can override the Console HTTP search
endpoint at server startup. All MCP servers, including optional search MCPs,
must be declared under `mcp_servers` in the global configuration. They use the
ordinary MCP namespaces and discovery; no MCP server is built into either lab.

## Repository instructions

The server discovers `AGENTS.override.md`, then `AGENTS.md`, in each directory
from the nearest `.git` marker to the task's working directory. A marker can be
a file or directory. Without a marker, only the working directory is checked.
It selects one file per directory, including an empty override, and combines
nonempty contents in ancestor order. Instruction-file symlinks are allowed.
Descendant files are read by the agent when needed, following its shared guidance.

Repository contents share a 32 KiB UTF-8 byte budget. Global instructions in the data directory retain their independent
32 KiB budget. These are fixed limits; configurable fallback names and project
trust/sandbox policies are not implemented.

Repository snapshots stay cached across turns at the same working directory.
Editing a file alone does not refresh a warm task. Changing `cwd`, restarting
the server, or restoring an archived task loads the current chain. The server
retains at most 256 lightweight snapshots in least-recently-used order; an evicted
task also resumes cold. Idle agent isolates and database owners are still released.

OpenAI renders Codex's user-role AGENTS.md wrapper and full replacement/removal
messages. OpenCode renders its developer-role `Instructions from: PATH` blocks
and upstream added/changed/removed messages, selecting a unified diff when it is
shorter than a full replacement. System instructions are copied verbatim from
each pinned upstream; there is no shared Happen instruction overlay.
Unchanged snapshots and an initially empty chain add no instruction messages.
Compaction restores one current nonempty snapshot instead of retaining earlier
versions or replacement notices. Original events remain in durable history.
Empty MCP/client catalogs also add no initial or restored availability messages;
actual removals still append their availability notice.
Tool updates compare JSON objects independently of key order. Reordering the
same catalog does not add declarations or notices. Unloaded schemas stay out of
context; changed loaded definitions and removals remain explicit. Namespace
notices follow each provider's own budget. Codex namespace notices have a 4 KiB
UTF-8 cap and use the first description line, capped at 250 Unicode characters.
Full MCP guidance remains available through discovery. Compaction restores current
provider instructions, namespace summaries, and OpenAI's loaded subset once.

## DeepSeek through OpenCode Console

Create Happen's own Console login:

```sh
dart run bin/agent.dart login --provider opencode
```

Open the displayed URL in your signed-in browser, confirm the device code, and
authorize the workspace. The DeepSeek package saves `opencode-auth.json` privately
and refreshes its own tokens. It does not require the OpenCode executable or use
the CLI's refresh token.

Select an OpenCode model in the desktop composer, or use `--provider opencode` with the CLI.
Optional defaults in `~/.config/happen/config.yaml`:

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
for existing tasks and clients. The desktop offers the `opencode` subscription
account directly.

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

Task IDs are opaque strings generated by the task's provider. New `openai`
tasks use Codex-style hyphenated UUIDv7 IDs; `opencode` and `deepseek` tasks use
OpenCode-style `ses_` IDs. Forks and imports receive fresh IDs from the provider
saved in their source history. Existing task IDs remain valid. An import's
optional `operation_id` is a separate retry key: concurrent or later retries,
including after a server restart, return the same imported task ID.

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

Manual, threshold, and overflow compaction emit a durable `compaction.started`
event with `data.reason` (`manual`, `threshold`, or `overflow`). Successful
installation emits `context.compacted`, including the visible `data.summary`
(empty for native GPT checkpoints) and usage. The replacement `data.input`
contains provider replay state and must not be rendered as conversation text.
Internal compaction text/reasoning deltas are excluded from the reply stream;
`model.retrying` still reports retries. Failure or cancellation ends the turn
with `turn.failed` or `turn.cancelled` without installing a checkpoint.

Subscriptions deliver these events live. A client joining during compaction
subscribes and pages durable history to find the active start. The desktop
renders one timed compaction row, retains its completion in history, and offers
an expandable summary when available. Interrupted starts in idle history are
shown as interrupted rather than left spinning.

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
| `providers.list` | Returns ChatGPT (`openai`) and OpenCode (`opencode`) models, reasoning options, and credential status without credential values. |
| `auth.login` | `provider`, `login_id`. Starts browser/device authorization; `auth.login` events supply its URL and optional device code. |
| `auth.cancel` | `login_id`. Cancels this connection's active authorization. |
| `auth.logout` | `provider` (`openai` or `opencode`; legacy `gpt` accepted). Cancels credential operations and removes Happen's login. |
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
may already have happened. OpenAI selects native declarations through `tool_search`
and updates them between steps once loaded; its code mode uses `tools.client__NAME`.
OpenCode exposes `tools.client.NAME` through `execute` and `search`, keeping their
schemas out of the native catalog.

## MCP Events

The core protocol is `2026-07-28`; Events follows the pinned experimental draft
listed in [decisions.md](decisions.md). Push, polling, and signed webhooks are
implemented. Discovery and event delivery are distinct from model execution.

| Method | Parameters |
| --- | --- |
| `mcp.status` / `mcp.reload` | No parameters. |
| `mcp.inventory` | Optional `verbose` boolean (default false) and `server` name. Read-only server inventory, including disabled entries. |
| `mcp.inventory.cancel` | Notification with the inventory call's `request_id`; cancels only that request. |
| `mcp.request` | `server`, `method`, optional `arguments`; supports event discovery/polling, resources, and prompts. |
| `mcp.events.subscribe` | `server`, `name`, optional `arguments`, `mode` (`push`, `poll`, `webhook`), `cursor`, `max_age_ms`, `ttl_ms`, `task_id`. |
| `mcp.events.subscriptions` | Lists this connection's subscriptions. |
| `mcp.events.unsubscribe` | `subscription_id`. |

`mcp.inventory` returns `{servers: [...]}` sorted by name. Each row contains
`name`, `enabled`, `state`, `auth_status`, `tool_count`, and an optional sanitized
`error`. Configured HTTP headers are reported as `configured_headers`, without
their values; this does not claim OAuth support or successful authentication.
HTTP 401/403 is `not_authenticated`. Other connections report `unsupported`.
With `verbose: true`, rows also contain sorted `tools` names, `resources`
(`name`, optional `title`, `uri`), and `resource_templates` (`name`, optional
`title`, `uriTemplate`). Resource discovery follows cursors and reports catalog
failures in `resources_error` / `resource_templates_error` while keeping other
servers' results. Credentials, launch arguments and private metadata are excluded.

Inventory reconciles the server's global config on demand; invalid edits retain
the last accepted configuration and add a sanitized `config_error`. It reuses
shared MCP connections. Calls have a 30-second server deadline and the usual
2 MiB result bound; select a server for oversized inventories. `AgentClient`'s
`mcpInventory` accepts a cancellation token and sends the cancellation notification
when its owner closes. Disconnect also cancels outstanding inventory requests.

The desktop's `/mcp` and `/mcp verbose` commands open this inventory in the same
autocomplete popover as file search. They run locally, preserve surrounding
draft text and file references, and do not submit a model turn or write history.

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
