The server runs as one detached, PID-managed daemon per Linux user and data directory, shared by all desktop connections. It uses no systemd unit. SSH forwards its private Unix socket; the VPS needs no public application port.

From the repository root, create the **gitignored** `.local/deploy-server.json` with your private SSH target:

```json
{"host":"my-vps"}
```

`host` may be an alias from `~/.ssh/config`. Optional `user`, `port` and `identityFile` fields override SSH defaults. Keep real connection settings in this local file; the public Moon configuration and cached build artifacts contain no deployment target.

Build, upload and restart the daemon with one command:

```sh
moonx deploy-server
```

`deploy-server` depends on the cacheable `build-server` task, which builds Linux x64. Its Moon dependencies build QuickJS, SQLite and flutter_pty2 independently with their package hooks. Agent commands and interactive terminals share flutter_pty2 3.x, a Dart FFI package with no Flutter SDK dependency. Each native task tracks its build tooling and lockfile; QuickJS also tracks its hook, C sources and headers, including the vendored submodule. Moon caches each shared library as an output.

The Dart AOT task tracks the server's Dart package graph and consumes those native outputs with `cacheStrategy: outputs`, so Dart-only edits reuse the native libraries, and native changes invalidate Dart compilation only when a library changes. Moon also restores the final executable, checksum and build report on a cache hit. Desktop code, tests, documentation and private connection settings do not invalidate the build. Upload and restart run on every deployment. The deployment checks the VPS architecture and artifact checksums before uploading.

To reference the existing Codex login **on the VPS** during the first deployment:

```sh
moonx deploy-server -- --from-codex
```

This does not copy credentials from this checkout or your Mac. Omit `--from-codex` when the server already has authentication configured.

The builder freezes the current server sources (including uncommitted edits), and builds with Dart 3.13.7 in an Ubuntu 24.04 build environment. **Docker is used only for Linux compilation**, through `tool/build_server/Dockerfile`; it never runs the deployed server. Docker must be running locally on a cache miss. Only the server's package graph and native sources enter the builder; desktop, SSH files and local configuration are excluded.

The artifact is one self-contained AOT executable, `happen-server`, with QuickJS, SQLite and PTY libraries embedded as compressed payloads. Before entering the CLI, it extracts verified native libraries into a private cache and checks their actual symbol bindings. Warm launches use the cached libraries without decoding the payload. The VPS needs no Dart SDK, Flutter, compiler, Docker or adjacent library directory to run it.

The tool uploads that executable through SSH, verifies SHA-256, checks its embedded-library bootstrap, switches `~/.local/share/happen/current`, and restarts the daemon. It waits for readiness before acknowledging success and restores the previous release if the new daemon fails to start. Restart interrupts active turns; saved threads remain on disk.

To build independently, or redeploy an existing artifact:

```sh
moonx build-server
moon run build-server-arm64
dart tool/build_server.dart arm64
dart tool/deploy_server.dart --skip-build
```

The direct Dart build and deployment also invoke the Moon task graph. The direct deployment detects x64 or arm64 and uses the private local target, or an explicitly supplied SSH alias. Artifacts are written to `build/server/linux-<architecture>/happen-server`, with a SHA-256 file and `build-report.json`; independently cached native libraries are under its `native/` directory. The builder verifies both cold extraction and warm startup.

Desktop connections retain their SSH tunnel across daemon restarts and immediately reconnect to the replacement Unix socket. Failed socket attempts back off from 50 ms to at most one second. After the protocol acknowledges capabilities, the desktop becomes available while its catalog and thread histories synchronize in the background. A lost SSH transport is recreated automatically; remote WebSocket pings run every two seconds to detect silent failures.

Manage the daemon directly:

```sh
ssh my-vps '.local/bin/happen-server daemon status'
ssh my-vps '.local/bin/happen-server daemon start'
ssh my-vps '.local/bin/happen-server daemon restart'
ssh my-vps '.local/bin/happen-server daemon stop'
```

