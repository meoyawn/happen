import 'package:protocol/protocol.dart';

import 'providers.dart';

Json initialConfiguration(Json input, String cwd, bool telemetry) {
  final settings = jsonObject(input['provider_settings']);
  final interface = toolInterface(input['provider'] as String);
  return {
    'cwd': cwd,
    'provider': input['provider'],
    'model': input['model'],
    'reasoning': settings['reasoning'],
    'provider_settings': settings,
    'reasoning_updates': input['reasoning_updates'] == true,
    'catalog_revision': input['catalog_revision'],
    'base_instructions': input['base_instructions'],
    'instructions': interface.baseInstructions(input['model'] as String, input['base_instructions'] as String),
    'tool_interface': interface.id,
    'tools': interface.definitions.map((tool) => tool.toJson()).toList(),
    'host_catalog': interface.hostCatalog,
    'telemetry': input['telemetry'] ?? telemetry,
    'global_directory': input['global_directory'],
  };
}
