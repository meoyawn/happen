import 'package:protocol/protocol.dart';

import 'tool_specs.dart';

Json initialConfiguration(Json input, String cwd, bool telemetry) {
  final settings = jsonObject(input['provider_settings']);
  return {
    'cwd': cwd,
    'provider': input['provider'],
    'model': input['model'],
    'reasoning': settings['reasoning'],
    'provider_settings': settings,
    'reasoning_updates': input['reasoning_updates'] == true,
    'catalog_revision': input['catalog_revision'],
    'base_instructions': input['base_instructions'],
    'instructions': '${input['base_instructions']}\n\n$agentInstructions',
    'tools': [codeDefinition.toJson()],
    'host_catalog': hostCatalog,
    'telemetry': input['telemetry'] ?? telemetry,
    'global_directory': input['global_directory'],
  };
}
