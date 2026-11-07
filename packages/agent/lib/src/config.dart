import 'package:protocol/protocol.dart';

import 'providers.dart';

Json initialConfiguration(Json input, String cwd, bool telemetry) {
  final settings = {...jsonObject(input['provider_settings']),
    if (input['provider'] == 'openai') 'goals': input['ephemeral'] != true};
  final interface = toolInterface(input['provider'] as String, model: input['model'] as String, settings: settings);
  return {
    'cwd': cwd,
    'provider': input['provider'],
    'model': input['model'],
    'provider_settings': settings,
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
