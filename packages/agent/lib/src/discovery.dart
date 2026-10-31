import 'dart:convert';
import 'dart:math';

import 'package:ai/ai.dart';
import 'package:code_mode/code_mode.dart';
import 'package:protocol/protocol.dart';

String toolKey(ToolDefinition tool) => '${tool.namespace ?? ''}.${tool.name}';

Map<String, ToolDefinition> loadedTools(Iterable<ConversationItem> input) => {
  for (final item in input)
    for (final tool in item.tools) toolKey(tool): tool,
};

List<Json> deferredCatalog(Json mcp, Json client) => [
  ...(mcp['tools'] as List? ?? []).map(jsonObject),
  for (final raw in client['tools'] as List? ?? [])
    {...jsonObject(raw), 'tool_name': raw['name'], 'name': 'client__${raw['name']}'},
];

ToolDefinition catalogDefinition(Json tool, {Json? mcp}) {
  final guidance = [
    for (final server in (mcp?['instructions'] as List? ?? []).map(jsonObject))
      if (tool['namespace'] == (server['namespace'] ?? 'mcp__${server['server']}'))
        'Usage guidance supplied by MCP server ${server['server']}:\n${server['text']}',
  ];
  return ToolDefinition.fromJson({
    ...tool, 'name': tool['tool_name'],
    if (guidance.isNotEmpty) 'description': '${tool['description'] ?? ''}\n\n${guidance.join('\n')}',
  });
}

/// Tokenized BM25 with deterministic tie breaking and exact-name preference.
/// A catalog is local host metadata; only the selected results enter history.
List<Json> searchTools(List<Json> catalog, Json arguments) {
  final query = requiredString(arguments, 'query').trim();
  final limit = arguments['limit'] ?? 8;
  if (query.isEmpty) throw const FormatException('query must not be empty');
  if (limit is! int || limit < 1 || limit > 32) {
    throw const FormatException('limit must be an integer between 1 and 32');
  }
  List<String> words(String text) => RegExp(r'[\p{L}\p{N}]+', unicode: true)
      .allMatches(text.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}').toLowerCase())
      .map((match) => match.group(0)!).toList();
  final terms = words(query).toSet();
  if (terms.isEmpty || catalog.isEmpty) return [];
  final documents = [for (final tool in catalog) words(
    '${tool['name']} ${tool['namespace']} ${tool['tool_name']} ${tool['description'] ?? ''}',
  )];
  final average = documents.fold<int>(0, (sum, doc) => sum + doc.length) / documents.length;
  final frequencies = {
    for (final term in terms) term: documents.where((doc) => doc.contains(term)).length,
  };
  final ranked = <({Json tool, double score})>[];
  for (var i = 0; i < catalog.length; i++) {
    final tool = catalog[i], doc = documents[i];
    var score = 0.0;
    for (final term in terms) {
      final tf = doc.where((word) => word == term).length;
      if (tf == 0) continue;
      final df = frequencies[term]!;
      final idf = log(1 + (documents.length - df + 0.5) / (df + 0.5));
      score += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * doc.length / average));
    }
    if ([tool['name'], '${tool['namespace']}.${tool['tool_name']}']
        .any((name) => name.toString().toLowerCase() == query.toLowerCase())) {
      score += 1000000;
    }
    if (score > 0) ranked.add((tool: tool, score: score));
  }
  ranked.sort((a, b) {
    final score = b.score.compareTo(a.score);
    return score == 0 ? (a.tool['name'] as String).compareTo(b.tool['name'] as String) : score;
  });
  return ranked.take(limit).map((entry) => entry.tool).toList();
}

Json discoveryResult(List<Json> selected, Json mcp) => {
  'tools': [for (final tool in selected) describeHostTool(tool)],
  if (selected.any((tool) => (tool['namespace'] as String).startsWith('mcp__')))
    'instructions': [
      for (final server in (mcp['instructions'] as List? ?? []).map(jsonObject))
        if (selected.any((tool) => tool['namespace'] == (server['namespace'] ?? 'mcp__${server['server']}'))) server,
    ],
};

