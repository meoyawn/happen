# Pinned dependencies

`flutter/` is the vendored development Flutter SDK, pinned as a Git submodule.
Initialize it before resolving workspace dependencies:

```sh
git submodule update --init --recursive
dart pub get
```

HTTP uses Dart's built-in `HttpClient`, including its connection pooling and
default idle timeout. The former manual HTTP/2 pool and `http2` fork are no longer
dependencies. Historical measurements remain in `docs/evidence/`.
