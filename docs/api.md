# Running Happen

Initialize the pinned QuickJS submodule, then resolve the Dart workspace:

```sh
git submodule update --init --recursive
dart pub get
dart run packages/cli/bin/happen.dart login --from-codex
dart run packages/cli/bin/happen.dart exec --cwd /path/to/repo "Complete this task"
```

`packages/cli` is a workspace package. Its commands call the local agent host
directly, without a listener, socket, WebSocket, or remote-machine connection.
`exec` owns its agent, persistence and provider isolates in one process.
`login --from-codex` stores a
reference to Codex's credential file; Codex remains responsible for refreshing
that login. `login` and `login --device` create an independently owned login.

The default data directory is `~/.local/share/agent-server`. Set `AGENT_DATA_DIR`
or pass the global `--data-dir PATH` option to select another directory. It holds
authentication references, `AGENTS.md`, and task databases. Global configuration
defaults to `~/.config/happen/config.yaml`, independently of the data directory.

`happen exec --help` lists execution options, including `--[no-]telemetry`.
Telemetry is disabled by default. With `--telemetry`, after the turn completes,
fails, or is cancelled, `exec` exports a local Chrome Trace Event JSON file under
`DATA_DIR/telemetry/` and prints its absolute path. With `--json`, the final output
is a `telemetry.exported` event whose `data.path` contains that path.

OpenAI's tool layout follows the selected model's catalog `tool_mode`, matching
Codex. Supported GPT models select CodeModeOnly: `exec`/`wait` orchestrate shell
and deferred MCP tools, with tool search enabled.

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

The CLI has no `serve`, `--url`, or server-authentication options. Applications
that need a listener can embed `AgentServer.start` or `startEmbedded` from the
server package; the desktop continues using its private local Unix socket.

Dart applications can embed `AgentServer.startEmbedded(directory: ...)` and
connect to its `uri`. Call `close()` on the client and server when their owner
exits. Clients that can present and answer questions call `client.capabilities`
with `{"questions": true}` on each connection. This enables GPT question tools
on subsequent turns in their subscribed sessions, including saved sessions.
The capability is not persisted in the session's provider settings.
Build a distributable CLI with its native libraries using:

```sh
dart build cli --target=packages/cli/bin/happen.dart --output=build/happen
```

### Saved sessions

The server's `thread/list` RPC discovers durable session databases independently
of live agent isolates and desktop sidebar references. It returns `{data, nextCursor}`;
summaries include `id`, `name`, `preview`, `cwd`, timestamps, and current `status`.
Supported filters include `cwd`, `modelProviders`, `parentThreadId`, `archived`,
and `searchTerm`. `sortDirection` defaults to `desc`; `sortKey` defaults to updated
time and also accepts `created_at`. `limit` defaults to 100, with a maximum of 500.
Opaque cursors retain the original filters and order.

The server generates and saves a context name in the background when a persistent
thread starts working. Naming uses a separate model request without tools or
extra conversation turns. It continues after a client disconnects,
preserves existing names, and does not change activity ordering. All connected
clients receive `thread/name/updated`; desktop renders `name`, falling back to
`preview` until a name is available. Ephemeral threads are excluded.

Listing never loads a conversation or runs its tools. Creation is acknowledged
after the session history and catalog metadata are durable. Saved interrupted
sessions remain listed after restart. The desktop refreshes its local sidebar
cache from the server at startup, when adding a project, returning to Home,
and on resume.

Keep the resulting `bundle/bin` and `bundle/lib` directories together. For a
single-file macOS arm64 release, use the Moon target instead:

```sh
moon run build-cli
build/cli/happen --version
python3 tool/verify_cli.py
```

`build/cli/happen` contains the stock Dart AOT runtime, program, and compressed
QuickJS/SQLite dylibs. The first launch installs the dylibs in a private cache at
`~/Library/Caches/dev.happen/cli/native/`; subsequent launches check a small marker
and file metadata, then load the cached libraries. They do not decompress or hash
the payload, acquire an installation lock, start a helper, or require a Dart SDK.
The cache is addressed by native asset content, so Dart-only rebuilds can reuse
it. Missing files trigger repair; concurrent cold launches share one installation.
`HAPPEN_NATIVE_CACHE` overrides the cache directory. The build pins Dart 3.13.7
and verifies the matching upstream Mach-O writer before using it. Its first build
downloads those compiler source files into the build cache; later builds reuse
them. Native assets still come from the existing package hooks.

The verification command copies only the executable into a temporary directory,
runs without a Dart SDK on `PATH`, measures cold/warm launches, checks concurrent
extraction and repair, and executes a fixture-backed task through SQLite and
Code Mode. Reports are written next to the executable. This release target
currently supports macOS arm64 and uses ad-hoc code signing.

## OpenAI request JSON and deterministic comparisons

