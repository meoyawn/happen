import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';

typedef EmbeddedNativeAsset = ({String name, String sha256, int length, String Function() payload});

const cliNativeContracts = <String, ({String assetId, String anchor})>{
  'libcode_mode.dylib': (assetId: 'package:code_mode/src/bindings.dart', anchor: 'embedded_js_thread_id'),
  'libsqlite3.dylib': (assetId: 'package:sqlite3/src/ffi/libsqlite3.g.dart', anchor: 'sqlite3_libversion_number'),
};

@Native<Uint64 Function()>(assetId: 'package:code_mode/src/bindings.dart', symbol: 'embedded_js_thread_id')
external int _threadId();
@Native<Int32 Function()>(assetId: 'package:sqlite3/src/ffi/libsqlite3.g.dart', symbol: 'sqlite3_libversion_number')
external int _sqliteVersion();

final _process = DynamicLibrary.process();
final _malloc = _process.lookupFunction<Pointer<Void> Function(Size), Pointer<Void> Function(int)>('malloc');
final _free = _process.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');
final _chmod = _process.lookupFunction<Int32 Function(Pointer<Uint8>, Uint16), int Function(Pointer<Uint8>, int)>('chmod');
final _dlopen = _process.lookupFunction<Pointer<Void> Function(Pointer<Uint8>, Int32), Pointer<Void> Function(Pointer<Uint8>, int)>('dlopen');
final _dlsym = _process.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>), Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>)>('dlsym');
final _libraries = <Pointer<Void>>[];

T _withCString<T>(String value, T Function(Pointer<Uint8>) body) {
  final bytes = utf8.encode(value);
  final pointer = _malloc(bytes.length + 1).cast<Uint8>();
  if (pointer == nullptr) throw StateError('Native bootstrap allocation failed');
  try {
    pointer.asTypedList(bytes.length + 1)..setAll(0, bytes)..[bytes.length] = 0;
    return body(pointer);
  } finally { _free(pointer.cast()); }
}

void _mode(String path, int mode) {
  if (_withCString(path, (pointer) => _chmod(pointer, mode)) != 0) {
    throw FileSystemException('Cannot protect the native cache', path);
  }
}

bool _ready(Directory directory, String id, List<EmbeddedNativeAsset> assets) {
  try {
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) != FileSystemEntityType.directory) return false;
    final marker = File('${directory.path}/complete');
    if (FileSystemEntity.typeSync(marker.path, followLinks: false) != FileSystemEntityType.file ||
        marker.lengthSync() != id.length || marker.readAsStringSync() != id) { return false; }
    for (final asset in assets) {
      final file = File('${directory.path}/${asset.name}');
      if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file ||
          file.lengthSync() != asset.length) { return false; }
    }
    return true;
  } on FileSystemException { return false; }
}

Future<bool> _install(Directory root, Directory directory, String id, List<EmbeddedNativeAsset> assets) async {
  await root.create(recursive: true);
  if (FileSystemEntity.typeSync(root.path, followLinks: false) != FileSystemEntityType.directory) {
    throw FileSystemException('Native cache must be a directory', root.path);
  }
  _mode(root.path, 448); // 0700
  final lockPath = '${root.path}/$id.lock';
  if (FileSystemEntity.isLinkSync(lockPath)) throw FileSystemException('Unexpected native cache lock link', lockPath);
  final lock = await File(lockPath).open(mode: FileMode.append);
  try {
    _mode(lockPath, 384); // 0600
    await lock.lock(FileLock.blockingExclusive);
    if (_ready(directory, id, assets)) return false;
    await directory.create();
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Native cache must be a directory', directory.path);
    }
    _mode(directory.path, 448);
    final complete = File('${directory.path}/complete');
    if (FileSystemEntity.typeSync(complete.path, followLinks: false) != FileSystemEntityType.notFound) await complete.delete();
    final staging = await directory.createTemp('.install-');
    try {
      for (final asset in assets) {
        final bytes = gzip.decode(base64.decode(asset.payload()));
        if (bytes.length != asset.length || sha256.convert(bytes).toString() != asset.sha256) {
          throw StateError('Embedded native payload checksum failed: ${asset.name}');
        }
        final file = File('${staging.path}/${asset.name}');
        await file.writeAsBytes(bytes, flush: true);
        _mode(file.path, 320); // 0500
        await file.rename('${directory.path}/${asset.name}');
      }
      final marker = File('${staging.path}/complete');
      await marker.writeAsString(id, flush: true);
      _mode(marker.path, 256); // 0400
      await marker.rename(complete.path);
    } finally { await staging.delete(recursive: true); }
    return true;
  } finally {
    try { await lock.unlock(); } finally { await lock.close(); }
  }
}

/// The release main runs this before touching any native package. Warm launches
/// read only a small marker and file metadata before loading the cached dylibs.
/// No subprocess, network request, SDK, or runtime compiler is involved.
Future<void> bootstrapNativeAssets(String id, List<EmbeddedNativeAsset> assets) async {
  if (!Platform.isMacOS) throw UnsupportedError('This executable targets macOS');
  final started = Stopwatch()..start();
  final home = Platform.environment['HOME'];
  final override = Platform.environment['HAPPEN_NATIVE_CACHE'];
  if (override == null && (home == null || home.isEmpty)) throw StateError('HOME is required for the native cache');
  final root = Directory(override ?? '$home/Library/Caches/dev.happen/cli/native').absolute;
  if (FileSystemEntity.isLinkSync(root.path)) throw FileSystemException('Native cache must not be a symbolic link', root.path);
  final directory = Directory('${root.path}/$id');
  final installed = _ready(directory, id, assets) ? false : await _install(root, directory, id, assets);
  for (final asset in assets) {
    final handle = _withCString('${directory.path}/${asset.name}', (path) => _dlopen(path, 0x2 | 0x4)); // RTLD_NOW | RTLD_LOCAL
    if (handle == nullptr) throw StateError('Cannot load embedded native asset: ${asset.name}');
    _libraries.add(handle); // Process-owned; native work must never outlive its library.
    _withCString(cliNativeContracts[asset.name]!.anchor, (symbol) {
      final bound = asset.name == 'libcode_mode.dylib'
        ? Native.addressOf<NativeFunction<Uint64 Function()>>(_threadId).cast<Void>()
        : Native.addressOf<NativeFunction<Int32 Function()>>(_sqliteVersion).cast<Void>();
      if (_dlsym(handle, symbol) != bound) throw StateError('Native asset binding differs from ${asset.name}');
    });
  }
  if (_threadId() == 0 || _sqliteVersion() < 3000000) throw StateError('Incompatible embedded native ABI');
  if (Platform.environment['HAPPEN_BOOTSTRAP_REPORT'] == '1') {
    stderr.writeln(jsonEncode({'installed': installed, 'bootstrap_microseconds': started.elapsedMicroseconds, 'native_id': id}));
  }
}
