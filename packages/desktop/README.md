# desktop

Happen desktop client

Drag the sidebar's right edge to resize it. The chosen width is saved between
launches and adjusts to keep room for the conversation in a smaller window.

Use a project's **… → Remove project** menu to remove it and its task entries
from Happen. Confirming stops running tasks and clears drafts; the project folder
and saved task history are kept. Missing folders are greyed out when Happen
launches, with new tasks and messages disabled while existing conversations remain
readable. Availability is checked at launch, without polling or a refresh button.
Open a restored folder again to make its existing project available.

The composer's right side groups the context ring, one model/reasoning menu,
microphone and Send/Stop. Hover or click the ring for used/available tokens and
prompt-cache hit rates for the latest response and the conversation. Missing
measurements show **Usage unavailable**, including after compaction until a new
response measures the replacement context. Existing chats need no migration.
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

The guarded launcher reuses the running debug app or its Flutter supervisor,
including while Flutter is still building. Concurrent launcher calls share a
local lock. If several instances already exist, it reports their PIDs and exits
without starting another. Use this launcher for development launches.

`dev` is a persistent, interactive Moon server task. New sessions run Flutter in
the foreground with live output: press `r` to hot reload, `R` to hot restart,
or `q` to quit. Ctrl+C stops the session. The command stays open until Flutter
exits and returns its exit status.
Reusing an existing session waits for it to exit and keeps its original
terminal/VM controls. `moon run dev -- --status` only inspects and exits.
Locks and supervisor metadata stay in the checkout's ignored `.local/run/`;
they are never added to the app bundle.

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

Debug and release have separate instance checks, so one of each can run.
Reinstallation preserves the debug app and checks the release executable's full
path immediately before signalling it. For a different installation directory,
use `moon run release-reinstall -- --applications-dir /path/to/Applications`.
The guard applies to these local launch/install commands; launching the app
directly bypasses it.

Type `@` in a new or existing task's composer to search files in the selected
project on the server. Use Up/Down and Enter or Tab, or click/tap a result; Escape
dismisses suggestions. Paths containing spaces are quoted. Selecting a file
inserts its relative path into the draft; it does not upload its contents.

Search waits for a 200 ms typing pause, caches up to 20 recent queries for ten
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
