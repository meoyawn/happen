import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

/// Codex's ancestor-chain discovery. Descendant checks are agent guidance.
Future<Json> loadAgentsMd(
  String cwd,
  String globalDirectory,
  CancellationToken cancellation,
) async {
  cancellation.throwIfCancelled();
  final current = Directory(await Directory(cwd).resolveSymbolicLinks());
  final chain = <Directory>[];
  var cursor = current;
  var foundRoot = false;
  while (true) {
    cancellation.throwIfCancelled();
    chain.add(cursor);
    if (await FileSystemEntity.type('${cursor.path}/.git') !=
        FileSystemEntityType.notFound) {
      foundRoot = true;
      break;
    }
    if (cursor.parent.path == cursor.path) break;
    cursor = cursor.parent;
  }
  final project = foundRoot ? chain.reversed : [current];
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
  await load(project);
  cancellation.throwIfCancelled();
  return {'cwd': current.path, 'files': files, 'truncated': truncated};
}

ConversationItem instructionMessage(Json snapshot, {bool replacement = false}) {
  final files = (snapshot['files'] as List).map(jsonObject);
  final text = StringBuffer(
    '# AGENTS.md instructions for ${snapshot['cwd']}\n\n',
  );
  if (replacement) {
    text.writeln(
      'These AGENTS.md instructions replace all previously provided AGENTS.md instructions.',
    );
  }
  if (files.isEmpty) {
    text.writeln(
      'No automatically loaded AGENTS.md instructions currently apply.',
    );
  } else {
    for (final file in files) {
      text.writeln(
        '\nInstructions from ${file['path']} (scope: ${file['scope']}):\n${file['text']}',
      );
      if (file['truncated'] == true) {
        text.writeln(
          '[File truncated: read the full file before working in its scope.]',
        );
      }
    }
  }
  if (snapshot['truncated'] == true) {
    text.writeln(
      '[Instruction budget reached. Check applicable files for omitted instructions.]',
    );
  }
  return ConversationItem(
    role: 'user',
    content: [
      {'type': 'text', 'text': text.toString()},
    ],
    native: {
      'harness': {'context': 'agents_md'},
    },
  );
}

ConversationItem environmentMessage(String cwd) => ConversationItem(
  role: 'user',
  content: [
    {'type': 'text', 'text': 'Current working directory: $cwd'},
  ],
  native: {
    'harness': {'context': 'environment'},
  },
);

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
}) {
  final result = compacted
      .where((item) => !isHarnessContext(item) && item.kind != 'configuration')
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
    instructionMessage(snapshot),
    environmentMessage(cwd),
    if (mcpSnapshot != null) ...[
      if ((mcpSnapshot['tools'] as List? ?? []).isNotEmpty)
        mcpToolDefinitions(mcpSnapshot),
      mcpContext(mcpSnapshot),
    ],
    if (clientSnapshot != null) ...[
      if ((clientSnapshot['tools'] as List).isNotEmpty)
        clientToolDefinitions(clientSnapshot),
      clientToolsContext(clientSnapshot),
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

ConversationItem clientToolDefinitions(Json snapshot) => ConversationItem(
  kind: 'tools',
  tools: (snapshot['tools'] as List)
      .map((raw) => ToolDefinition.fromJson(jsonObject(raw)))
      .toList(),
  native: {
    'harness': {'context': 'client_tools'},
  },
);

ConversationItem clientToolsContext(Json snapshot) => ConversationItem(
  role: 'developer',
  content: [
    {
      'type': 'text',
      'text':
          'Client tools currently available: '
          '${(snapshot['tools'] as List).map((tool) => 'client.${tool['name']}').join(', ')}. '
          'This replaces earlier client tool availability notices. All other client tools are unavailable. '
          'In code mode call tools.client__NAME; ALL_TOOLS includes parameters and descriptions. '
          'Calls run in the connected client. A disconnect or cancellation may leave their outcome unknown; inspect state before repeating an action.',
    },
  ],
  native: {
    'harness': {'context': 'client_tools'},
  },
);

ConversationItem mcpToolDefinitions(Json snapshot) => ConversationItem(
  kind: 'tools',
  tools: (snapshot['tools'] as List)
      .map((raw) => ToolDefinition.fromJson({
        ...jsonObject(raw),
        'name': raw['tool_name'],
      }))
      .toList(),
  native: {
    'harness': {'context': 'mcp'},
  },
);

ConversationItem mcpContext(Json snapshot) {
  final tools = (snapshot['tools'] as List? ?? []).map(jsonObject);
  final text = StringBuffer(
    'Current configured MCP host tools (this replaces earlier MCP availability notices):\n',
  );
  text.writeln(tools.map((tool) => tool['name']).join(', '));
  text.writeln(
    'New or changed tools are declared in the appended tool definitions. '
    'In code mode use the host names above; ALL_TOOLS includes their descriptions and parameters. '
    'Only the tools in this notice are currently available; removed tools are unavailable.',
  );
  for (final server in (snapshot['instructions'] as List? ?? []).map(
    jsonObject,
  )) {
    text.writeln(
      'Usage guidance supplied by MCP server ${server['server']}:\n${server['text']}',
    );
  }
  return ConversationItem(
    role: 'developer',
    content: [
      {'type': 'text', 'text': clippedText(text.toString())},
    ],
    native: {
      'harness': {'context': 'mcp'},
    },
  );
}