```sh
# A local Responses API endpoint needs no ChatGPT login.
dart run packages/cli/bin/happen.dart exec --endpoint http://127.0.0.1:8080/v1/responses "task"

# Opt-in exact outbound OpenAI request JSON, one file per transport attempt.
HAPPEN_ROLLOUT_TRACE_ROOT=.local/traces dart run packages/cli/bin/happen.dart exec "task"

# Real Codex against the in-process agent; no Happen CLI build required.
moon run test-e2e
```

`--endpoint` accepts a complete HTTP(S) loopback Responses URL, including its
`/responses` path. It optionally reads `OPENAI_API_KEY`, or the environment
variable selected with `--api-key-env`; an unauthenticated local endpoint is
also supported. ChatGPT credentials are never forwarded to that endpoint.
Endpoint selection applies to this CLI process; supply it again when resuming.

Tracing is off unless `HAPPEN_ROLLOUT_TRACE_ROOT` is set. CLI and in-process
execution use the same capture. A private directory per transport client holds
ordered UUIDv7-named `.json` files. Each file contains exactly the serialized
Responses HTTP body or WebSocket message passed to the transport, including
retries and compaction. There are no prepared-input exports, response dumps,
trace reducers, or reconstructed inference files.

The parity harness captures both harnesses' actual HTTP bodies at the same
receiving OpenAI endpoint. At the end of each session it compares their final
full inference requests with strict deep JSON equality, preserving array order.
The top-level `client_metadata` telemetry field is excluded explicitly: Happen
does not send it, and every case checks that omission on the received requests.
Scoped generated IDs and numeric timing fields are normalized; the original
values remain in raw captures. Message shapes and all other fields remain
strict. Codex's built-in compaction
trace omits transport fields and is not used. The app's internal read-only
context snapshot remains available for inspection; it is not comparison evidence.
Request files contain full context and tool results; authorization headers and
credential values are not recorded. See [the context contract](../test/fixtures/context_contract/README.md)
for deterministic strict comparisons, isolated configs, and real Dart MCP.

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

Create `~/.config/happen/config.yaml` with local commands, remote URLs, or both:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/meoyawn/happen/master/packages/config/schema.json
mcp_servers:
  dart:
    command: dart
    args: [mcp-server, --disable, analysis]
  remote:
    url: https://example.com/mcp
    header_env:
      Authorization: MCP_AUTHORIZATION

