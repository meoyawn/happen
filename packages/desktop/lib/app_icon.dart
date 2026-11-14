import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:protocol/protocol.dart';

/// Load the running bundle's icon directly instead of using Launch Services' cache.
Future<void> restoreAppIcon(CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  if (Platform.isMacOS) await CancellableIsolate.run(_restoreMacOSIcon, cancellation);
}

final _objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
final _class = _objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
  Pointer<Void> Function(Pointer<Utf8>)>('objc_getClass');
final _selector = _objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
  Pointer<Void> Function(Pointer<Utf8>)>('sel_registerName');
final _send = _objc.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
  Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>('objc_msgSend');
final _sendObject = _objc.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
  Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>('objc_msgSend');
final _performOnMain = _objc.lookupFunction<
  Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Bool),
  void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, bool)>('objc_msgSend');
final _release = _objc.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>),
  void Function(Pointer<Void>, Pointer<Void>)>('objc_msgSend');

// The worker owns bundle lookup and image loading; AppKit owns the Dock mutation.
void _restoreMacOSIcon() => using((arena) {
  Pointer<Void> type(String name) => _class(name.toNativeUtf8(allocator: arena));
  Pointer<Void> sel(String name) => _selector(name.toNativeUtf8(allocator: arena));
  Pointer<Void> string(String value) => _sendObject(type('NSString'), sel('stringWithUTF8String:'),
    value.toNativeUtf8(allocator: arena).cast());
  final pool = _send(_send(type('NSAutoreleasePool'), sel('alloc')), sel('init'));
  var image = nullptr.cast<Void>();
  try {
    final bundle = _send(type('NSBundle'), sel('mainBundle'));
    final name = _sendObject(bundle, sel('objectForInfoDictionaryKey:'), string('CFBundleIconFile'));
    if (name == nullptr) throw StateError('The macOS bundle has no app icon');
    final path = _sendObject(bundle, sel('pathForImageResource:'), name);
    if (path == nullptr) throw StateError('The macOS bundle app icon is missing');
    image = _sendObject(_send(type('NSImage'), sel('alloc')), sel('initWithContentsOfFile:'), path);
    if (image == nullptr) throw StateError('Could not load the macOS bundle app icon');
    final app = _send(type('NSApplication'), sel('sharedApplication'));
    if (app == nullptr) throw StateError('The macOS application is unavailable');
    _performOnMain(app, sel('performSelectorOnMainThread:withObject:waitUntilDone:'),
      sel('setApplicationIconImage:'), image, true);
  } finally {
    if (image != nullptr) _release(image, sel('release'));
    if (pool != nullptr) _release(pool, sel('drain'));
  }
});
