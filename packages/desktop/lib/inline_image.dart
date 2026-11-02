import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:protocol/protocol.dart' show CancellationToken, CancellableIsolate, maxClientFrameBytes;

/// Inline media shares Flutter's image cache across transcript mounts.
class InlineImage extends ImageProvider<InlineImage> {
  const InlineImage(this.source);
  final String source;

  @override
  Future<InlineImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(InlineImage key, ImageDecoderCallback decode) {
    final cancellation = CancellationToken();
    return MultiFrameImageStreamCompleter(
      codec: _loadInlineImage(key.source, decode, cancellation),
      scale: 1,
      debugLabel: 'Inline image',
    )..addOnLastListenerRemovedCallback(cancellation.cancel);
  }

  @override
  bool operator ==(Object other) => other is InlineImage && other.source == source;

  @override
  int get hashCode => source.hashCode;
}

Future<ui.Codec> _loadInlineImage(String source, ImageDecoderCallback decode, CancellationToken cancellation) async {
  final bytes = await CancellableIsolate.run(() {
    if (source.length > maxClientFrameBytes) throw const FormatException('Image is too large');
    final data = UriData.parse(source);
    if (!data.mimeType.startsWith('image/')) throw const FormatException('Expected an image');
    return data.contentAsBytes();
  }, cancellation);
  cancellation.throwIfCancelled();
  return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
}