```

Use the global `--config PATH` option to select another YAML file, for example
`dart run packages/cli/bin/happen.dart --config /path/config.yaml exec "task"`. Embedded applications
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
summaries enter context. OpenAI keeps declarations in request-level `tools`,
refreshing its code-mode discovery declaration when availability changes; it does
not append incremental declarations to history. OpenAI MCP calls use `mcp__SERVER.TOOL`, and code
mode uses `tools.mcp__SERVER__TOOL`. OpenCode calls MCP tools inside `execute`
through `tools.SERVER.TOOL`, preserving bracket notation for hyphens. Its native
catalog stays fixed; external schemas remain inside Code Mode. Namespace removals
append availability notices, and calls check the live registry. OpenAI compaction
restores current context while the request catalog remains provider-owned. A catalog check
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

### Project-local MCP configuration

Use `.happen/config.yaml` inside a checkout. Repository layers are read from the
checkout root through the selected thread's cwd, with closer settings taking
precedence. Like Codex, table fields merge recursively, while arrays and scalar
values replace. A project can therefore override only `enabled`, `args`, or
selected environment keys of a global server. The final merged server must still
have exactly one valid transport. Explicit relative `cwd` paths resolve beside
the declaring config (`cwd: ..` selects the parent of `.happen/`). A new local
command without a cwd defaults to the invoking cwd; a global command defaults to
the server process's launch directory.

Matching command/arguments, effective cwd and environment reuse one stdio
process, even across global/local entries with different server names. Changing
a binding cancels its pending requests, not unrelated calls on a shared process.
The last config owner releases that process. URL connections do not own a remote
server process.

MCP API requests may supply `threadId` to select its project configuration.
Inventory/status remain read-only thread operations: they do not subscribe,
load a saved thread, or run a model turn. Without a thread/cwd, inventory is
global-only. Project MCP files reload at model/catalog boundaries and on watched
file or executable changes. Other provider settings remain startup configuration.

HTTP servers can use browser OAuth without adding tokens to global config:

```sh
happen mcp list
happen mcp login strength
happen mcp logout strength
```

`login` resolves the named global server, discovers its authorization server,
registers a public client when supported, and opens the default browser. It uses
PKCE S256, a loopback callback, OAuth state and issuer validation, and resource-bound
tokens. The network owner saves and refreshes credentials; existing tasks discover
the connected tools on their next step. The desktop surfaces servers requiring
sign-in inline in the conversation above the composer. **Sign in** opens the
default browser, with waiting, retry and cancellation controls kept in the
conversation. `/mcp` and `/mcp verbose` also offer sign-in and sign-out actions.
Account sign-in (`happen login`) remains separate from MCP server sign-in.
MCP OAuth follows Codex's ordinary standards-based flow only; no ChatGPT
connectors, enterprise connector authorization, or plugin system is enabled.
Discovery uses GET, follows bounded same-origin metadata redirects, and rejects
cross-origin redirects before sending resource credentials elsewhere.

Local subprocess servers use `env` / `inherit_env`. Explicit HTTP `Authorization`
headers take precedence over OAuth. `oauth: false` disables interactive auth for
an HTTP server. Optional `oauth` settings include `client_id` for a pre-registered
client, `client_secret_env`, `token_endpoint_auth_method` (`none`,
`client_secret_basic`, or `client_secret_post`), `scopes`, and `callback_port`.
Otherwise scopes come from the server's challenge/resource metadata, with
`offline_access` added only when the authorization server advertises it.

The CLI owns its MCP connections locally in-process. For a terminal where the
browser should not be opened automatically:

```sh
happen mcp login strength --no-browser
```

Open the printed authorization URL and paste the complete final callback URL
when prompted; input is hidden and does not enter shell or task history. The
callback is accepted only by the client that initiated that login, with the same
state, redirect and issuer checks as the loopback listener. Alternatively, a fixed
`oauth.callback_port` permits SSH forwarding of the loopback callback. Credentials
remain on the Happen server and are not synchronized between machines.

Credentials live under the data directory's `mcp-auth/`, separately from config
and task history, keyed by server name and full URL. Files use private permissions
and atomic replacement, with refresh coalescing and file locks for local processes
sharing that directory. CLI login/logout is observed by an already running desktop
at its next catalog/inventory read. Logout clears Happen's locally saved login.

`packages/config` parses YAML/JSON, validates it against the embedded JSON
Schema, loads files, watches for changes, and merges project layers. Files support
`mcp_servers` only. The server monitors executables and applies validated changes
through its MCP manager, which owns connections and process restarts.
Diagnostics omit config values. Use the
[public schema](https://raw.githubusercontent.com/meoyawn/happen/master/packages/config/schema.json)
in a YAML editor, or export the embedded copy with
`dart run packages/cli/bin/happen.dart config-schema > /path/happen.schema.json`.
Models and reasoning come from the catalog unless explicitly selected through
the CLI, desktop, or thread API. Providers validate thread settings and save the
resolved selection with each thread. Embedders can pass model endpoint URLs
and the public MCP webhook callback URL to `AgentServer.start` or `startEmbedded`.

GPT supports `http` and `websocket` model transports. Its catalog supplies the
model prompt, effort defaults, and context limits. Like Codex, GPT compacts at
90% of the selected context window (or a lower explicit limit), and reports 95%
as usable context unless the catalog specifies another percentage.
DeepSeek supports the native
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

OpenAI's `tools.shell_command({command, workdir?, shell?, login?, timeout_ms?,
max_output_tokens?})` runs to completion, with a 10,000 ms default timeout and no
resumable session. Steering, Stop, or cell cancellation kills its process tree.
`tools.exec_command({cmd, ...})` creates a task-owned session: its process survives
cell cancellation, steering, Stop, and turn completion. `write_stdin` can access
the same session in later turns; cancelling a poll releases the wait and preserves
the session. Use one-shot calls for short commands and sessions for development
servers or other deliberately persistent work.

OpenCode uses `shell({command, background?})`: foreground calls follow their caller,
while `background: true` commands belong to the task. Completed background results
are included at the next model step or turn. An idle task is not sampled just
because its background command completed, and a persistent server does not keep
the turn open. Each call uses its current working directory even when native
tool state was created in an earlier turn.

Idle thread unloading, archive, and server shutdown close task-owned sessions and reap
their processes. Unloading preserves history and permits later turns with fresh
sessions. Session IDs are ephemeral; fork, export/import, and restart never copy
or recreate live processes. A subscribed thread retains its tool runtime between turns.

MCP and client-tool calls always follow their invoking cell or turn. Cancellation
is forwarded to the remote owner, without stopping shared MCP servers or another
task's calls. Remote execution stops only if that owner honors cancellation.
QuickJS cancellation reaches pending host calls and its native interrupt handler;
the task-owned process lifetime is selected separately by the provider runtime.

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

In OpenAI code mode, MCP calls resolve to the complete `CallToolResult`, including
tool failures with `isError: true`. Check that flag before consuming the result,
even after `Promise.allSettled` reports `fulfilled`. Prefer `structuredContent`
when present; `content` text can be ordinary text or an error message, so only
use `JSON.parse` when the tool documents JSON output. Host exceptions reject with
error text, preserving the message when an `allSettled` result is printed.

Nested tool arguments are JSON snapshots taken when the call is made. Later
mutations do not change the host input. Serialization errors, such as circular
objects or BigInt arguments, throw at the call site and can be caught there.

OpenAI cells also expose `as_settled(iterable)` and
`stream_settled(iterable, emit)`. They consume results in settlement order,
including rejections, with `{index, status, value}` or `{index, status, reason}`
records. A Map preserves its keys as `index`; other iterables use input positions.
`stream_settled` awaits each callback. Breaking an `as_settled` loop closes the
iterator; it does not cancel the input promises.

OpenCode follows its own runtime: inside `execute({code})`, call
`await search({query, namespace, limit, offset})`. Query and namespace are optional;
the default page size is 10. Results contain `items` with exact callable `path`,
`description`, and `signature`, plus `remaining` and `next`. Matching scores exact
paths, path words, substrings, descriptions, and parameter metadata. It supports
plural forms and sorts ties by path. This is a catalog snapshot for that execution.
It does not load native schemas. The catalog shares a 2,000-token estimate across
namespaces and always includes pinned entries. MCP server instructions render
separately. File/shell/web tools are ordinary native calls outside `execute`.

In OpenAI code mode, `store(key, value)` saves an explicit JSON snapshot for
`load(key)` in later cells. Completed cells merge their writes into the session,
including writes made before a script error. Observed values persist with the
task; model output includes only what the cell prints. Stored values have no
separate serialized-size cap. OpenAI cells use a 256 MiB QuickJS memory budget;
the one-shot CodeMode API defaults to 32 MiB. Retaining large results increases
the memory needed by later cells.

## Web search

OpenAI defaults to Codex's standalone web search. With the catalog's Code Mode
only default, call `tools.web__run` inside `functions.exec`; mixed mode also
exposes `web.run` directly. Search requests go to OpenAI's `/alpha/search`
endpoint, and their results reach durable history and subsequent model input.
Set `providers.openai.settings.web_search` to `disabled` to omit it; the default
is `live`. No separate standalone-search setting is needed.

The tool uses OpenAI's parameter schema:
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
public text/HTML directly without Console credentials. Standalone OpenAI search can also use opaque
references returned by its hosted reader and forwards its full command set to
that service. Neither provider advertises the other's web interface.

When the standalone OpenAI reader reports that a requested source URL is inaccessible,
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

## Clock and goal tools

OpenAI exposes `clock.sleep` directly, outside JavaScript code mode, following the
current Codex model-driven default. `duration_ms` must be an integer in
`1..43200000`. Steering interrupts sleep with a successful interruption receipt;
Stop cancels the turn. `providers.openai.settings.sleep_tool: false` disables it.

Goal tools are always enabled for saved OpenAI threads: `get_goal`, `create_goal`, and `update_goal`
are available inside `functions.exec`. Goals require an explicit user request.
Their objectives, status, optional token budget, noncached token usage, and active
elapsed time are persisted by the task's existing storage owner. Unfinished goals
cannot be overwritten, and pausing cannot bypass an exhausted budget.
There is no goals-disable option in global configuration. Ephemeral threads,
including side conversations, do not support persistent goals.

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

Repository and global instructions are refreshed before each model step, including
after tools run within a turn. Repository snapshots stay cached while candidate
file metadata is unchanged; checks include missing override files, symlink targets,
and the current ancestor chain. Edits, additions, deletions, and editor rename saves
are picked up without restarting or changing `cwd`. No idle filesystem watchers or
extra model turns are started. The server retains at most 256 lightweight snapshots
in least-recently-used order. Idle agent isolates and database owners are still released.

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
dart run packages/cli/bin/happen.dart login --provider opencode
```

