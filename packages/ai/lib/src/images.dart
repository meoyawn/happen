import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:protocol/protocol.dart';

/// Codex's model image preparation. Killing the worker cancels file reads and
/// CPU work without blocking other tasks or the UI.
Future<List<Json>> prepareInputAttachments(Object? attachments, {
  required CancellationToken cancellation, int envelopeBytes = 0,
}) {
  cancellation.throwIfCancelled();
  if (attachments == null) return Future.value([]);
  if (attachments is List && !attachments.any((part) => part is Map && part['type'] == 'image')) {
    return Future.value(inputAttachments(attachments));
  }
  return CancellableIsolate.run(() {
    final parts = inputAttachments(attachments);
    final result = [
      for (final part in parts)
        if (part['type'] == 'image')
          _prepareImage(_imageBytes(part), part['name'] as String, part['detail'] as String)
        else part,
    ];
    if (utf8.encode(jsonEncode(result)).length + envelopeBytes > maxClientFrameBytes) {
      throw const FormatException('Prepared message exceeds the Codex 64 MiB transport limit; send fewer attachments');
    }
    return result;
  }, cancellation);
}

/// Snapshot client-local images for a remote server. Keep source bytes when
/// they fit Codex's 32 MiB image budget; prepare the largest sources first when
/// needed. The caller retains originals for retry and the server still applies
/// its model policy. This does not progressively lower image quality.
Future<List<Json>> prepareRemoteImages(List<Json> attachments, {required CancellationToken cancellation}) {
  cancellation.throwIfCancelled();
  return CancellableIsolate.run(() {
    final parts = inputAttachments(attachments);
    final estimates = <int>[];
    for (final part in parts) {
      if (part['type'] != 'image' || part['path'] is! String) throw const FormatException('Expected local image paths');
      final stat = File(part['path'] as String).statSync();
      if (stat.type != FileSystemEntityType.file) throw const FormatException('Image path must be a regular file');
      if (stat.size > maxImageInputBytes) throw const FormatException('Image input exceeds the Codex 1 GiB limit');
      estimates.add(4 * ((stat.size + 2) ~/ 3) + 64);
    }
    var total = estimates.fold<int>(0, (sum, size) => sum + size);
    final prepared = <int, Json>{};
    final largestFirst = List.generate(parts.length, (index) => index)
      ..sort((a, b) => estimates[b].compareTo(estimates[a]));
    for (final index in largestFirst) {
      if (total <= maxRemoteImageBytes) break;
      final part = parts[index];
      final reduced = _prepareImage(_imageBytes(part), part['name'] as String, part['detail'] as String, forceEncode: true);
      prepared[index] = reduced;
      total += attachmentDataUrl(reduced).length - estimates[index];
      if (prepared.values.fold<int>(0, (size, image) => size + attachmentDataUrl(image).length) > maxRemoteImageBytes) {
        throw const FormatException('Image attachments exceed the Codex 32 MiB transport limit after preparation; send fewer images');
      }
    }
    final result = <Json>[];
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (prepared[index] case final image?) {
        result.add(image);
      } else {
        final bytes = _imageBytes(part);
        final mime = imageMimeType(bytes);
        result.add(mime == null
          ? _prepareImage(bytes, part['name'] as String, part['detail'] as String, resize: false)
          : {'type': 'image', 'name': part['name'], 'mime_type': mime, 'data': base64Encode(bytes), 'detail': part['detail']});
      }
    }
    if (result.fold<int>(0, (size, part) => size + attachmentDataUrl(part).length) > maxRemoteImageBytes) {
      throw const FormatException('Image attachments exceed the Codex 32 MiB transport limit after preparation; send fewer images');
    }
    return result;
  }, cancellation);
}

Uint8List _imageBytes(Json part) {
  if (part['path'] case final String path) {
    final file = File(path);
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file) throw const FormatException('Image path must be a regular file');
    if (stat.size > maxImageInputBytes) throw const FormatException('Image input exceeds the Codex 1 GiB limit');
    // Read a bounded snapshot, even if the source grows after the stat.
    final source = file.openSync();
    try {
      final bytes = BytesBuilder(copy: false);
      while (true) {
        final chunk = source.readSync(math.min(1024 * 1024, maxImageInputBytes + 1 - bytes.length));
        if (chunk.isEmpty) return bytes.takeBytes();
        bytes.add(chunk);
        if (bytes.length > maxImageInputBytes) throw const FormatException('Image input exceeds the Codex 1 GiB limit');
      }
    } finally {
      source.closeSync();
    }
  }
  return base64Decode(part['data'] as String);
}

Json _prepareImage(Uint8List bytes, String name, String detail, {bool forceEncode = false, bool resize = true}) {
  if (bytes.isEmpty || bytes.length > maxImageInputBytes) {
    throw const FormatException('Image input must be nonempty and at most 1 GiB');
  }
  if (!{'high', 'original'}.contains(detail)) throw const FormatException('Unsupported image detail');
  final decoded = image.decodeImage(bytes, frame: 0);
  if (decoded == null) throw const FormatException('Could not decode the attached image');
  var source = image.bakeOrientation(decoded);
  final originalMime = imageMimeType(bytes);
  final (width, height) = resize ? _dimensions(source.width, source.height, detail) : (source.width, source.height);
  var mime = originalMime ?? 'image/png';
  var encoded = bytes;
  if (forceEncode || width != source.width || height != source.height ||
      !{'image/png', 'image/jpeg', 'image/webp'}.contains(originalMime)) {
    source = image.copyResize(source, width: width, height: height, interpolation: image.Interpolation.average);
    encoded = switch (mime) {
      'image/jpeg' => image.encodeJpg(source, quality: 85),
      'image/webp' => image.encodeWebP(source),
      _ => image.encodePng(source, singleFrame: true),
    };
    if (mime != 'image/jpeg' && mime != 'image/webp') mime = 'image/png';
  }
  return {'type': 'image', 'name': name, 'mime_type': mime, 'data': base64Encode(encoded), 'detail': detail,
    'width': width, 'height': height};
}

/// Codex utils/image::prompt_image_output_dimensions_for_limits, 32px patches.
(int, int) _dimensions(int width, int height, String detail) {
  final edge = detail == 'original' ? 6000 : 2048;
  final patches = detail == 'original' ? 10000 : 2500;
  bool fits() => width <= edge && height <= edge && ((width + 31) ~/ 32) * ((height + 31) ~/ 32) <= patches;
  if (fits()) return (width, height);
  final edgeScale = math.min(1.0, edge / math.max(width, height));
  width = math.max(1, (width * edgeScale).round());
  height = math.max(1, (height * edgeScale).round());
  if (fits()) return (width, height);
  var scale = math.sqrt(32 * 32 * patches / width / height);
  final across = width * scale / 32, down = height * scale / 32;
  scale *= math.min(across.floor() / across, down.floor() / down);
  return (math.max(1, (width * scale).floor()), math.max(1, (height * scale).floor()));
}
