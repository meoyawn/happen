QuickJS 2026-06-04, https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz

Archive SHA-256: b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a

The quickjs directory is a Git submodule of https://github.com/bellard/quickjs,
pinned to release commit 3d5e064e9dd67c70f7962836505a7fa067bf0a4e.
Its quickjs.c is byte-identical to the tested release archive.

Initialize it with git submodule update --init --recursive.
The Dart build hook compiles only the interpreter C sources and our bridge;
no qjs executable, libc module, Node, Rust runtime, or Flutter dependency.