Open the displayed URL in your signed-in browser, confirm the device code, and
authorize the workspace. The DeepSeek package saves `opencode-auth.json` privately
and refreshes its own tokens. It does not require the OpenCode executable or use
the CLI's refresh token.

Select an OpenCode model in the desktop composer, or use `--provider opencode` with the CLI.
Run `dart run packages/cli/bin/happen.dart exec --provider opencode "Complete this task"`.
The route uses Chat Completions, with a 200,000-token context and a maximum output
of 32,000 tokens from the recorded OpenCode catalog. The exact free model is required;
there is no automatic paid fallback. Native DeepSeek remains available with
`deepseek-flash` and `DEEPSEEK_API_KEY`. The desktop offers the `opencode`
subscription account directly.

Login and model availability are separate. In the recorded live check, Happen's
device authorization succeeded, but its authenticated inference request received
`FreeUsageLimitError` (HTTP 429). The OpenCode CLI returned `READY` for the same
model. Happen reports `free_usage_limit` for that hosted denial; live tool execution
through this route is still unverified. See the [evidence](evidence/deepseek-console.json).

## WebSocket API

Requests are JSON objects with `id`, `method`, and `params`. Replies contain the
same `id` and either `result` or `error`. Notifications use `method` and `params`.
Initialize each connection with `initialize` and `clientInfo: {name, version}`.
The desktop uses native Codex-style threads, turns, and typed items, not OpenCode
projections. `turn/completed` carries the terminal turn's `completed`, `failed`,
or `interrupted` status. Happen extensions use `happen/…` notifications.

