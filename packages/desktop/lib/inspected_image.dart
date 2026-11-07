import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

/// The recorded image belongs to its server/thread/item, not a mutable path on
/// this computer. Both thumbnail and viewer resolve that recorded source.
class InspectedImage extends ImageProvider<InspectedImage> {
  const InspectedImage(this.client, this.threadId, this.itemId);
  final AgentClient client;
  final String threadId, itemId;

  @override
  Future<InspectedImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(InspectedImage key, ImageDecoderCallback decode) {
    final cancellation = CancellationToken();
    return MultiFrameImageStreamCompleter(codec: _load(decode, cancellation), scale: 1,
      debugLabel: 'Inspected image')..addOnLastListenerRemovedCallback(cancellation.cancel);
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode, CancellationToken cancellation) async {
    final response = await client.sessionRead('thread/image/read', {'threadId': threadId, 'itemId': itemId},
      cancellation: cancellation);
    final source = requiredString(response, 'source');
    final bytes = await CancellableIsolate.run(() {
      if (source.length > maxClientFrameBytes) throw const FormatException('Image is too large');
      final data = UriData.parse(source);
      if (!data.mimeType.startsWith('image/')) throw const FormatException('Expected an image');
      return data.contentAsBytes();
    }, cancellation);
    cancellation.throwIfCancelled();
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is InspectedImage && identical(client, other.client) &&
    threadId == other.threadId && itemId == other.itemId;
  @override
  int get hashCode => Object.hash(client, threadId, itemId);
}
