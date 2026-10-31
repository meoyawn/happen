import 'dart:async';
import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  late _Client client;
  late DesktopSession session;
  Directory? directory;
  setUp(() {
    client = _Client();
    session = DesktopSession(client, _Database());
    session.providers = [
      {'id': 'gpt', 'name': 'ChatGPT', 'auth': 'chatgpt', 'status': 'signed_in', 'default_model': 'gpt-6.1-sol', 'models': [
        {'id': 'gpt-6.1-sol', 'default_reasoning': 'low', 'reasoning_levels': ['low'], 'reasoning_updates': true},
      ]},
      {'id': 'opencode', 'name': 'OpenCode', 'auth': 'opencode', 'status': 'signed_out', 'models': []},
    ];
    final task = DesktopTask('task', 'Example')
      ..loaded = true
      ..provider = 'gpt'
      ..model = 'gpt-6.1-sol'
      ..reasoning = 'low';
    session.projects.add(Project('checkout', '/project', '/project', [task]));
    session.project = session.projects.single;
    session.task = task;
  });
  tearDown(() async {
    await session.close();
    await directory?.delete(recursive: true);
    directory = null;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
  }

  testWidgets('expanded tool details survive switching away from the task and back', (tester) async {
    session.task!.events.addAll({
      1: {'seq': 1, 'type': 'tool.started', 'data': {'call_id': 'cell', 'namespace': 'functions', 'name': 'exec', 'input': 'text(await tools.exec_command({cmd: "pwd"}));'}},
      2: {'seq': 2, 'type': 'host_tool.started', 'data': {'id': 'shell', 'parent_call_id': 'cell', 'name': 'exec_command', 'arguments': {'cmd': 'pwd'}}},
      3: {'seq': 3, 'type': 'host_tool.completed', 'data': {'id': 'shell', 'output': {'output': '/project'}}},
    });
    await open(tester);
    await tester.tap(find.text('functions.exec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code & output'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('text(await tools.exec_command({cmd: "pwd"}));'), findsOneWidget);
    await tester.tap(find.text('exec_command'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('/project'), findsOneWidget);
    final task = session.task!;
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    await tester.runAsync(() => session.select(session.project!, task));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Enter sends and Shift Enter inserts a newline', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'First line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'First line\n');
    expect(client.sent, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['prompt'], 'First line\n');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Settings lists archived tasks, opens their history, and restores them', (tester) async {
    final archived = DesktopTask('archived', 'Old conversation')..archived = true..loaded = true;
    session.project!.tasks.add(archived);
    late Directory root;
    late IsolateOwner database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-settings-');
      directory = root;
      database = await openDesktopDatabase(root.path);
      await callIsolate(database.port, 'project.add', {'checkout_key': 'checkout', 'identity': '/project', 'path': '/project'});
      await callIsolate(database.port, 'task.add', {'id': archived.id, 'checkout_key': 'checkout', 'title': archived.title});
      await callIsolate(database.port, 'task.archive', {'task_id': archived.id, 'archived': true});
      final previous = session;
      await previous.close();
      client = _Client();
      session = DesktopSession(client, database)
        ..providers = previous.providers
        ..projects.addAll(previous.projects)
        ..project = previous.project
        ..task = previous.task;
    });
    await open(tester);
    expect(find.text('Old conversation'), findsNothing);
    expect(find.text('Archived'), findsNothing);
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Sign in to OpenCode'), findsOneWidget);
    expect(find.text('Steer'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    final row = find.byKey(const ValueKey('archived:archived'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(find.text('Archived tasks (1)'), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Old conversation')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('project')), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(session.task, same(archived));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Restore task to continue'), findsOneWidget);
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.descendant(of: row, matching: find.text('Restore')));
      await Future<void>.delayed(Duration.zero);
      await callIsolate(database.port, 'load', {});
    });
    await tester.pumpAndSettle();
    expect(client.restored, [archived.id]);
    expect(find.text('Archived tasks (0)'), findsOneWidget);
    expect(find.text('No archived tasks.'), findsOneWidget);
    expect(archived.archived, isFalse);
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}));
      expect((saved['tasks'] as List).single['archived'], 0);
    });
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.ancestor(of: find.text('Old conversation'), matching: find.byType(ListTile)),
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive task'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await callIsolate(database.port, 'load', {});
    });
    for (var attempt = 0; archived.archiving && attempt < 100; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Task archived'), findsOneWidget, reason: 'archived=${archived.archived}, archiving=${archived.archiving}, error=${session.error}');
    expect(find.text('Old conversation'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Task archived'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  final sent = <Json>[];
  final restored = <String>[];
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'task.unarchive' || method == 'task.archive') {
      if (method == 'task.unarchive') restored.add(params['task_id'] as String);
      return {'task_id': params['task_id'], 'archived': method == 'task.archive'};
    }
    if (method != 'task.send') throw StateError('Unexpected request: $method');
    sent.add(params);
    return {'task_id': params['task_id']};
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}

class _Database implements IsolateOwner {
  @override Future<void> close() async {}
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected database operation');
}
