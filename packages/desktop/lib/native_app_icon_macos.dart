import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final _objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
final _class = _objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
  Pointer<Void> Function(Pointer<Utf8>)>('objc_getClass');
final _selector = _objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
  Pointer<Void> Function(Pointer<Utf8>)>('sel_registerName');
final _send = _objc.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
  Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>('objc_msgSend');
final _sendObject = _objc.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
  Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>('objc_msgSend');
final _sendBytes = _objc.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>, UintPtr),
  Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>, int)>('objc_msgSend');
final _performOnMain = _objc.lookupFunction<
  Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Bool),
  void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, bool)>('objc_msgSend');
final _release = _objc.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>),
  void Function(Pointer<Void>, Pointer<Void>)>('objc_msgSend');

/// AppKit performs the mutation on the main thread even with unmerged Flutter runners.
void setMacOSAppIcon(Uint8List? bytes) => using((arena) {
  Pointer<Void> type(String name) => _class(name.toNativeUtf8(allocator: arena));
  Pointer<Void> sel(String name) => _selector(name.toNativeUtf8(allocator: arena));
  final pool = _send(_send(type('NSAutoreleasePool'), sel('alloc')), sel('init'));
  var data = nullptr.cast<Void>(), image = nullptr.cast<Void>();
  try {
    final app = _send(type('NSApplication'), sel('sharedApplication'));
    if (app == nullptr) throw StateError('The macOS application is unavailable');
    if (bytes != null) {
      final buffer = arena<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
      data = _sendBytes(_send(type('NSData'), sel('alloc')), sel('initWithBytes:length:'), buffer, bytes.length);
      image = _sendObject(_send(type('NSImage'), sel('alloc')), sel('initWithData:'), data);
      if (image == nullptr) throw StateError('Could not load the app icon');
    }
    // nil restores the bundle's release/debug icon, without hard-coding its color.
    _performOnMain(app, sel('performSelectorOnMainThread:withObject:waitUntilDone:'),
      sel('setApplicationIconImage:'), image, true);
  } finally {
    if (image != nullptr) _release(image, sel('release'));
    if (data != nullptr) _release(data, sel('release'));
    if (pool != nullptr) _release(pool, sel('drain'));
  }
});
