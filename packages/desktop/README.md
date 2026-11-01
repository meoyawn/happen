# desktop

Happen desktop client

The conversation uses OpenCode's message model and presentation, with Inter and
IBM Plex Mono fonts, compact spacing, and its working indicator. Nested tool calls
appear inline; **View code** opens the JavaScript source.
Hover a finished OpenCode response to copy it or see its model, reasoning level,
and turn duration, rounded to seconds (or minutes and seconds for longer turns).

**Settings → Interface** offers **Top tabs**, **Side
tabs**, and **Inbox**, using OpenCode's layout previews. Top and side tabs can
be dragged to reorder or closed without archiving their sessions. **Home** and
**Search sessions** reopen them. Inbox groups recent results and sessions that
need attention, with a collapsible **Working** section below. Tab order, layout,
read markers, and sidebar choices are saved.

The macOS window uses its full content area. The native traffic lights sit in
the sidebar header in Side tabs and Inbox, or beside the top tabs. Drag empty
header space to move the window; double-click follows the macOS title bar setting.
Click the sidebar icon or press **⌘⇧B** to collapse or reopen the sidebar. While
collapsed, hover the window's left edge or rest on the icon to preview it over
the conversation. On Windows/Linux, use **Ctrl+Shift+B**.

Live responses reveal incoming text on display frames, updating only the
streaming message. Images reserve their thumbnail space before loading, and
each horizontal image rail retains its own scroll position.

Drag the sidebar's right edge to resize it. The chosen width is saved between
launches and adjusts to keep room for the conversation in a smaller window.
The edge has OpenCode's delayed pill on hover and a darker pill while dragging.

**⌘J** opens and focuses the integrated terminal in the current project's folder.
Repeated presses focus the same shell. The panel retains shells separately for
each chat or project draft; hiding it or switching chats keeps them running.
Use **+** for another shell, **×** to stop one, and the down arrow to hide the
panel. Drag its top edge to resize it. Archiving immediately stops all of that
chat's terminals, including hidden tabs and background jobs; restoring the chat
starts fresh shells.
A draft's terminals follow its first submitted task. Hibernating the agent leaves
the terminal alone. Removing a project or quitting closes its shells and drains
native resources. On Windows/Linux, use **Ctrl+J**.

**Option+Up/Down** moves between sessions in the current navigation view.
Conversation drafts are retained while navigating.

Use a project's **… → Remove project** menu to remove it and its task entries
from Happen. Confirming stops running tasks and clears drafts; the project folder
and saved task history are kept. Missing folders are greyed out when Happen
launches, with new tasks and messages disabled while existing conversations remain
readable. Availability is checked at launch, without polling or a refresh button.
Open a restored folder again to make its existing project available.

The header's context ring opens **Context** in OpenCode's full-height right panel,
beside the conversation and composer. **⌘B** (or **Ctrl+B**) toggles the panel;
drag the divider to resize it. The tab strip supports closing, adding, and
reopening tabs, and **⌘W** closes the focused panel tab. Open tabs, selection,
visibility, and the divider width are saved per session. Hiding the panel keeps
its content and scroll position; closing its last tab hides it.

**Context** shows the actual saved system prompt,
provider/model, context limit, token and cache counts, tools, model settings, and
expandable projected session messages. For OpenAI sessions the base prompt
is a developer context item, as in Codex, rather than a second system copy.
Earlier context pages load on demand. **Export session JSON** saves a JSON file
to Downloads with a unique title-based filename. It exports each message body once;
context metadata references its base prompt
by message ID instead of embedding the message page and prompt again.
Usage becomes available after a
response measures the current context, including after compaction.
The composer groups the model/reasoning menu, microphone, and Send/Stop.
The model/reasoning menu keeps models fixed for existing tasks; supported reasoning
changes apply to the next message.
One action button sends messages, or stops a running task when the draft is empty.
With a draft or attachments during a running task, it steers or queues the message
according to Settings.

Servers requiring MCP authentication appear inline in the conversation above the
composer. Choose **Sign in** to open the default browser; waiting, retry and
cancellation stay in the conversation. Successful connection removes the request
and makes tools available on the next model step without changing the draft.

