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

ToolDefinition catalogDefinition(Json tool, {Json? mcp}) {
  final guidance = [
    for (final server in (mcp?['instructions'] as List? ?? []).map(jsonObject))
      if (tool['namespace'] == (server['namespace'] ?? 'mcp__${server['server']}'))
        server['text'] as String,
  ];
  return ToolDefinition.fromJson({
    ...tool, 'name': tool['tool_name'],
    if (guidance.isNotEmpty) 'namespace_description': guidance.join('\n'),
  });
}
