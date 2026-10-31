# desktop

Happen desktop client

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

New sessions run in the background and return their PID, log, and input pipe.
For a session started by the launcher, hot reload with
`printf r > .local/run/flutter-input`; use `R` for hot restart and `q` to quit.
An existing session started elsewhere keeps its original terminal/VM controls.
Logs, locks, and supervisor metadata stay in the checkout's ignored `.local/run/`;
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
