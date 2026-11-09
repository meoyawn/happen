The server runs as one detached, PID-managed daemon per Linux user and data directory, shared by all desktop connections. It uses no systemd unit. SSH forwards its private Unix socket; the VPS needs no public application port.

Build and deploy from the repository root, using an alias already configured in `~/.ssh/config`:

```sh
dart tool/deploy_server.dart my-vps --from-codex
```

`--from-codex` references the existing Codex login **on the VPS**. It does not copy credentials from this checkout or your Mac. Omit it when the server already has authentication configured.

For subsequent deployments:

```sh
dart tool/deploy_server.dart my-vps
```

The deployment detects x64 or arm64, freezes the current server sources (including uncommitted edits), and builds with Dart 3.13.7 in an Ubuntu 24.04 build environment. **Docker is used only for Linux compilation**, through `tool/build_server/Dockerfile`; it never runs the deployed server. Docker must be running locally to build. Only the server's package graph and native sources enter the builder; desktop, SSH files and local configuration are excluded.

The artifact is one self-contained AOT executable, `happen-server`, with QuickJS, SQLite and PTY libraries embedded as compressed payloads. Before entering the CLI, it extracts verified native libraries into a private cache and checks their actual symbol bindings. Warm launches use the cached libraries without decoding the payload. The VPS needs no Dart SDK, Flutter, compiler, Docker or adjacent library directory to run it.

The tool uploads that executable through SSH, verifies SHA-256, checks its embedded-library bootstrap, switches `~/.local/share/happen/current`, and restarts the daemon. It waits for readiness before acknowledging success and restores the previous release if the new daemon fails to start. Restart interrupts active turns; saved threads remain on disk.

To build independently, or redeploy an existing artifact:

```sh
dart tool/build_server.dart x64
dart tool/build_server.dart arm64
dart tool/deploy_server.dart my-vps --skip-build
```

Artifacts are written to `build/server/linux-<architecture>/happen-server`, with a SHA-256 file and `build-report.json`. The builder verifies both cold extraction and warm startup. Moon tasks `build-server` and `deploy-server` accept the same arguments.

Manage the daemon directly:

```sh
ssh my-vps '.local/bin/happen-server daemon status'
ssh my-vps '.local/bin/happen-server daemon start'
ssh my-vps '.local/bin/happen-server daemon restart'
ssh my-vps '.local/bin/happen-server daemon stop'
```

Commands return JSON with `backend: "pid"`, status, PID and socket path. Start is idempotent. Lifecycle commands serialize through a file lock; Linux boot ID and process start ticks protect against stale records and PID reuse. Stop waits for graceful shutdown before another daemon can start. The daemon survives SSH disconnects. A desktop connection starts it again if it is stopped, including after reboot.

The default data directory is `~/.local/share/agent-server` (`AGENT_DATA_DIR` or `--data-dir` overrides it). It contains `daemon.json`, `daemon.log`, `server.sock` and thread storage. The directory is private to the user and the socket is mode `0600`. Global server configuration remains in `~/.config/happen/config.yaml` on the VPS.

After deployment, open desktop **Settings → Servers → Connect server**. Enter a hostname or an SSH config alias and a display name. User, port and identity-file path are optional; blank values inherit SSH configuration and the SSH agent. Optional workspace directories seed checkout discovery. The desktop verifies the protocol connection and shows the server as **Available** in the machine picker. Use **Manage servers…** in that picker to edit, reconnect or remove a connection.

Remote connections are desktop-owned settings in `desktop.sqlite`. Deployment provisions the server; adding a connection is a desktop Settings action. SSH keys remain with SSH, and model credentials remain on the server where they are used. Connection settings and credential values are kept outside this repository.

The sidebar combines threads and invested drafts from every connected server, regardless of which machine is selected. Cards show their machine; opening one routes to that server. Switching machines retains the sidebar's pins, project filter, disclosure and scroll state. A disconnected server retains its cached rows while reconnecting.

Each server owns its durable SQLite thread catalog (`server.sqlite`) and per-thread history (`tasks/<id>/history.sqlite`). Desktop project/thread rows are a disposable cache: synchronization discovers folders from the server catalog, replaces stale titles and archive state, and removes stale references. Rebuilding that cache also recovers histories whose checkout directory is unavailable. Connection settings, drafts and presentation preferences are retained separately from the cached rows in desktop SQLite.

New threads have **Run on** and **Workspace** controls beneath the composer, following T3 Code's draft routing. Run on lists machines with the same Git repository; Workspace lists each checkout and registered worktree, showing its branch and full path. When a machine has several matches, choosing it opens its workspace choices. The machine becomes fixed once the thread starts.

Before sending the first message, click **Pull** beside these controls to bring the selected checkout to the latest remote `main` or `master`. The selected machine runs Git with its own remote configuration and credentials. The action prefers `upstream`, then `origin`, then another remote in name order. It prefers the remote's default when that branch is `main` or `master`, otherwise `main` then `master`. Its tooltip names the source; progress can be cancelled, and success briefly shows **Pulled** or **Already up to date**, matching T3's Pull feedback. Thread creation and workspace switching wait until the pull finishes.

Pull is fast-forward only, with autostash disabled. Unrelated local edits are preserved; conflicting edits, diverged history and detached HEAD stop the action with an error. A worktree without a configured upstream can still update from the repository's mainline. Git writes serialize across worktrees sharing a common repository, while separate clones remain independent.

Discovery uses registered project roots, recent Happen thread directories and Codex session metadata. A registered workspace container exposes its immediate Git checkouts; repository roots are not recursively scanned. Each matching repository is expanded with `git worktree list --porcelain`, including worktrees outside the original project directory and worktrees belonging to a bare repository. SSH, SCP and HTTPS remote spellings identify the same project. As in T3, `upstream` takes precedence over `origin`, then other fetch remotes in name order. Local folder paths do not group projects across machines. Subdirectory projects resolve to the same relative directory in each checkout.

Changing a draft's machine preserves its prompt, model settings, file references and attachments. The destination draft is committed before the source is removed; attachment caches are copied so one machine's draft cannot delete another's files.
