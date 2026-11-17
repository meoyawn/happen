import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:protocol/protocol.dart';

Future<void> writeClipboardImage(Uint8List png, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  if (!Platform.isMacOS) throw UnsupportedError('Image clipboard is unavailable on this platform');
  await computeCancellable(() => _writeMacOSImage(png), cancellation);
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
final _data = _objc.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>, UintPtr),
  Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>, int)>('objc_msgSend');
final _clear = _objc.lookupFunction<IntPtr Function(Pointer<Void>, Pointer<Void>),
  int Function(Pointer<Void>, Pointer<Void>)>('objc_msgSend');
final _setData = _objc.lookupFunction<Bool Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>),
  bool Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)>('objc_msgSend');
final _release = _objc.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>),
  void Function(Pointer<Void>, Pointer<Void>)>('objc_msgSend');

// The worker owns native buffers, autoreleased objects, and pasteboard IPC.
void _writeMacOSImage(Uint8List png) => using((arena) {
  Pointer<Void> type(String name) => _class(name.toNativeUtf8(allocator: arena));
  Pointer<Void> sel(String name) => _selector(name.toNativeUtf8(allocator: arena));
  final pool = _send(_send(type('NSAutoreleasePool'), sel('alloc')), sel('init'));
  try {
    final bytes = arena<Uint8>(png.length)..asTypedList(png.length).setAll(0, png);
    final data = _data(type('NSData'), sel('dataWithBytes:length:'), bytes, png.length);
    final format = _sendObject(type('NSString'), sel('stringWithUTF8String:'),
      'public.png'.toNativeUtf8(allocator: arena).cast());
    final pasteboard = _send(type('NSPasteboard'), sel('generalPasteboard'));
    if (data == nullptr || format == nullptr || pasteboard == nullptr) {
      throw StateError('Could not prepare the image clipboard');
    }
    _clear(pasteboard, sel('clearContents'));
    if (!_setData(pasteboard, sel('setData:forType:'), data, format)) {
      throw StateError('Could not copy the image to the clipboard');
    }
  } finally {
    if (pool != nullptr) _release(pool, sel('drain'));
  }
});
