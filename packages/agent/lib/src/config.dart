import 'package:protocol/protocol.dart';

import 'providers.dart';

Json initialConfiguration(Json input, String cwd, bool telemetry) {
  final settings = jsonObject(input['provider_settings']);
  final interface = toolInterface(input['provider'] as String);
  return {
    'cwd': cwd,
    'provider': input['provider'],
    'model': input['model'],
    'provider_settings': settings,
    'reasoning_updates': input['reasoning_updates'] == true,
    'catalog_revision': input['catalog_revision'],
    'instructions': interface.baseInstructions(input['model'] as String, input['instructions'] as String),
    'tool_interface': interface.id,
    'telemetry': input['telemetry'] ?? telemetry,
    'global_directory': input['global_directory'],
  };
}