Type `/mcp` and press Enter to view MCP server status in the composer popover.
Use `/mcp verbose` for tool names, resources, and resource templates. Both use
the same popover as `@` file search. HTTP OAuth servers offer **Sign in**, which
opens your default browser, and **Sign out** after connection. Cancel stops a
pending login; Open browser retries launching the browser. Type to filter,
press Escape to close, or start a new `@` mention to switch back to files.
Commands preserve surrounding draft text and run without sending a message.

On macOS and Windows, closing the window keeps Happen and its embedded server
running. The tray menu has **Show** and **Quit**. Show restores and focuses the
window; Quit shuts down the server and exits the process. The macOS Dock also
reopens the hidden window.

With the window focused, press **⌘Q** on macOS or **Ctrl+Q** on Windows to show
a dark translucent quit hint, then press it again within one second to quit.
The hint fades out over 200 ms. Holding the key does not confirm. Escape, another
key, clicking, or switching away cancels the confirmation. Clicks continue to
the window underneath. The tray's Quit action quits directly.

The server stays in the desktop process on every platform. macOS/Linux use
private UDS WebSockets; Windows uses an ephemeral authenticated loopback port.
Native tray changes require a rebuild and relaunch.

Session events and message parts use the OpenCode schema shared by the server,
SQLite projection, and Flutter renderer. Every session keeps one `history.sqlite`
file with a single writer isolate and independent read-only WAL snapshots.
The durable inbox is in that same database. Existing histories are projected by
their session writer when first opened; live notifications use the same events
as replay. WebSocket RPC, event acknowledgements, and backpressure remain the
transport. Provider inference and credentials still support ChatGPT and OpenCode.

Paste images with Command+V or Paste in the composer, or drag images and files
onto it. Preview or remove attachments before sending; image-only messages work.
Failed sends keep the draft and attachments. A native rebuild installs the macOS
clipboard bridge and drag-and-drop plugin.

The embedded server reads local image paths and applies Codex's image sizing.
For remote connections, the desktop accepts originals up to 1 GiB and prepares
oversized images off the UI thread to fit the combined 32 MiB encoded image
budget before sending. Smaller originals stay unchanged when they fit. Ordinary
remote files upload in blocks of up to 24 MiB; local files remain path references.
Cancellation preserves the draft. Saved conversations retain prepared image
bytes. Remote server selection remains outside the current desktop UI.

Images inspected by the agent appear as a collapsed **Viewed an image** or
**Viewed N images** activity in the conversation. Expand it to reveal the
thumbnail rail, then click a thumbnail to inspect and zoom inside Happen.
The saved activity contains the same prepared image bytes sent to the model.
OpenAI uses `image(...)` with MCP image blocks or `tools.view_image(...)`;
OpenCode's `read` and MCP tools present images directly to the model.

