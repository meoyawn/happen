import 'dart:convert';
import 'dart:typed_data';

/// Codex's inline-audio policy: short PCM WAV clips become a text notice;
/// budget known durations at ten tokens/second, unknown formats by URL bytes.
Map<String, Object?> audioMetadata(String url) {
  final fallback = (utf8.encode(url).length + 3) ~/ 4;
  final comma = url.indexOf(',');
  if (comma < 0) return {'tokens': fallback};
  final metadata = url.substring(0, comma).split(';');
  final payload = url.substring(comma + 1);
  if (!metadata.skip(1).any((part) => part.toLowerCase() == 'base64') || payload.length > ((50 * 1024 * 1024 + 2) ~/ 3) * 4) {
    return {'tokens': fallback};
  }
  Uint8List bytes;
  try { bytes = base64Decode(payload); } on FormatException { return {'tokens': fallback}; }
  final wav = _wavDuration(bytes);
  if (wav != null && wav < 0.025) return {'omit': true, 'tokens': 0};
  final mime = metadata.first.toLowerCase().replaceFirst('data:', '');
  const supported = {'audio/wav', 'audio/x-wav', 'audio/wave', 'audio/vnd.wave',
    'audio/mpeg', 'audio/mp3', 'audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/webm', 'audio/ogg'};
  final duration = supported.contains(mime) ? wav ?? _flacDuration(bytes) ?? _mpegDuration(bytes) ?? _mp4Duration(bytes) ?? _oggDuration(bytes) : null;
  return {'tokens': duration == null ? fallback : (duration * 10).ceil()};
}

String _tag(Uint8List bytes, int start, int length) => start + length <= bytes.length
  ? String.fromCharCodes(bytes.sublist(start, start + length)) : '';

double? _wavDuration(Uint8List bytes) {
  if (_tag(bytes, 0, 4) != 'RIFF' || _tag(bytes, 8, 4) != 'WAVE') return null;
  final data = ByteData.sublistView(bytes);
  int? rate, alignment;
  for (var offset = 12; offset + 8 <= bytes.length;) {
    final kind = _tag(bytes, offset, 4), length = data.getUint32(offset + 4, Endian.little), start = offset + 8;
    final actual = length.clamp(0, bytes.length - start);
    if (kind == 'fmt ') {
      if (actual < 16) return null;
      var encoding = data.getUint16(start, Endian.little);
      if (encoding == 0xfffe) {
        const guid = [0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113];
        if (actual < 40 || List.generate(guid.length, (i) => bytes[start + 26 + i] == guid[i]).contains(false)) return null;
        encoding = data.getUint16(start + 24, Endian.little);
      }
      if (encoding != 1 && encoding != 3) return null;
      rate = data.getUint32(start + 4, Endian.little);
      alignment = data.getUint16(start + 12, Endian.little);
      if (rate == 0 || alignment == 0) return null;
    } else if (kind == 'data') {
      return rate == null || alignment == null ? null : (actual ~/ alignment) / rate;
    }
    offset = start + length + length % 2;
  }
  return null;
}

double? _flacDuration(Uint8List bytes) {
  if (_tag(bytes, 0, 4) != 'fLaC' || bytes.length < 42 || bytes[4] & 0x7f != 0) return null;
  final rate = bytes[18] << 12 | bytes[19] << 4 | bytes[20] >> 4;
  final samples = (bytes[21] & 15) * 0x100000000 + (bytes[22] << 24 | bytes[23] << 16 | bytes[24] << 8 | bytes[25]);
  return rate == 0 ? null : samples / rate;
}

