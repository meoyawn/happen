import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

String toolKey(ToolDefinition tool) => '${tool.namespace ?? ''}.${tool.name}';

Map<String, ToolDefinition> loadedTools(Iterable<ConversationItem> input) => {
  for (final item in input)
    for (final tool in item.tools) toolKey(tool): tool,
};

List<Json> deferredCatalog(Json mcp, Json client) => [
  for (final raw in mcp['tools'] as List? ?? []) {
    ...jsonObject(raw),
    'namespace_description': (mcp['instructions'] as List? ?? []).where((server) =>
      raw['namespace'] == (server['namespace'] ?? 'mcp__${server['server']}'),
    ).map((server) => server['text']).join('\n'),
  },
  for (final raw in client['tools'] as List? ?? [])
    {...jsonObject(raw), 'tool_name': raw['name'], 'name': 'client__${raw['name']}'},
];
