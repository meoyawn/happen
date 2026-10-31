# Pinned dependencies

`http/` is a Git submodule of [meoyawn/http](https://github.com/meoyawn/http), on
the `happen/http2-late-data` maintenance branch. The superproject pins commit
`30e4c31035d7cca957658da38945e34079ac298a`, based on the upstream `http2-v3.1.0`
release (`286037b57bcd0cb353ed98be8a508e753221e661`).

The root `pubspec.yaml` overrides only `http2`, using `http/pkgs/http2` at version
`3.1.0+happen.1`. Initialize the submodule before resolving dependencies:

```sh
git submodule update --init --recursive
dart pub get
```

The fork fixes late DATA flow control after a stream reset. The report and
standalone reproducer are in [dart-lang/http#2051](https://github.com/dart-lang/http/issues/2051).
See [the decision record](../docs/decisions.md#2026-11-01--http2-late-data-protocol-failure-and-recovery)
and [sanitized measurements](../docs/evidence/http2-late-data.json).

Run dependency checks inside `http/pkgs/http2` with `dart pub get` and
`dart test --platform vm`. Happen's `test/http_connections_test.dart` verifies the
actual TLS cancellation/recovery boundary. Root analysis excludes the upstream
monorepo; analyze the dependency's changed files from its own package directory.

Keep the fork based on the release until an upstream release includes the repair
and passes these checks. Then remove the path override and this submodule.