| Thread operation | Parameters and behavior |
| --- | --- |
| `thread/start` | Optional `cwd`, `provider`, `model`, `settings`, `developerInstructions`, `dynamicTools`, `ephemeral`. Creates and subscribes to a thread; returns `thread` and configuration. |
| `thread/resume` | `threadId`, optional `excludeTurns`. Loads a saved thread and subscribes this connection. Warm resume preserves cached status. |
| `thread/read` | `threadId`, optional `includeTurns`, `watch`. Reads history without loading execution. Happen's `watch: true` also forwards live items on this connection without retaining a runtime; `watch: false` stops that watch. |
| `thread/loaded/list` | Returns currently loaded IDs, including unsubscribed threads awaiting their idle deadline. |
| `thread/list` | Pages saved thread summaries. |
| `thread/name/set` | `threadId`, `name`. Persists a nonempty name and broadcasts `thread/name/updated` to every connected client. Explicit names take precedence over background generation. |
| `thread/items/list` / `thread/turns/list` | `threadId`, optional opaque `cursor`, `limit`, and view/direction options. Reads native history without loading it. |
| `thread/unsubscribe` | `threadId`. Removes this connection's execution subscription and transcript watch; returns `unsubscribed`, `notSubscribed`, or `notLoaded`. Never cancels a running turn. |
| `turn/start` | `threadId`, `input`, optional `effort`, `delivery`. Starts or queues input and subscribes this connection. |
| `turn/steer` / `turn/interrupt` | `threadId`, `expectedTurnId` and `input` for steering, or `turnId` for interruption. |
| `thread/fork` | `threadId`, optional stored SQLite `path`, `lastTurnId` or `beforeTurnId`, `excludeTurns`, `model`, `modelProvider`, `cwd`, `settings`, `reasoning`, `baseInstructions`, `developerInstructions`, `ephemeral`. Structurally shares the selected immutable prefix and subscribes the caller to the new thread. |
| `thread/archive` / `thread/unarchive` | `threadId`. Archives/restores metadata in place without moving history. Archive drains active work, detaches every client subscription, and releases thread-owned resources. |
| `thread/goal/get` / `thread/goal/set` / `thread/goal/clear` | `threadId`; set accepts partial objective/status/budget changes. |

Forks inherit the saved name and effective configuration; overrides apply to the
child. `lastTurnId` includes a terminal turn, while `beforeTurnId` excludes its
turn and everything after it. Omitting both freezes the latest prefix, marking
any unfinished turn interrupted only in the child. The response precedes restored
token usage and the global, metadata-only `thread/started` notification.
`excludeTurns` skips usage replay and allows history to be paged separately.
Ephemeral forks require `excludeTurns: true`, remain pathless, and stay out of
saved thread listings.

History items expose Happen's `order` field from their canonical rollout position,
including items embedded in full turns and turn summaries. Clients retain that
order across pages; timestamps do not determine transcript order. Snapshot
`liveItems` contain unfinished items, and `notificationThrough` is captured before
the history read so later notifications remain replayable.
Desktop opens unarchived history with `watch: true` before that watermark is
captured. This keeps event-triggered turns visible after reconnecting, including
their event input, streamed replies, tool activity, and questions. Watches survive
runtime unloading and end on unsubscribe, archive, or connection close. They do
not load a thread, resume a goal, start inference, or delay idle unloading.

Happen uses Codex's default 60-second idle unload delay. A full delay must elapse
after both turn activity and the final subscriber are gone. Resubscription
cancels the countdown; turn completion starts a fresh countdown when nobody is
subscribed. Disconnect removes that connection's subscriptions. Unloading emits
`thread/closed` and `thread/status/changed` with `notLoaded`; cold resume reloads
saved history. Ordinary ephemeral threads use in-memory SQLite and cannot resume
after unloading. The native wire's per-thread `config.thread_unload_delay_secs`
override is runtime-only; it is not restored by a cold resume. Happen does not
import Codex's global configuration schema.

| Session read | Parameters and behavior |
| --- | --- |
| `session.context` | `sessionID`, optional opaque `cursor`, `limit` (1–200). Reads the agent's actual normalized model buffer and request envelope. Returns chronological `input`, `instructions`, `tools`, frozen `settings`, `effectiveReasoning`, `inputCount`, counts, token/cache usage, context limit, `through`, `sourceThrough`, `windowID`, and `snapshotID`. `cursor.next` appends the next input page from the same immutable snapshot, even if execution or compaction changes the live context. |
| `session.read.cancel` | `request_id` of a pending session read on this connection. Cancels snapshot/replay work without interrupting the session writer or execution. |

| Git operation | Parameters and behavior |
| --- | --- |
| `git/status` | `cwd`. Discovers the checkout and returns `isRepo`, `host`, `root`, `branch`, `head`, `upstream`, `remote`, `ahead`, `behind`, changed `files`, and total `additions`/`deletions`. Each file includes `path`, optional `previousPath`, porcelain `status`, conflict/binary flags, and line counts compared with HEAD, including untracked files. |
| `git/branches` | `cwd`. Returns local and remote branches as `{ref, name, remote}` records. |
| `git/diff` | `cwd`, `path` from the changed-file list. Returns that file's metadata, unified `diff`, and `truncated` flag. Reads one file at a time without changing the index. |
| `git/run` | `cwd`, unique `actionId`, and `action`: `commit`, `push`, `commit_push`, `switch`, or `create_branch`. Commits accept optional `commitMessage`, `filePaths`, `provider`, and `model`; empty messages are generated without a conversation turn. Switching accepts a full `branch` ref from `git/branches`; creation accepts a new branch name. One write runs per checkout. |
| `git/cancel` | Notification with `requestId` of the pending Git request on this connection. Cancels its subprocesses and model request without interrupting an agent turn. |

