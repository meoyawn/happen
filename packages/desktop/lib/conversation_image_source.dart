import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:protocol/protocol.dart' show CancellationToken, CancellableIsolate, maxClientFrameBytes;

/// Workers own image I/O and decoding of embedded data. Flutter owns the
/// resulting codec and shares its image cache across thumbnails and previews.
class ConversationImageSource extends ImageProvider<ConversationImageSource> {
  const ConversationImageSource(this.source);
  final String source;

  @override
  Future<ConversationImageSource> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(ConversationImageSource key, ImageDecoderCallback decode) {
    final cancellation = CancellationToken();
    return MultiFrameImageStreamCompleter(
      codec: _loadImage(key.source, decode, cancellation),
      scale: 1,
      debugLabel: 'Conversation image',
    )..addOnLastListenerRemovedCallback(cancellation.cancel);
  }

  @override
  bool operator ==(Object other) => other is ConversationImageSource && other.source == source;

  @override
  int get hashCode => source.hashCode;
}

Future<ui.Codec> _loadImage(String source, ImageDecoderCallback decode, CancellationToken cancellation) async {
  final bytes = await CancellableIsolate.run(() => _readImage(source), cancellation);
  cancellation.throwIfCancelled();
  return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
}

Future<Uint8List> _readImage(String source) async {
  if (source.startsWith('data:')) {
    if (source.length > maxClientFrameBytes) throw const FormatException('Image is too large');
    final data = UriData.parse(source);
    if (!data.mimeType.startsWith('image/')) throw const FormatException('Expected an image');
    return data.contentAsBytes();
  }
  final uri = Uri.parse(source);
  if (uri.scheme == 'file') return File.fromUri(uri).readAsBytes();
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) throw HttpException('Could not load image (${response.statusCode})', uri: uri);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) { bytes.add(chunk); }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}
