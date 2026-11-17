import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;
import 'database_web.dart';

typedef BrowserFile = ({String name, String path, bool image});

Future<Object?> _files(String method, Json params, CancellationToken cancellation) async {
  final owner = await openDesktopDatabase('', cancellation: cancellation);
  try { return await desktopDatabaseRequest(owner, method, params, cancellation: cancellation); }
  finally { await owner.close(); }
}

Future<String> storeBrowserFile(Uint8List bytes, String name, CancellationToken cancellation) async {
  final id = 'browser-file:${newId()}';
  await _files('files.put', {'id': id, 'name': name, 'data': base64Encode(bytes)}, cancellation);
  return id;
}
Future<Uint8List> readBrowserFile(String path, CancellationToken cancellation) async {
  if (path.startsWith('data:')) return UriData.parse(path).contentAsBytes();
  final file = await _files('files.read', {'id': path}, cancellation);
  if (file == null) throw StateError('Attachment is no longer available in this browser');
  return base64Decode(jsonObject(file)['data'] as String);
}
Future<void> deleteBrowserFile(String path) async { await _files('files.remove', {'id': path}, CancellationToken()); }
Future<String> copyBrowserFile(String path, CancellationToken cancellation) async =>
  storeBrowserFile(await readBrowserFile(path, cancellation), 'Attachment', cancellation);

Future<Uint8List> readBrowserImage(String source, CancellationToken cancellation) async {
  if (source.startsWith('browser-file:') || source.startsWith('data:')) return readBrowserFile(source, cancellation);
  final uri = Uri.parse(source);
  if (!{'https', 'http', 'blob'}.contains(uri.scheme)) throw const FormatException('Unsupported image address');
  final abort = web.AbortController();
  final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
  final token = cancellation.merge(deadline);
  final hook = CancellationHook(token, () => abort.abort());
  try {
    final response = await web.window.fetch(source.toJS, web.RequestInit(signal: abort.signal)).toDart;
    if (!response.ok) throw StateError('Could not load image (${response.status})');
    return (await response.arrayBuffer().toDart).toDart.asUint8List();
  } finally { hook.dispose(); deadline.cancel(); }
}

Future<List<Json>> prepareBrowserImages(List<Json> attachments, {required CancellationToken cancellation}) async {
  final result = <Json>[];
  var size = 0;
  for (final attachment in attachments) {
    final bytes = await readBrowserFile(requiredString(attachment, 'path'), cancellation);
    final mime = imageMimeType(bytes);
    if (mime == null) throw const FormatException('Use PNG, JPEG, GIF, or WebP images in the browser');
    final encoded = base64Encode(bytes);
    size += encoded.length + 128;
    if (size > maxRemoteImageBytes) throw const FormatException('Image attachments exceed 32 MiB; send smaller images');
    result.add({'type': 'image', 'name': attachment['name'], 'mime_type': mime, 'data': encoded, 'detail': 'auto'});
  }
  return result;
}

Future<List<BrowserFile>> pickBrowserFiles(CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final input = web.HTMLInputElement()..type = 'file'..multiple = true;
  input.style..position = 'fixed'..left = '0'..top = '0'..width = '1px'..height = '1px'..opacity = '0'..pointerEvents = 'none';
  input.tabIndex = -1;
  web.document.body!.append(input);
  final chosen = CancellableCompleter<void>(cancellation);
  final changes = input.onChange.listen((_) { if (!chosen.isCompleted) chosen.complete(); });
  final cancelled = web.EventStreamProviders.cancelEvent.forTarget(input).listen((_) { if (!chosen.isCompleted) chosen.complete(); });
  try {
    input.click();
    await chosen.future;
    final result = <BrowserFile>[];
    final files = input.files;
    for (var i = 0; i < (files?.length ?? 0); i++) {
      final file = files!.item(i)!;
      if (file.size > 100 * 1024 * 1024) throw StateError('Choose files smaller than 100 MB');
      final bytes = (await file.arrayBuffer().toDart.asCancellable(cancellation)).toDart.asUint8List();
      final path = await storeBrowserFile(bytes, file.name, cancellation);
      result.add((name: file.name, path: path, image: file.type.startsWith('image/') && file.type != 'image/svg+xml'));
    }
    return result;
  } finally { await changes.cancel(); await cancelled.cancel(); input.remove(); }
}

void downloadBrowserFile(Uint8List bytes, String name) {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'application/json'));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()..href = url..download = name;
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  // Let the browser consume the object URL before releasing it.
  Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
}
