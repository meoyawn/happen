import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai/ai.dart';
import 'package:image/image.dart' as image;
import 'package:protocol/protocol.dart';

/// OpenCode core/image.ts and image/photon-normalize.ts: 2000px, 5 MiB
/// base64 per image, small/transparent PNG preservation, then JPEG qualities
/// 80/70/55/40 and progressively smaller dimensions. CPU work stays off the UI.
Future<List<Json>> prepareOpenCodeImages(List<Json> images, {required CancellationToken cancellation}) {
  cancellation.throwIfCancelled();
  if (images.isEmpty) return Future.value([]);
  return CancellableIsolate.run(() {
    final result = [for (final part in inputAttachments(images)) _normalize(part)];
    if (utf8.encode(jsonEncode(result)).length > maxClientFrameBytes) {
      throw const FormatException('Prepared images exceed the 64 MiB transport limit');
    }
    return result;
  }, cancellation);
}

Json _normalize(Json part) {
  final bytes = inputImageBytes(part);
  final decoded = image.decodeImage(bytes, frame: 0);
  if (decoded == null) throw const FormatException('Image could not be decoded');
  final source = image.bakeOrientation(decoded);
  final mime = imageMimeType(bytes) ?? 'image/png';
  final encodedSize = 4 * ((bytes.length + 2) ~/ 3);
  const maxBytes = 5 * 1024 * 1024;
  final fits = source.width <= 2000 && source.height <= 2000 && encodedSize <= maxBytes;
  final smallPng = encodedSize <= 384 * 1024 || source.width * source.height <= 256 * 256;
  Json result(List<int> data, String mime, int width, int height) => {
    'type': 'image', 'name': part['name'], 'mime_type': mime,
    'data': base64Encode(data), 'detail': 'high', 'width': width, 'height': height,
  };
  if (fits && (mime != 'image/png' || smallPng)) {
    return result(bytes, mime, source.width, source.height);
  }
  var transparent = 0;
  final columns = math.min(64, source.width), rows = math.min(64, source.height);
  if (mime != 'image/jpeg' && source.hasAlpha) {
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        if (source.getPixel(((column + .5) * source.width / columns).floor(),
            ((row + .5) * source.height / rows).floor()).aNormalized * 255 < 250) transparent++;
      }
    }
  }
  final preserveAlpha = transparent / (columns * rows) > .05;
  if (fits) {
    if (preserveAlpha) return result(bytes, mime, source.width, source.height);
    final jpeg = image.encodeJpg(source, quality: 80);
    return jpeg.length < bytes.length ? result(jpeg, 'image/jpeg', source.width, source.height)
        : result(bytes, mime, source.width, source.height);
  }
  final scale = math.min(1.0, math.min(2000 / source.width, 2000 / source.height));
  var width = math.max(1, (source.width * scale).round());
  var height = math.max(1, (source.height * scale).round());
  for (var step = 0; step < 32; step++) {
    final resized = width == source.width && height == source.height ? source
        : image.copyResize(source, width: width, height: height, interpolation: image.Interpolation.cubic);
    final pngFirst = preserveAlpha || width * height <= 256 * 256;
    for (final quality in [if (pngFirst) null, 80, 70, 55, 40, if (!pngFirst) null]) {
      final Uint8List candidate = quality == null ? image.encodePng(resized, singleFrame: true)
          : image.encodeJpg(resized, quality: quality);
      if (4 * ((candidate.length + 2) ~/ 3) <= maxBytes) {
        return result(candidate, quality == null ? 'image/png' : 'image/jpeg', width, height);
      }
    }
    if (width == 1 && height == 1) break;
    width = math.max(1, (width * .75).floor());
    height = math.max(1, (height * .75).floor());
  }
  throw const FormatException('Image exceeds OpenCode limits after resizing');
}
