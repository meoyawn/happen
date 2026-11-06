import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:ai/ai.dart';
import 'package:desktop/conversation.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';

void main() {
  testWidgets('forking a response opens its saved prefix and preserves the source draft and history', (tester) async {
    late Directory root;
    late AgentServer server;
    late DesktopSession session;
    late Project project;
    late DesktopTask source;
    Future<void>? pending;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-fork-');
      final config = {'cwd': root.path, 'provider': 'openai', 'model': 'gpt-6.1-sol',
        'provider_settings': {'reasoning': 'high', 'transport': 'http'}};
      final store = TaskStore(root.path, 'parent');
      try {
        store.append('task.created', config, metadata: {'config': config, 'name': 'Original conversation'});
        for (final id in ['one', 'two']) {
          store.append('turn.started', {'turnId': id});
          store.append('input.committed', {'item': ConversationItem.user('Question $id').toJson()});
          store.append('model.completed', {'assistantMessageID': 'answer-$id',
            'output': [ConversationItem.text('assistant', 'Answer $id').toJson()]});
          store.append('turn.completed', {});
        }
      } finally { store.close(); }
      server = await AgentServer.start(directory: root.path, port: 0, configPath: '${root.path}/config.yaml', skillsHome: root.path);
      final database = await openDesktopDatabase(root.path);
      source = DesktopTask('parent', 'Original conversation');
      project = Project('checkout', root.path, root.path, [source]);
      await callIsolate(database.port, 'project.add', {'checkout_key': project.checkoutKey, 'identity': project.id, 'path': project.path});
      final client = await HttpOverrides.runWithHttpOverrides(() => AgentClient.connect(server.uri), _LocalHttp());
      session = DesktopSession(client, database)
        ..projects.add(project)..project = project..task = source;
      session.drafts[source.id] = 'Keep my unsent message';
      await session.loadHistory(source);
    });
    addTearDown(() async {
      await session.close(); await server.close(); await root.delete(recursive: true);
    });
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(
      listenable: session,
      builder: (context, _) => ConversationDeck(task: session.task, tasks: project.tasks.toSet(),
        directory: root.path, empty: const SizedBox.shrink(), onRetry: (_) {},
        onFork: (target, turnId) {
          pending = session.forkFromResponse(target, turnId);
          return pending!;
        }),
    ))));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Answer one')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Fork from this response').first);
      await pending;
    });
    await tester.pumpAndSettle();
    final child = session.task!;
    expect(child.id, isNot(source.id)); expect(child.loaded, true); expect(child.running, false);
    expect(child.title, 'Original conversation fork');
    expect(child.model, 'gpt-6.1-sol'); expect(child.reasoning, 'high');
    expect(session.openTabIds, contains(child.id));
    expect(project.tasks, containsAll([source, child]));
    expect(find.text('Answer one'), findsOneWidget); expect(find.text('Answer two'), findsNothing);
    expect(session.drafts[source.id], 'Keep my unsent message');
    expect(conversation(source).where((entry) => entry.role == 'Happen').map((entry) => entry.text), ['Answer one', 'Answer two']);
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(session.database.port, 'load', {}));
      expect((saved['tasks'] as List).singleWhere((task) => task['id'] == child.id)['title'], 'Original conversation fork');
      expect((await session.client.request('thread/read', {'threadId': child.id, 'includeTurns': true}) as Json)['thread']['forkedFromId'], source.id);
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fork action belongs to terminal responses and remains available while a later turn runs', (tester) async {
    final task = DesktopTask('parent', 'Conversation')..loaded = true..running = true;
    task.turns.addAll({
      'done': {'id': 'done', 'status': 'completed'},
      'active': {'id': 'active', 'status': 'inProgress'},
    });
    task.messages['user-done'] = {'id': 'user-done', 'type': 'userMessage', 'turnId': 'done', 'order': 0,
      'content': [{'type': 'text', 'text': 'First question'}]};
    for (final (id, turn, text, phase, live) in [
      ('earlier', 'done', 'Earlier answer', 'final_answer', false),
      ('commentary', 'active', 'Working commentary', 'commentary', false),
      ('partial', 'active', 'Streaming answer', 'final_answer', true),
      ('finished-item', 'active', 'Item finished before turn', 'final_answer', false),
    ]) {
      if (id == 'commentary') {
        task.messages['user-active'] = {'id': 'user-active', 'type': 'userMessage', 'turnId': 'active',
          'order': task.messages.length, 'content': [{'type': 'text', 'text': 'Next question'}]};
      }
      task.messages[id] = {'id': id, 'turnId': turn, 'type': 'agentMessage', 'text': text, 'phase': phase,
        'live': live, 'order': task.messages.length};
    }
    var calls = 0;
    final release = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConversationDeck(
      task: task, tasks: {task}, directory: '', empty: const SizedBox.shrink(), onRetry: (_) {},
      onFork: (target, turnId) async { expect(target, task); expect(turnId, 'done'); calls++; await release.future; },
    ))));
    await tester.pump();
    expect(find.byTooltip('Fork from this response'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Earlier answer')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byTooltip('Fork from this response'));
    await tester.pump();
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.fork_right_rounded)).onPressed, isNull);
    expect(calls, 1);
    release.complete();
    await tester.pump();
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.fork_right_rounded)).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _LocalHttp extends HttpOverrides {}
