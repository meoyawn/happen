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

After a successful deployment, the tool registers the SSH alias in **`~/.config/happen/remotes.json`** (`XDG_CONFIG_HOME` is respected). The desktop discovers this file, verifies the remote protocol connection and shows the host as **Available** in the machine picker in its sidebar and thread header. Select it to open remote projects and run threads on the VPS. Each host retains its own desktop database, project list and drafts; discovery leaves the current machine and thread selected. After redeployment, select **Reconnect** if an existing SSH connection was closed.

You can also maintain this private file yourself:

```json
{
  "hosts": [
    {"alias": "my-vps", "name": "Development VPS", "projects": ["/home/agent/workspace"]}
  ]
}
```

Keep SSH addresses, keys and provider credentials outside the repository. Deployment only persists host registration in the user's configuration directory; no credential file or machine-specific deployment descriptor is generated in the checkout.
