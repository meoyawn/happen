# desktop

Happen desktop client

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