The Windows runner and QuickJS build path target x64. In addition to Flutter's
Visual Studio tooling, the Windows QuickJS build uses
[MSYS2 UCRT64 GCC](https://www.msys2.org/docs/environments/), defaulting to
`C:\msys64\ucrt64\bin\gcc.exe`. A different installation can be selected in the
workspace root `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    code_mode:
      mingw_cc: 'D:/msys64/ucrt64/bin/gcc.exe'
```

This compiler is only needed when building on Windows. macOS/Linux keep the
existing native build path.

On macOS, click the composer's microphone to dictate with the local ChatGPT
account. The editor stays editable while the mic shows its recording waveform.
Settings opens a separate screen with a saved Dictation mode: **Live** (the
default) shows text while you speak; **On stop** inserts it after recording.
Live mode falls back to transcription on stop if its connection fails. Each
recording keeps the mode it started with. Stop finishes the transcript; Enter
or Send finishes and sends. Escape or Cancel discards the recording and restores
untouched dictated text. Failed transcription keeps the audio for Retry;
changing chats cancels the old attempt.

Audio is uploaded directly from the desktop to OpenAI. The local backend only
supplies authentication, independently of the task's selected model/provider.
Audio stays in memory and is cleared after completion or cancellation. A native
rebuild is needed to install the microphone bridge and permission description.

Tasks have no elapsed-time or step limit. GPT reconnects interrupted model
streams with bounded retries, and the conversation shows reconnection progress
and terminal failures. Stop or archive a task to end it. The embedded server
runs inside Happen, so quitting the application stops its work.

From the repository root:

```sh
flutter pub get
moon run dev -- --status
moon run dev
```

The guarded launcher reuses any running Happen app, including installed releases,
or a Flutter supervisor for a Happen checkout in any build mode. This also covers
Flutter while it is still building. Concurrent launcher calls share a lock across
checkouts. If several instances already exist, it reports their PIDs and exits
without starting another. Use this launcher for development launches.

`dev` is a persistent, interactive Moon server task. New sessions run Flutter in
the foreground with live output: press `r` to hot reload, `R` to hot restart,
or `q` to quit. Ctrl+C stops the session. The command stays open until Flutter
exits and returns its exit status.
Reusing an existing session waits for it to exit and keeps its original
terminal/VM controls. `moon run dev -- --status` only inspects and exits.
Checkout locks and supervisor metadata stay in the ignored `.local/run/`;
the shared launch lock stays in the system temporary directory. They are never
added to the app bundle.

```sh
moon run release
moon run release-reinstall
```

`release` directly runs `flutter build macos --release` under this package,
producing `build/macos/Build/Products/Release/Happen.app`. It creates no workflow
logs or locks and performs no process inspection or reuse. `release-reinstall`
builds first, stages and verifies the bundle, and installs it at `/Applications/Happen.app`.
It stops the installed release before replacing the bundle and leaves it
stopped. Failed replacement validation restores the previous bundle and leaves
it stopped too. `reinstall-release` is an alias.

The development launcher also reuses a running release instead of starting a
debug app alongside it. Reinstallation preserves the debug app and checks the
release executable's full path immediately before signalling it. For a different
installation directory, use
`moon run release-reinstall -- --applications-dir /path/to/Applications`.
The guard applies to these local launch/install commands; launching the app
directly bypasses it.

The composer uses a virtual line editor with a bounded viewport for large
drafts. Its completion popover follows OpenCode, including file and folder icons
for each language and special filename. Up/Down changes the selected suggestion
without moving the caret; Enter or Tab accepts it, and Escape closes the popover.

Type `@` to find project files and folders, projects, other sessions, MCP resources,
and MCP tools. Quoted queries support paths containing spaces. File references
retain their full path and serialize as Markdown links; they do not upload file
contents. Session references include the text from up to 20 recent messages.
The **+** menu opens context search, commands, prompt history, or attachments.
**Shift+Up** opens searchable prompt history for the current session.

Type `/` for local commands, model choices, reasoning levels, and skills. Model
and reasoning choices follow the same availability rules as their picker.
`/new`, `/context`, `/terminal`, `/history`, and `/attach` open their respective
actions; `/mcp` and `/mcp verbose` show server status and inventory.

Type `$` to search skills, or find them alongside files with `@` and commands
with `/`. Skills come from the server's project and user `.agents/skills/`
directories. Suggestions show the name, description, and Project or Global
scope. Select one with Up/Down and Enter or Tab, or click it, to insert an inline
skill reference. Escape dismisses suggestions. Selection preserves the full
`SKILL.md` path through editing, undo, copying, and draft navigation; sending
serializes it as `[$name](/path/to/SKILL.md)`. References appear as blue labels in
the editor, with a skill glyph in suggestions. Discovery returns metadata only; the agent
loads the skill instructions when needed.

Mention search waits for a 120 ms typing pause, caches up to 20 recent queries for ten
seconds, and cancels superseded requests. Late replies cannot change a newer
draft or another task's composer. File search shares the task WebSocket and
remains available while other tasks are streaming.

The macOS build normalizes bundled native asset paths to their framework install
names. This works around [Flutter #190799](https://github.com/flutter/flutter/issues/190799),
which can load SQLite twice when rebuilding while the app is running. The step
is harmless on SDKs that already contain the upstream fix. Stop and relaunch
Happen once after applying this change; hot reload cannot repair existing mappings.

Verify the built SQLite framework across file replacement without changing the
application or its data:

```sh
flutter build macos --debug --no-pub
dart --disable-dart-dev tool/verify_native_assets.dart
```
