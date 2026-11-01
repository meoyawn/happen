import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/context_usage.dart';
import 'package:desktop/context_window.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('context shows the saved prompt and current usage, expands raw messages, and exports the session', (tester) async {
    final client = _Client();
    late Directory root;
    late DesktopSession session;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('context-window-');
      session = DesktopSession(client, await openDesktopDatabase(root.path));
    });
    addTearDown(() async {
      await tester.runAsync(() async { await session.close(); await root.delete(recursive: true); });
    });
    final task = DesktopTask('session', 'Inspect context')..messages.addAll({
      'msg_old': {'id': 'msg_old', 'type': 'assistant', 'time': {'created': 1}, 'metadata': {'seq': 1},
        'tokens': {'input': 99999}, 'content': []},
      'msg_compact': {'id': 'msg_compact', 'type': 'compaction', 'status': 'completed', 'time': {'created': 2}, 'metadata': {'seq': 2}},
      for (final message in client.messages) message['id'] as String: message,
    });
    final downloads = Directory('${root.path}/Downloads');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 420, child: Column(children: [
      ContextUsageIndicator(messages: task.messages.values, limit: 1000, onPressed: () {}),
      Expanded(child: SessionContextWindow(session: session, task: task, downloadsDirectory: downloads)),
    ]))))));
    await tester.pumpAndSettle();
    expect(find.text('Total Tokens'), findsOneWidget);
    expect(find.text('120'), findsNWidgets(2));
    expect(find.text('99999'), findsNothing);
    expect(find.textContaining('msg_old'), findsNothing);
    final scrollable = find.descendant(of: find.byType(SessionContextWindow), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('System Prompt'), 200, scrollable: scrollable);
    expect(find.text('You are the saved system prompt.', findRichText: true), findsOneWidget);
    await tester.scrollUntilVisible(find.text('user • msg_user'), 200, scrollable: scrollable);
    await tester.tap(find.text('user • msg_user'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Raw request', findRichText: true), findsOneWidget);
    await tester.ensureVisible(find.text('Export session JSON'));
    final button = tester.widget<TextButton>(find.ancestor(of: find.text('Export session JSON'),
      matching: find.byWidgetPredicate((widget) => widget is TextButton)).first);
    await tester.runAsync(button.onPressed! as Future<void> Function());
    await tester.pumpAndSettle();
    final contents = await tester.runAsync(() async {
      final file = (await downloads.list().toList()).single as File;
      expect(file.path, endsWith('.json'));
      expect(file.path, contains('inspect-context-'));
      return file.readAsString();
    });
    expect(contents, contains('"messages"'));
    expect(contents, contains('Raw request'));
    final exported = jsonDecode(contents!) as Map;
    expect(exported['context']['systemMessageID'], 'msg_base');
    for (final key in ['data', 'system', 'systemMessage', 'cursor']) {
      expect((exported['context'] as Map).containsKey(key), false);
    }
    expect(RegExp('You are the saved system prompt.').allMatches(contents).length, 1);
    expect(client.methods, containsAll(['session.context', 'session.message.list']));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  final methods = <String>[];
  final messages = <Json>[
    {'id': 'msg_base', 'type': 'synthetic', 'role': 'developer', 'context': 'model',
      'text': 'You are the saved system prompt.', 'metadata': {'seq': 1}, 'time': {'created': 1}},
    {'id': 'msg_user', 'type': 'user', 'text': 'Raw request', 'files': [], 'metadata': {'seq': 3}, 'time': {'created': 3}},
    {'id': 'msg_answer', 'type': 'assistant', 'agent': 'build', 'model': {'providerID': 'opencode', 'id': 'fixture'},
      'content': [{'type': 'text', 'text': 'Answer'}], 'tokens': {'input': 70, 'output': 20, 'reasoning': 5, 'cache': {'read': 25, 'write': 0}},
      'metadata': {'seq': 4}, 'time': {'created': 4, 'completed': 5}},
  ];
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    methods.add(method);
    return method == 'session.context' ? {
      'sessionID': 'session', 'through': 5, 'compaction': 2, 'system': 'You are the saved system prompt.',
      'systemMessage': messages.first,
      'model': {'providerID': 'opencode', 'id': 'fixture'}, 'tools': [], 'settings': {'reasoning': 'high'},
      'limit': 1000, 'counts': {'user': 1, 'assistant': 2, 'compaction': 1},
      'created': 1, 'updated': 5, 'data': messages, 'cursor': {},
    } : {'data': messages, 'through': 5, 'cursor': {}};
  }
  @override Future<void> close() async { if (!events.isClosed) await events.close(); }
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async =>
    jsonObject(await request(method, params).asCancellable(cancellation));
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
