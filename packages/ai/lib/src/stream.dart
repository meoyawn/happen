import 'dart:convert';

import 'package:protocol/protocol.dart' show boundedLines;

/// SSE framing shared by HTTP model and MCP transports. Bounds each event.
Stream<Map<String, dynamic>> decodeSse(
  Stream<List<int>> bytes, {
  int maxEventBytes = 8 * 1024 * 1024,
}) async* {
  var data = <String>[];
  var size = 0;
  await for (final line in boundedLines(bytes, maxBytes: maxEventBytes)) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final payload = data.join('\n');
        if (payload == '[DONE]') return;
        final value = jsonDecode(payload);
        if (value is! Map) {
          throw const FormatException('Expected an SSE JSON object');
        }
        yield Map<String, dynamic>.from(value);
      }
      data = [];
      size = 0;
    } else if (line.startsWith('data:')) {
      final value = line.substring(5).replaceFirst(RegExp(r'^ '), '');
      size += utf8.encode(value).length;
      if (size > maxEventBytes) {
        throw const FormatException('SSE event too large');
      }
      data.add(value);
    }
  }
  if (data.isNotEmpty && data.join('\n') != '[DONE]') {
    final value = jsonDecode(data.join('\n'));
    if (value is! Map) {
      throw const FormatException('Expected an SSE JSON object');
    }
    yield Map<String, dynamic>.from(value);
  }
}
