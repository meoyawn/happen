import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'discovery.dart';

/// Global instructions have an independent budget; the server owns repository discovery.
Future<Json> loadAgentsMd(
  Json repository,
  String globalDirectory,
  CancellationToken cancellation,
) async {
  cancellation.throwIfCancelled();
  final files = <Json>[];
  final seen = <String>{};
  var truncated = false;
  Future<void> load(Iterable<Directory> directories) async {
    var remaining = 32768;
    for (final directory in directories) {
      cancellation.throwIfCancelled();
      for (final name in ['AGENTS.override.md', 'AGENTS.md']) {
        final file = File('${directory.path}/$name');
        if (await FileSystemEntity.type(file.path) !=
            FileSystemEntityType.file) {
          continue;
        }
        final path = await file.resolveSymbolicLinks();
        if (!seen.add(path)) break;
        final bytes = <int>[];
        final chunks = StreamIterator(file.openRead(0, remaining + 1));
        try {
          while (await chunks.moveNext().asCancellable(
            cancellation,
            onCancel: () => unawaited(chunks.cancel()),
          )) {
            bytes.addAll(chunks.current);
          }
        } finally {
          await chunks.cancel();
        }
        final cut = bytes.length > remaining;
        final content = utf8.decode(
          bytes.take(remaining).toList(),
          allowMalformed: true,
        );
        if (content.trim().isNotEmpty || cut) {
          files.add({
            'path': file.absolute.path,
            'scope': directory.absolute.path,
            'text': content,
            'global': true,
            if (cut) 'truncated': true,
          });
          remaining -= content.isEmpty ? 0 : bytes.length.clamp(0, remaining);
        }
        truncated |= cut;
        break;
      }
      if (remaining == 0) {
        truncated = true;
        break;
      }
    }
  }

  await load([Directory(globalDirectory)]);
  files.addAll((repository['files'] as List).map(jsonObject));
  truncated |= repository['truncated'] == true;
  cancellation.throwIfCancelled();
  return {'cwd': repository['cwd'], 'files': files, 'truncated': truncated};
}

bool isHarnessContext(ConversationItem item) => item.native['harness'] is Map;

/// Restore current context exactly; summaries are not responsible for these rules.
List<ConversationItem> restoreContext(
  List<ConversationItem> compacted,
  List<ConversationItem> previous,
  Json snapshot,
  String cwd,
  String baselineEffort,
  String effectiveEffort,
  bool reasoningUpdates, {
  Json? mcpSnapshot,
  Json? clientSnapshot,
  List<ToolDefinition> initialTools = const [],
  ToolDefinition? discovery,
  String? Function(List<Json>, List<Json>?)? catalogContext,
  required ConversationItem Function(Json, Json?) instructionContext,
  required ConversationItem Function(String, {bool replacement}) environmentContext,
  List<ConversationItem> providerContext = const [],
}) {
  final known = {
    for (final tool in initialTools) toolKey(tool): tool,
    ...loadedTools(previous),
  };
  // A retained search exchange still needs its matching result, but selected
  // schemas are restored once from the current catalog below.
  ConversationItem withoutSearchTools(ConversationItem item) => item.content.any((part) =>
    part['type'] == 'tool_result' && part['format'] == 'search',
  ) ? ConversationItem(
    id: item.id, kind: item.kind, role: item.role, content: item.content,
    settings: item.settings, native: item.native,
  ) : item;
  final result = compacted
      .where((item) => !isHarnessContext(item) && item.kind != 'configuration')
      .map(withoutSearchTools)
      .toList();
  final keptIds = result.map((item) => item.id).toSet();
  final retained = previous.where(
    (item) =>
        !isHarnessContext(item) &&
        (item.kind == 'tools' ||
            item.role == 'system' ||
            item.role == 'developer') &&
        !keptIds.contains(item.id),
  );
  final initial = [
    ...retained,
    ...providerContext,
    if (discovery != null && !initialTools.any((tool) => toolKey(tool) == toolKey(discovery)))
      ConversationItem(kind: 'tools', tools: [discovery],
        native: {'harness': {'context': 'discovery'}},
      ),
    if ((snapshot['files'] as List).isNotEmpty) instructionContext(snapshot, null),
    environmentContext(cwd),
    if (catalogContext?.call(deferredCatalog(mcpSnapshot ?? {}, clientSnapshot ?? {}), null) case final String text)
      ConversationItem(role: 'developer', content: [{'type': 'text', 'text': text}],
        native: {'harness': {'context': 'tool_catalog'}}),
    if (discovery != null && mcpSnapshot != null &&
        ((mcpSnapshot['tools'] as List? ?? []).isNotEmpty ||
            (mcpSnapshot['instructions'] as List? ?? []).isNotEmpty)) ...[
      if ((mcpSnapshot['tools'] as List? ?? []).isNotEmpty)
        ..._restoreTools(mcpToolDefinitions(mcpSnapshot), known),
    ],
    if (discovery != null && clientSnapshot != null && (clientSnapshot['tools'] as List).isNotEmpty) ...[
      ..._restoreTools(clientToolDefinitions(clientSnapshot), known),
    ],
  ];
  var insertion = result.lastIndexWhere(
    (item) => item.role == 'user' && item.kind == 'message',
  );
  if (insertion < 0) {
    insertion = result.lastIndexWhere((item) => item.kind == 'compaction');
  }
  if (insertion < 0) insertion = result.length;
  result.insertAll(insertion, initial);
  if (reasoningUpdates && effectiveEffort != baselineEffort) {
    // A following user context item also makes the update valid after manual compaction.
    result.add(
      ConversationItem(
        kind: 'configuration',
        settings: {'reasoning': effectiveEffort},
      ),
    );
    result.add(
      ConversationItem(
        role: 'user',
        content: [
          {'type': 'text', 'text': 'Continue with the current task settings.'},
        ],
        native: {
          'harness': {'context': 'configuration'},
        },
      ),
    );
  }
  return result;
}

List<ConversationItem> _restoreTools(ConversationItem item, Map<String, ToolDefinition> known) {
  final selected = item.tools.where((tool) => known.containsKey(toolKey(tool))).toList();
  return [if (selected.isNotEmpty) ConversationItem(kind: 'tools', tools: selected, native: item.native)];
}

ConversationItem clientToolDefinitions(Json snapshot) => ConversationItem(
  kind: 'tools',
  tools: (snapshot['tools'] as List)
      .map((raw) => ToolDefinition.fromJson(jsonObject(raw)))
      .toList(),
  native: {
    'harness': {'context': 'client_tools'},
  },
);

// Codex's WorldStateHash sorts JSON objects before comparing tool definitions.
String contextFingerprint(Object? value) {
  Object? ordered(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: ordered(value[key])};
    }
    if (value is List) return value.map(ordered).toList();
    return value;
  }
  return jsonEncode(ordered(value));
}

ConversationItem mcpToolDefinitions(Json snapshot) => ConversationItem(
  kind: 'tools',
  tools: (snapshot['tools'] as List)
      .map((raw) => catalogDefinition(jsonObject(raw), mcp: snapshot))
      .toList(),
  native: {
    'harness': {'context': 'mcp'},
  },
);