`git/progress` notifications contain `actionId`, `cwd`, workflow `phase`
(`generating`, `committing`, `pushing`, or `switching`), a display `label`,
and optional subprocess `output`. After a successful commit, push progress and
the final action result include its `{sha, subject}` receipt. A push failure
returns `status: "failed"` and `message` while retaining that commit receipt;
retrying `push` does not create another commit. Successful writes return
`status: "completed"` after Git confirms completion. Cancellation does not undo
a completed commit; refresh `git/status` to reconcile the checkout.

| Inbox operation | Parameters and behavior |
| --- | --- |
| `session.inbox` | `sessionID`. Reads durable pending inputs in admission order. |
| `session.inbox.update` | `sessionID`, `inboxID`, `delivery` (`steer` or `queue`). Changes a pending input in place and emits `session.inbox.delivery.changed`. Steering an idle session starts that input. |
| `session.inbox.cancel` | `sessionID`, `inboxID`. Deletes only that pending input and emits `session.inbox.cancelled`, without stopping the active execution. |

Inbox mutations reject inputs that have already started or been delivered.
The writer rechecks offers before committing them, so a late mailbox
offer cannot deliver a deleted input or ordinary input moved to the queue. Changes
preserve attachments, creation time, reasoning choice, and admission order.

Each session stores canonical Codex RolloutLines, native projections, and its durable inbox in
one `tasks/<sessionID>/history.sqlite`. Its writer updates them in one transaction.
Independent read-only connections take WAL snapshots without acquiring a writer.
Canonical writes and projections share one outer transaction; a projection
savepoint protects canonical durability if materialization fails.

Tool state uses namespaced JSON KV (`get`, `set`, `remove`,
and ordered, prefix-paginated `scan`) in the `kv` table of that same session SQLite.
There is no separate state database. Callers own their namespaces and validation;
goal state uses dedicated tables in that same database. Forks inherit goal
progress while deferring automatic continuation until explicit input.

Context inspection does not read the message/part projection. A running agent
serializes the same buffer and envelope used by inference. Unloaded sessions
restore through that same agent initialization path, without admitting a turn,
refreshing repository/skill/tool context, or calling a provider. Completed model
output and tool results enter the buffer only after their durable commit;
uncommitted streaming deltas and queued inputs do not enter it. Compaction
replaces the buffer, including its native provider state.

Context cursors belong to their WebSocket connection. At most four unfinished
inspection snapshots are retained per connection; completing pagination or
disconnecting releases them. An evicted cursor returns an explicit expiration
error and requires a fresh read. Context pagination runs forward, unlike
transcript pagination. This is normalized model history, not a provider-specific
HTTP wire-body dump.

OpenAI sessions use the model catalog's Responses Lite defaults. Tool declarations
enter history as `additional_tools`, followed by the developer base prompt.
Requests omit top-level `tools` and `instructions`, set `parallel_tool_calls` to
false, and use `reasoning.context: "all_turns"`. Unchanged turns retain that prefix;
tool changes append only their delta, and compaction restores one current prefix
at the front. The selected reasoning effort is retained as a configuration update
and reasserted when a cold runtime begins inference.
Initial repository, environment, skill and deferred-tool context precedes the
real user prompt in both the model buffer and durable history.
Synthetic messages preserve their model role and harness context classification.
Completed Responses stream items are retained even when the terminal completion
packet has an empty output summary. `end_turn: false` continues inference after
commentary instead of completing the session before its tool calls run.
The desktop inspector fetches every page of one agent snapshot and serializes
it through the inference adapter. Its JSON export contains only that request:
OpenAI Responses `input`, native `tools`, and request settings, including the
base prompt as the first developer message. Internal snapshot accounting and
transcript projections are not included in the desktop export.

Task operations acknowledge admission before emitting their durable events;
wait for `turn/completed` to learn the outcome.

Task IDs are opaque strings generated by the task's provider. New `openai`
tasks use Codex-style hyphenated UUIDv7 IDs; `opencode` and `deepseek` tasks use
OpenCode-style `ses_` IDs. Forks and imports receive fresh IDs from the provider
saved in their source history. Existing task IDs remain valid. An import's
optional `operation_id` is a separate retry key: concurrent or later retries,
including after a server restart, return the same imported task ID.