double? _mpegDuration(Uint8List bytes) {
  var offset = 0;
  if (_tag(bytes, 0, 3) == 'ID3' && bytes.length >= 10) {
    offset = 10 + ((bytes[6] & 127) << 21 | (bytes[7] & 127) << 14 | (bytes[8] & 127) << 7 | bytes[9] & 127);
  }
  const rates = [44100, 48000, 32000];
  const high = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
  const low = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
  var duration = 0.0, frames = 0;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 255 || bytes[offset + 1] & 0xe0 != 0xe0) {
      if (frames != 0 || offset > 16384) break;
      offset++; continue;
    }
    final version = bytes[offset + 1] >> 3 & 3, layer = bytes[offset + 1] >> 1 & 3;
    final rateIndex = bytes[offset + 2] >> 2 & 3, bitrateIndex = bytes[offset + 2] >> 4;
    if (version == 1 || layer != 1 || rateIndex == 3 || bitrateIndex == 0 || bitrateIndex == 15) break;
    final rate = rates[rateIndex] ~/ (version == 3 ? 1 : version == 2 ? 2 : 4);
    final bitrate = (version == 3 ? high : low)[bitrateIndex] * 1000;
    final size = (version == 3 ? 144 : 72) * bitrate ~/ rate + (bytes[offset + 2] >> 1 & 1);
    if (size < 4 || offset + size > bytes.length) break;
    duration += (version == 3 ? 1152 : 576) / rate;
    frames++; offset += size;
  }
  return frames == 0 ? null : duration;
}

double? _mp4Duration(Uint8List bytes) {
  if (_tag(bytes, 4, 4) != 'ftyp') return null;
  final data = ByteData.sublistView(bytes);
  List<({int start, int end, String type})> boxes(int start, int end) {
    final result = <({int start, int end, String type})>[];
    while (start + 8 <= end) {
      var size = data.getUint32(start), header = 8;
      if (size == 1) { if (start + 16 > end) break; size = data.getUint64(start + 8); header = 16; }
      if (size == 0) size = end - start;
      if (size < header || size > end - start) break;
      result.add((start: start + header, end: start + size, type: _tag(bytes, start + 4, 4)));
      start += size;
    }
    return result;
  }
  for (final moov in boxes(0, bytes.length).where((box) => box.type == 'moov')) {
    for (final track in boxes(moov.start, moov.end).where((box) => box.type == 'trak')) {
      for (final media in boxes(track.start, track.end).where((box) => box.type == 'mdia')) {
        final children = boxes(media.start, media.end);
        if (!children.any((box) => box.type == 'hdlr' && _tag(bytes, box.start + 8, 4) == 'soun')) continue;
        for (final header in children.where((box) => box.type == 'mdhd')) {
          final wide = bytes[header.start] == 1;
          if (header.end - header.start < (wide ? 32 : 20)) continue;
          final rate = data.getUint32(header.start + (wide ? 20 : 12));
          final samples = wide ? data.getUint64(header.start + 24) : data.getUint32(header.start + 16);
          if (rate > 0 && samples >= 0) return samples / rate;
        }
      }
    }
  }
  return null;
}

double? _oggDuration(Uint8List bytes) {
  if (_tag(bytes, 0, 4) != 'OggS') return null;
  final data = ByteData.sublistView(bytes);
  int? serial, rate;
  var skip = 0, last = 0;
  for (var offset = 0; offset + 27 <= bytes.length;) {
    if (_tag(bytes, offset, 4) != 'OggS') break;
    final segments = bytes[offset + 26], start = offset + 27 + segments;
    if (start > bytes.length) break;
    final size = bytes.sublist(offset + 27, start).fold<int>(0, (sum, byte) => sum + byte);
    if (start + size > bytes.length) break;
    final id = data.getUint32(offset + 14, Endian.little);
    if (serial == null && size >= 19 && _tag(bytes, start, 8) == 'OpusHead') {
      serial = id; rate = 48000; skip = data.getUint16(start + 10, Endian.little);
    } else if (serial == null && size >= 30 && _tag(bytes, start, 7) == '\x01vorbis') {
      serial = id; rate = data.getUint32(start + 12, Endian.little);
    }
    if (id == serial) { final granule = data.getUint64(offset + 6, Endian.little); if (granule >= 0) last = granule; }
    offset = start + size;
  }
  return rate == null || rate == 0 || last < skip ? null : (last - skip) / rate;
}
