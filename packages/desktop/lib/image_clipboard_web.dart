import 'dart:js_interop';
import 'dart:typed_data';
import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;

Future<void> writeClipboardImage(Uint8List png, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final blob = web.Blob([png.toJS].toJS, web.BlobPropertyBag(type: 'image/png'));
  final item = web.ClipboardItem({'image/png': blob}.jsify()! as JSObject);
  await web.window.navigator.clipboard.write([item].toJS).toDart.asCancellable(cancellation);
}