Turns and model/compaction calls have no cumulative wall-clock deadline or model
step limit. Stop cancels turn-owned work; idle unloading,
archive, and server shutdown also close task-owned sessions. Quitting the desktop
stops its embedded server. GPT HTTP/SSE and WebSocket
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
The shared Dart `HttpClient` manages HTTP/1.1 connections with its default
15-second idle timeout. Request cancellation leaves other responses running.
A GPT `response.created` acknowledgement emits ephemeral
`model.connected` with `task_id` and `turn_id`, clearing reconnecting progress
while the accepted request is processing, even before any text arrives.

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
| `task.cancel` | `task_id`. Cancels the turn and caller-owned tools; task-owned sessions survive. |
| `task.archive` / `task.unarchive` | `task_id`. Stops work and archives a task, or restores it. History is retained. |
| `task.subscribe` | `task_id`. Subscribes this connection to future task events and returns `running` and pending inputs. |
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

Saved canonical records, metadata, and native projections use the same writer
and transaction. Missing projections rebuild from canonical records in bounded
batches; they are never the authoritative history.

Steer messages cancel active inference, cells, and caller-owned tools, then join
the same turn before its next model request. Task-owned sessions survive. Queue messages
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
expire archived conversations or delete project files. Agent isolates release
after each turn; loaded threads retain their SQLite writer and tool state until
idle unloading, archive, or shutdown. Telemetry includes active/resident task,
connection, pending-message, and maintenance counts for monitoring long runs.

The model is fixed for each task. GPT effort updates are appended to history;
DeepSeek effort is fixed. Automatically loaded `AGENTS.md` snapshots are restored
after compaction. Compaction keeps the full durable transcript available through
code mode's `history__list_windows`, `history__list_items`, `history__read_item`,
and `history__search_contents`. Forks and imports preserve historical item IDs.

Outbound messages drain through one ordered writer, bounded to 32,768 queued
frames and 64 MiB. There is no application-level acknowledgement protocol.
Clients exceeding either backlog bound disconnect; reconnect, resume, and page
native history to reconcile. Thread notification subscriptions belong to the
connection; server-hosted MCP event subscriptions have a separate lifetime.

The desktop opens saved history through read-only calls, without loading or
subscribing to execution. Threads have no tab-close lifecycle: archive releases
their transcript, pending reads, panels, terminals, and temporary side chats.
Archived previews release their cached history when dismissed; restore keeps
history read-only until execution is explicitly started again.

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

## MCP requests and caller input

Clients that can present MCP input opt in on each connection with
`client.capabilities {"mcp_inputs": true}`. This is separate from model questions
and is not saved in thread/provider settings. Without a capable caller, an input
request fails; the backend never supplies an answer, opens a URL, or creates a
device proof automatically.

`mcp.request` supports tools, resources, prompts, and event discovery/polling.
Optional `threadId` selects the saved project scope; optional `read_only: true`
sets host-owned `openai/readOnly` metadata that caller metadata cannot override.
Form (`elicitation/create`, `openai/form`, `openai/elicitation/create`), URL, and
native `openai/userVerification` requests use the same continuation driver.

| Method/event | Payload |
| --- | --- |
| `mcp.input.requested` event | `request_id`, `source`, `request: {method, params}`, and `threadId` for agent-owned input. Treat display text, schemas, URLs, and metadata as untrusted server data. |
| `mcp.input.list` | Optional `threadId`; returns only this client's authorized pending requests. Use after subscribing/reconnecting to a running thread. |
| `mcp.input.reply` | `request_id`, `response: {action, content?, _meta?}`. `action` is `accept`, `decline`, or `cancel`. Only one reply wins. |
| `mcp.input.closed` event | `request_id`, optional `threadId`; remove the pending prompt whether answered, cancelled, or failed. |

A public request belongs to its exact client connection. An agent request can be
answered only by an opted-in client subscribed to its thread. Cross-client or
cross-thread replies are rejected. Disconnect cancels that client's public
request, not shared MCP connections or other callers. Stop cancels the invoking
agent's requests. Input is transport interaction, not a new model message or
transcript item.

Native verification accepts only bounded `credentialId`/base64url `signature`
proofs supplied by the caller; invalid proofs become cancellation. Cancel/decline
discard proof material and retain only a recognized verification reason.
Human-input waits pause only that call's active-time timeout. All wire rounds
share its remaining budget and use fresh IDs, with a ten-request continuation
bound. Opaque `requestState` is preserved verbatim. Once an input is answered,
failure cannot cause session recovery or transient replay of that operation.
Sampling and roots are not advertised.

## MCP Events

The core protocol is `2026-07-28`; Events follows the pinned experimental draft
listed in [decisions.md](decisions.md). Push, polling, and signed webhooks are
implemented. Discovery and event delivery are distinct from model execution.

