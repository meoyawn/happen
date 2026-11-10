const cliNativeContracts = <String, ({String assetId, String anchor})>{
  'libcode_mode.dylib': (assetId: 'package:code_mode/src/bindings.dart', anchor: 'embedded_js_thread_id'),
  'libsqlite3.dylib': (assetId: 'package:sqlite3/src/ffi/libsqlite3.g.dart', anchor: 'sqlite3_libversion_number'),
  'libflutter_pty2.dylib': (assetId: 'package:flutter_pty2/flutter_pty2', anchor: 'pty_session_pid'),
};

const linuxNativeContracts = <String, ({String assetId, String anchor})>{
  'libcode_mode.so': (assetId: 'package:code_mode/src/bindings.dart', anchor: 'embedded_js_thread_id'),
  'libsqlite3.so': (assetId: 'package:sqlite3/src/ffi/libsqlite3.g.dart', anchor: 'sqlite3_libversion_number'),
  'libflutter_pty2.so': (assetId: 'package:flutter_pty2/flutter_pty2', anchor: 'pty_session_pid'),
};
