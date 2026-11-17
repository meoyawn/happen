import 'dart:convert';

import 'package:protocol/protocol.dart';

import 'catalog_data.dart';

const gptCatalogRevision = '0122b120cd7d8375676ea2e72e113c2f892343b0';
const gptCatalogClientVersion = '0.169.0';
final bundledGptModels = Map<String, Json>.unmodifiable({
  for (final value
      in (jsonObject(jsonDecode(modelCatalogJson))['models'] as List))
    (value as Map)['slug'] as String: jsonObject(value),
});

String get defaultGptModel => catalogDefaultGptModel(bundledGptModels.values);

List<GptModel> catalogGptModels(Iterable<Json> models) =>
  (models.where((model) => model['visibility'] == 'list').toList()
    ..sort((a, b) => (a['priority'] as int).compareTo(b['priority'] as int)))
    .map((data) => GptModel(data['slug'] as String, metadata: data)).toList();

String catalogDefaultGptModel(Iterable<Json> models) => catalogGptModels(models).first.id;

class GptModel {
  GptModel(String model, {Json? metadata})
    : data =
          metadata ?? bundledGptModels[model] ??
          (throw ArgumentError('Unknown GPT model: $model')) {
    if (data['slug'] != model) throw const FormatException('Model metadata does not match its model');
  }
  final Json data;
  String get id => data['slug'] as String;
  String get defaultReasoning => data['default_reasoning_level'] as String;
  List<String> get reasoningLevels =>
      (data['supported_reasoning_levels'] as List)
          .map((entry) => entry['effort'] as String)
          .where((value) => value != 'ultra')
          .toList();
  int get contextWindow => (data['context_window'] ?? data['max_context_window']) as int;
  int get maxContextWindow =>
      data['max_context_window'] as int? ?? contextWindow;
  int usableContextWindow({int? contextWindow}) =>
      (contextWindow ?? this.contextWindow) * (data['effective_context_window_percent'] as int? ?? 95) ~/ 100;
  bool get reasoningUpdates =>
      data['supports_reasoning_effort_updates'] == true;
  String get verbosity => data['default_verbosity'] as String? ?? 'low';
  String get instructions => requiredString(
    jsonObject(data['model_messages']),
    'instructions_template',
  );
  String get persistentInstructions =>
      data['model_messages']['persistent_instructions'] as String? ?? '';
  String get contentFilterGuidance {
    final text = data['model_messages']['content_filter_guidance'];
    return text is String && text.trim().isNotEmpty && utf8.encode(text).length <= 512 ? text
      : 'Your previous response was blocked by a content filter. Do not treat this as a transient failure or try to reproduce or work around the blocked content through repeated attempts, altered formatting, splitting, encoding, tools, subagents, or later wakes. Briefly explain the limitation and offer a permitted alternative. Continue unrelated authorized work.';
  }
}