| Method | Parameters |
| --- | --- |
| `mcp.status` / `mcp.reload` | No parameters. |
| `mcp.inventory` | Optional `verbose` boolean (default false) and `server` name. Read-only server inventory, including disabled entries. |
| `mcp.inventory.cancel` | Notification with the inventory call's `request_id`; cancels only that request. |
| `mcp.auth.login` | `server`, `login_id`. Emits a private `mcp.auth.login` event containing the browser `url`; returns the connected state/tool count. Five-minute deadline. |
| `mcp.auth.login.cancel` | Notification with `request_id`; cancels this client's pending auth request and its callback listener. Disconnect also cancels it. |
| `mcp.auth.callback` | `server`, `login_id`, `callback_url`. Completes this connection's own pending login without requiring the browser to reach the server's loopback listener. |
| `mcp.auth.logout` | `server`. Deletes local OAuth credentials and reconciles the shared connection. |
| `mcp.request` | `server`, `method`, optional `arguments`, `threadId`, `read_only`; supports tools, resources, prompts, and event discovery/polling. |
| `mcp.input.list` / `mcp.input.reply` | Caller-authorized pending input and replies; see [caller input](#mcp-requests-and-caller-input). |
| `mcp.events.subscribe` | `server`, `name`, optional `arguments`, `mode` (`push`, `poll`, `webhook`), `cursor`, `max_age_ms`, `ttl_ms`, `threadId`. |
| `mcp.events.subscriptions` | Optional `threadId`; lists that thread's server-owned subscriptions, or this connection's subscriptions if omitted. |
| `mcp.events.unsubscribe` | `subscription_id`, and `threadId` for a thread-owned subscription. |

`mcp.inventory` returns `{servers: [...]}` sorted by name. Each row contains
`name`, `enabled`, `state`, `auth_status`, `oauth_supported`, `tool_count`, and an optional sanitized
`error`. Configured HTTP headers are reported as `configured_headers`, without
their values; this does not claim successful authentication.
HTTP 401/403 is `not_authenticated`; saved OAuth is `oauth`, and an active login
is `signing_in`. Other connections report `unsupported`. Auth changes emit a
credential-free `mcp.auth.changed` event containing only the server name.
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
ends the subscription. Without `threadId`, subscriptions belong to the connection
and disconnect cancels them; these events are display-only. With `threadId`, the
running server owns the subscription, independently of desktop connections.
An event occurrence cold-loads its saved thread, durably queues untrusted user
input, and runs it according to the existing conversation instructions. During an
active turn, events enter the next model request without cancelling running tools
or inference. Ordinary queued messages still wait for the next turn.
Activation, heartbeat, empty polls, gap, verification,
termination, invalid signatures, and duplicates never start a turn. Normal idle
unloading applies after event processing. Thread ownership is local metadata,
not an extra parameter sent to the upstream MCP server. Archive stops the thread's
subscriptions. Webhook `2xx` waits for durable inbox admission; inbox pressure
returns `503` and retrying the same occurrence remains safe. A bounded receipt
joins that admission's transaction rather than adding a second commit.
Thread-owned desired subscriptions and cursors are saved in that thread's
existing SQLite file and restored automatically across server-process restart,
including its saved project-local MCP configuration. One server-owned writer
maintains `server.sqlite`: a shared `threads` metadata catalog for listings and
archive filters, plus the recovery owner IDs in `mcp_event_threads`. Startup
queries that index, checks each indexed thread's archived state and private
checkpoints, and reconnects unarchived owners independently. Fresh installations
initialize an empty catalog; startup never enumerates history folders.
Managed writes journal a thread ID before changing its canonical history and
update the catalog after commit. Startup repairs only those journaled IDs if a
process stopped before catalog synchronization.
An index entry commits before a subscription or occurrence can be admitted, so a
crash can leave an extra candidate but cannot hide committed recovery work.
Removal preserves an owner while acknowledged event input remains pending;
archive removes it after the thread's archive commit. The index contains no
credentials or callback secrets. Polling starts afresh after relaunch rather than
persisting the previous process's sleeping timer. Restoration alone does not
load the thread or run a model. A previously acknowledged, still-pending inbox
event is resumed without waiting for a new occurrence. Unsubscribe, archive and
provider termination remove desired state durably; ordinary connection-owned
subscriptions are not restored. Webhook callback IDs and signing secrets remain
private host state, excluded from inventory, model history and portable exports.
An expired provider registration may receive a fresh remote ID on restoration;
the new authenticated grant then pins that identity.

Transient polling failures keep the watch in `reconnecting`, retaining its saved
cursor. Retries continue with bounded backoff and honor provider `retryAfterMs`
advice; subscription status exposes the latest sanitized `error` until recovery.
Unsubscribe cancels a sleeping retry. Provider termination still removes desired
state. Restoring an already failed runtime replaces that runtime using its saved
subscription ID and cursor.

Webhook delivery requires the embedding host to pass an HTTPS `publicUrl` to
`AgentServer.start` or `startEmbedded`, routed to this server's `/mcp-events/...`
callback paths. The server verifies webhook
signatures and timestamps before delivery; signing secrets remain in private
host state. The ordinary SSH port-forward setup supports push and polling without a
public webhook endpoint.

See [verification.md](verification.md) for executable checks and measured limits.