Commands return JSON with `backend: "pid"`, status, PID and socket path. Start is idempotent. Lifecycle commands serialize through a file lock; Linux boot ID and process start ticks protect against stale records and PID reuse. Stop waits for graceful shutdown before another daemon can start. The daemon survives SSH disconnects. A desktop connection starts it again if it is stopped, including after reboot.

The default data directory is `~/.local/share/agent-server` (`AGENT_DATA_DIR` or `--data-dir` overrides it). It contains `daemon.json`, `daemon.log`, `server.sock` and thread storage. The directory is private to the user and the socket is mode `0600`. Global server configuration remains in `~/.config/happen/config.yaml` on the VPS.

After deployment, open desktop **Settings → Environments → Add environment**. Enter a hostname or an SSH config alias and a display name. User, port and identity-file path are optional; blank values inherit SSH configuration and the SSH agent. Optional workspace directories seed checkout discovery. Local and remote environments use the same connection-status layout; their overflow menus provide icon selection, including Apple, laptop, desktop, server, Linux and Ubuntu. Use **Manage environments…** in the machine picker to edit or remove a connection.

Remote connections and machine icons are desktop-owned settings in `desktop.sqlite`. Deployment provisions the server; adding a connection is a desktop Settings action. Happen does not generate SSH config includes or write to `~/.ssh`. SSH keys remain with SSH, and model credentials remain on the server where they are used. Connection settings and credential values are kept outside this repository.

The sidebar combines threads and invested drafts from every connected server, regardless of which machine is selected. Cards show their machine icon; opening one routes to that server. This computer is named **local** throughout the app. Switching machines retains the sidebar's pins, project filter, disclosure and scroll state. Application-owned SSH workers keep connections alive and retry dropped transports with capped exponential backoff. Recovery retains the desktop session, cached rows and drafts, and restores thread watches without replaying messages.

Each server owns its durable SQLite thread catalog (`server.sqlite`) and per-thread history (`tasks/<id>/history.sqlite`). Desktop project/thread rows are a disposable cache: synchronization discovers folders from the server catalog, replaces stale titles and archive state, and removes stale references. Rebuilding that cache also recovers histories whose checkout directory is unavailable. Connection settings, drafts and presentation preferences are retained separately from the cached rows in desktop SQLite.

New threads have **Run on** and **Workspace** controls beneath the composer, following T3 Code's draft routing. Both controls read inventories maintained in the background by the application: opening a draft or dropdown never starts SSH or workspace discovery. Run on lists connected machines and enables those with the same Git repository; Workspace lists cached checkouts and registered worktrees, showing each branch and full path. When a machine has several matches, choosing it opens its workspace choices. The machine becomes fixed once the thread starts.

Before sending the first message, click **Pull** beside these controls to bring the selected checkout to the latest remote `main` or `master`. The selected machine runs Git with its own remote configuration and credentials. The action prefers `upstream`, then `origin`, then another remote in name order. It prefers the remote's default when that branch is `main` or `master`, otherwise `main` then `master`. Its tooltip names the source; progress can be cancelled, and success briefly shows **Pulled** or **Already up to date**, matching T3's Pull feedback. Thread creation and workspace switching wait until the pull finishes.

Pull is fast-forward only, with autostash disabled. Unrelated local edits are preserved; conflicting edits, diverged history and detached HEAD stop the action with an error. A worktree without a configured upstream can still update from the repository's mainline. Git writes serialize across worktrees sharing a common repository, while separate clones remain independent.

Discovery uses registered project roots, recent Happen thread directories and Codex session metadata. A registered workspace container exposes its immediate Git checkouts; repository roots are not recursively scanned. Each matching repository is expanded with `git worktree list --porcelain`, including worktrees outside the original project directory and worktrees belonging to a bare repository. SSH, SCP and HTTPS remote spellings identify the same project. As in T3, `upstream` takes precedence over `origin`, then other fetch remotes in name order. Local folder paths do not group projects across machines. Subdirectory projects resolve to the same relative directory in each checkout.

Changing a draft's machine preserves its prompt, model settings, file references and attachments. The destination draft is committed before the source is removed; attachment caches are copied so one machine's draft cannot delete another's files.
