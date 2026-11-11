import 'dart:convert';
import 'dart:io';

import 'package:desktop/conversation_data.dart';
import 'package:desktop/conversation_tools.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';

void main() {
  testWidgets('collapsed transcripts release large results and expand from committed history', (tester) async {
    late Directory root;
    late AgentServer server;
    late DesktopSession session;
    final task = DesktopTask('large-results', 'Conversation');
    final text = 'Output begins\n${'saved text\n' * 10000}Output ends';
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('conversation-output-');
      final config = {'cwd': root.path, 'provider': 'openai', 'model': 'fixture'};
      final store = TaskStore(root.path, task.id);
      try {
        store.append('task.created', config, metadata: {'config': config});
        store.append('turn.started', {'turnId': 'turn'});
        for (final type in ['dynamicToolCall', 'mcpToolCall']) {
          // MCP's durable history bounds each result to 64 KiB.
          final output = type == 'mcpToolCall' ? text.substring(0, 40000) : text;
          final content = [{'type': 'text', 'text': output}];
          store.append('native.item.completed', {'turnId': 'turn', 'completedAtMs': 1000,
            'item': {'id': type, 'type': type, 'tool': 'fixture', 'status': 'completed',
              'arguments': <String, Object?>{},
              if (type == 'dynamicToolCall') 'contentItems': content
              else ...{'server': 'remote', 'result': {'content': content}}}});
        }
        store.append('turn.completed', {});
      } finally { store.close(); }
      server = await AgentServer.startLocal(directory: root.path,
        configPath: '${root.path}/config.yaml', skillsHome: root.path);
      session = DesktopSession(AgentClient.local(server), await openDesktopDatabase(root.path));
      await session.loadHistory(task);
      while (task.historyBefore != null) { await session.loadEarlier(task); }
    });
    addTearDown(() async {
      await session.close(); await server.close(); task.liveText.dispose(); await root.delete(recursive: true);
    });
    expect(task.loadError, isNull);
    expect(jsonEncode(task.messages).length, lessThan(8192),
      reason: 'Closed tool disclosures must not retain full saved output in the transcript cache.');
    final tools = conversation(task).where((entry) => entry.tool != null).map((entry) => entry.tool!).toList();
    expect(tools, hasLength(2));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConversationDataScope(
      client: session.client,
      child: Column(children: [for (final tool in tools) ConversationToolCall(tool: tool, onExpand: () {})])))));
    await tester.pumpAndSettle();
    expect(find.textContaining(text), findsNothing);
    for (final tool in tools) {
      final output = tool.id == 'mcpToolCall' ? text.substring(0, 40000) : text;
      final header = find.descendant(of: find.byKey(PageStorageKey('tool:${tool.id}')),
        matching: find.byType(InkWell)).first;
      await tester.runAsync(() async { await tester.tap(header); });
      // Real SQLite and worker formatting complete outside the widget clock.
      for (var attempt = 0; attempt < 100 && find.textContaining(output).evaluate().isEmpty; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(find.textContaining(output), findsOneWidget);
      await tester.tap(header); await tester.pumpAndSettle();
      expect(find.textContaining(output), findsNothing);
      expect(jsonEncode(task.messages).length, lessThan(8192),
        reason: 'Expanding a saved result must not repopulate the transcript cache.');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
