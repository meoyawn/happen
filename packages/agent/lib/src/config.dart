import 'package:protocol/protocol.dart';
import 'package:openai/openai.dart';

import 'providers.dart';

Json initialConfiguration(Json input, String cwd, bool telemetry) {
  final settings = {...jsonObject(input['provider_settings']),
    if (input['provider'] == 'openai') 'goals': input['ephemeral'] != true};
  final modelInfo = input['model_info'] == null ? null : jsonObject(input['model_info']);
  final interface = toolInterface(input['provider'] as String, model: input['model'] as String, settings: settings, modelInfo: modelInfo);
  return {
    'cwd': cwd,
    'provider': input['provider'],
    'model': input['model'],
    'model_info': ?modelInfo,
    'provider_settings': settings,
    if (input['provider'] == 'openai') 'context_window': GptModel(input['model'] as String, metadata: modelInfo)
      .usableContextWindow(contextWindow: settings['context_limit'] as int?),
    'reasoning_updates': input['reasoning_updates'] == true,
    'catalog_revision': input['catalog_revision'],
    'instructions': interface.baseInstructions(input['model'] as String, input['instructions'] as String),
    if (input['developerInstructions'] is String) 'developer_instructions': input['developerInstructions'],
    if (input['ephemeral'] == true) 'ephemeral': true,
    if (input['threadSource'] != null) 'thread_source': input['threadSource'],
    'tool_interface': interface.id,
    'telemetry': input['telemetry'] ?? telemetry,
    'tracing': input['tracing'] == true,
    'global_directory': input['global_directory'],
  };
}
