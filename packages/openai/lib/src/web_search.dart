import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'web_search_schema.dart';
import 'web_search_description.dart';

// SearchCommands at Codex 2681f8cba2831ef72bca2c0672b2e49d5f690745.
const webSearchDefinition = ToolDefinition(
  name: 'run',
  namespace: 'web',
  description: webSearchInstructions,
  parameters: webSearchParameters,
);

const webSearchHost = <String, dynamic>{
  'name': 'web__run', 'namespace': 'web', 'tool_name': 'run',
  'namespace_description': 'Tools in the web namespace.',
  'description': webSearchInstructions, 'parameters': webSearchParameters,
};

Json webSearchCommands(Object? value) {
  final commands = jsonObject(value);
  validateToolInput(commands, webSearchParameters, 'web.run');
  return commands;
}
