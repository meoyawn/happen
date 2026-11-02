import 'dart:convert';

import 'package:protocol/protocol.dart';

import 'output.dart';

/// Images are preserved; mixed text/audio consume the observation budget in
/// source order. The cost excludes images, which the AI record counts separately.
({List<Json> items, int textAudioTokens}) renderCellContent(Json collected, int tokens) {
  final head = collected['head'] as List, tail = collected['tail'] as List;
  final lostImages = collected['omittedImages'] as int? ?? 0, lostAudio = collected['omittedAudio'] as int? ?? 0;
  if ([...head, ...tail].every((item) => item is String) && lostImages == 0 && lostAudio == 0) {
    final items = [for (final text in renderCellOutput(collected, tokens)) {'type': 'input_text', 'text': text}];
    return (items: items, textAudioTokens: items.fold<int>(0, (sum, part) => sum + (utf8.encode(part['text']!).length + 3) ~/ 4));
  }
  final result = <Json>[];
  var remaining = tokens, omittedText = 0, omittedAudio = 0, audioTokens = 0;
  String notice(int bytes, int items, int images, int audio) =>
    '[Code Mode session output limit reached: omitted $bytes text bytes; discarded $items text segments, $images images, $audio audio items]';
  final bytes = collected['omittedBytes'] as int, items = collected['omittedItems'] as int;
  final raw = [...head,
    if (bytes != 0 || items != 0 || lostImages != 0 || lostAudio != 0) {'_notice': notice(bytes, items, lostImages, lostAudio)},
    ...tail];
  for (final value in raw) {
    if (value is Map && value['_notice'] is String) {
      result.add({'type': 'input_text', 'text': value['_notice']}); continue;
    }
    if (value is Map && value['_omission'] is Map) {
      final loss = value['_omission'] as Map;
      result.add({'type': 'input_text', 'text': notice(0, 0, loss['images'] as int, loss['audio'] as int)}); continue;
    }
    final part = value is String ? {'type': 'input_text', 'text': value} : jsonObject(value);
    switch (part['type']) {
      case 'input_image': result.add(part);
      case 'input_audio':
        final cost = part.remove('_audio_tokens') as int? ?? (utf8.encode(part['audio_url'] as String).length + 3) ~/ 4;
        if (cost <= remaining) { remaining -= cost; audioTokens += cost; result.add(part); }
        else { omittedAudio++; }
      case 'input_text':
        final text = part['text'] as String;
        if (text.isEmpty) continue;
        if (remaining == 0) { omittedText++; continue; }
        final cost = (utf8.encode(text).length + 3) ~/ 4;
        result.add({'type': 'input_text', 'text': truncateTokenText(text, maxTokens: remaining)});
        remaining = cost <= remaining ? remaining - cost : 0;
      default: throw StateError('Unknown cell content: ${part['type']}');
    }
  }
  if (omittedText > 0) result.add({'type': 'input_text', 'text': '[omitted $omittedText text items ...]'});
  if (omittedAudio > 0) result.add({'type': 'input_text', 'text': '[omitted $omittedAudio audio items ...]'});
  return (items: result, textAudioTokens: audioTokens + result.where((part) => part['type'] == 'input_text')
    .fold<int>(0, (sum, part) => sum + (utf8.encode(part['text'] as String).length + 3) ~/ 4));
}