String _bounded(String text, int bytes) {
  final result = StringBuffer();
  var size = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune), length = utf8.encode(String.fromCharCode(rune)).length;
    if (size + length > bytes) break;
    result.write(char);
    size += length;
  }
  return result.toString();
}

/// Only namespace summaries are automatic. Full schemas and server guidance
/// are delivered by discovery; native-loaded removals are explicitly named.
ConversationItem? catalogContext(
  Json current,
  Json? previous,
  Set<String> loaded, {
  required bool mcp,
}) {
  Map<String, String> guidance(Json? snapshot) => {
    for (final server in snapshot?['instructions'] as List? ?? [])
      server['namespace'] ?? 'mcp__${server['server']}': (server['text'] as String).trim(),
  };
  Map<String, String> summaries(Json? snapshot) {
    final counts = <String, int>{};
    for (final raw in snapshot?['tools'] as List? ?? []) {
      final namespace = raw['namespace'] as String;
      counts[namespace] = (counts[namespace] ?? 0) + 1;
    }
    final hints = {
      for (final entry in guidance(snapshot).entries)
        entry.key: _bounded(entry.value.replaceAll(RegExp(r'\s+'), ' '), 160),
    };
    return {for (final name in counts.keys.toList()..sort())
      name: '${counts[name]} tools${hints[name]?.isNotEmpty == true ? ': ${hints[name]}' : ''}',
    };
  }
  final before = summaries(previous), after = summaries(current);
  final beforeGuidance = guidance(previous), afterGuidance = guidance(current);
  final text = StringBuffer();
  for (final entry in after.entries) {
    final guidanceChanged = beforeGuidance[entry.key] != afterGuidance[entry.key];
    if (before[entry.key] != entry.value || guidanceChanged) {
      text.writeln('Deferred namespace ${entry.key}: ${entry.value}.');
    }
    if (guidanceChanged && (beforeGuidance[entry.key] ?? '').isNotEmpty) {
      text.writeln('Previously retrieved usage guidance for ${entry.key} no longer applies. '
        'Search again for the current guidance.');
    }
  }
  for (final name in before.keys.where((name) => !after.containsKey(name))) {
    text.writeln('Deferred namespace $name is unavailable.');
  }
  final currentKeys = {
    for (final raw in current['tools'] as List? ?? [])
      '${raw['namespace']}.${mcp ? raw['tool_name'] : raw['name']}',
  };
  final removed = [
    for (final raw in previous?['tools'] as List? ?? [])
      if (loaded.contains('${raw['namespace']}.${mcp ? raw['tool_name'] : raw['name']}') &&
          !currentKeys.contains('${raw['namespace']}.${mcp ? raw['tool_name'] : raw['name']}'))
        mcp ? raw['name'] : 'client.${raw['name']}',
  ]..sort();
  if (removed.isNotEmpty) {
    text.writeln('Removed ${mcp ? 'MCP' : 'client'} tools: ${removed.join(', ')}. These tools are unavailable.');
  }
  if (text.isEmpty) return null;
  text.writeln('Search with tools.tool_search({query, limit}) in code mode, or tool_search for direct calls.');
  if (!mcp && (previous?['tools'] as List? ?? []).isEmpty && after.isNotEmpty) {
    text.writeln('Client calls run in the connected client. After disconnection or cancellation, inspect state before repeating an action.');
  }
  final content = text.toString();
  return ConversationItem(
    role: 'developer',
    content: [{'type': 'text', 'text': utf8.encode(content).length <= 4096 ? content
      : '${_bounded(content, 4000)}\n[Namespace listing truncated; search or filter ALL_TOOLS for more.]'}],
    native: {'harness': {'context': mcp ? 'mcp' : 'client_tools'}},
  );
}
