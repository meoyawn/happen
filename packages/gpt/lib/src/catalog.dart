import 'dart:convert';

import 'package:protocol/protocol.dart';

import 'catalog_data.dart';

const gptCatalogRevision = '2681f8cba2831ef72bca2c0672b2e49d5f690745';
const supportedGptModels = {
  'gpt-6.1-sol',
  'gpt-6-astra',
  'gpt-6.1-terra',
  'gpt-6-sol',
  'gpt-6-luna',
};

final _catalog = {
  for (final value
      in (jsonObject(jsonDecode(modelCatalogJson))['models'] as List))
    (value as Map)['slug'] as String: jsonObject(value),
};

class GptModel {
  GptModel(String model)
    : data =
          _catalog[model] ??
          (throw ArgumentError('Unknown GPT model: $model')) {
    if (!supportedGptModels.contains(model))
      throw ArgumentError('GPT model is not supported by this harness: $model');
  }
  final Json data;
  String get id => data['slug'] as String;
  String get defaultReasoning => data['default_reasoning_level'] as String;
  List<String> get reasoningLevels =>
      (data['supported_reasoning_levels'] as List)
          .map((entry) => entry['effort'] as String)
          .where((value) => value != 'ultra')
          .toList();
  int get contextWindow => data['context_window'] as int;
  int get maxContextWindow =>
      data['max_context_window'] as int? ?? contextWindow;
  bool get reasoningUpdates =>
      data['supports_reasoning_effort_updates'] == true;
  String get verbosity => data['default_verbosity'] as String? ?? 'low';
  String get reasoningSummary =>
      data['default_reasoning_summary'] as String? ?? 'none';
  String get instructions => requiredString(
    jsonObject(data['model_messages']),
    'instructions_template',
  );
  String get persistentInstructions =>
      data['model_messages']['persistent_instructions'] as String? ?? '';
}
