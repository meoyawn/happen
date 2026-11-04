import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:desktop/workspace_navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  Widget sidebar(DesktopSession session, {void Function(Project, DesktopTask)? select,
      void Function(DesktopTask, bool)? archive}) => MaterialApp(home: Scaffold(body: SizedBox(width: 276,
    child: ThreadSidebar(session: session, home: true, windowControls: false,
      onHome: () {}, onSearch: () {}, onNew: () {}, onSettings: () {}, onDraft: (_) {},
      onSelect: select ?? (_, _) {}, onArchive: archive ?? (_, _) {}))));

  testWidgets('one project tree includes saved interrupted and older finished threads without starting work', (tester) async {
    final session = DesktopSession(_Client(), _Database());
    addTearDown(session.close);
    final interrupted = DesktopTask('interrupted', 'Saved work interrupted by a crash')..loaded = true;
    interrupted.turns['turn'] = {'id': 'turn', 'status': 'inProgress'};
    final completed = DesktopTask('completed', 'An older finished session');
    session.projects.add(Project('project', '/project', '/project', [interrupted, completed]));
    DesktopTask? opened;
    await tester.pumpWidget(sidebar(session, select: (_, task) => opened = task));
    expect(find.byKey(const ValueKey('thread:interrupted')), findsOneWidget);
    expect(find.byKey(const ValueKey('thread:completed')), findsOneWidget);
    expect(find.byTooltip('Interrupted'), findsOneWidget);
    expect(find.byTooltip('Working'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thread:interrupted')));
    expect(opened, same(interrupted)); expect(interrupted.running, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed threads can archive without selecting or loading their broken history', (tester) async {
    final session = DesktopSession(_Client(), _Database());
    addTearDown(session.close);
    final failed = DesktopTask('failed', 'Cannot load conversation')..loadError = 'History failed';
    session.projects.add(Project('project', '/project', '/project', [failed]));
    final actions = <(DesktopTask, bool)>[];
    var opened = false;
    await tester.pumpWidget(sidebar(session, select: (_, _) => opened = true,
      archive: (task, archived) => actions.add((task, archived))));
    final row = find.byKey(const ValueKey('thread:failed'));
    await tester.tap(row, buttons: kSecondaryMouseButton); await tester.pumpAndSettle();
    await tester.tap(find.text('Archive session')); await tester.pumpAndSettle();
    expect(actions, [(failed, true)]); expect(opened, false);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 700)); addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row)); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Archive session')); await tester.pumpAndSettle();
    expect(actions, [(failed, true), (failed, true)]); expect(opened, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('parent questions override working status until the native resolution arrives', (tester) async {
    final session = DesktopSession(_Client(), _Database());
    addTearDown(session.close);
    final task = DesktopTask('question', 'Waiting for your answer')..running = true;
    session.projects.add(Project('project', '/project', '/project', [task]));
    await tester.pumpWidget(ListenableBuilder(listenable: session, builder: (_, _) => sidebar(session)));
    void event(String method, Json params) => session.client.events.add({'method': method, 'params': {'threadId': task.id, ...params}});
    event('happen/question/asked', {'request': {'id': 'request', 'questions': <Object?>[]}});
    await tester.pump();
    expect(find.byTooltip('Input'), findsOneWidget); expect(find.byTooltip('Working'), findsNothing);
    event('item/started', {'turnId': 'turn', 'item': {'id': 'reply', 'type': 'agentMessage', 'text': ''}}); await tester.pump();
    expect(find.byTooltip('Input'), findsOneWidget);
    event('happen/question/replied', {'requestID': 'request'}); await tester.pump();
    expect(find.byTooltip('Input'), findsNothing); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pinning moves threads above projects and persists without opening their history', (tester) async {
    late DesktopSession session;
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('workspace-pinning-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      addTearDown(() => tester.runAsync(session.close));
    });
    final older = DesktopTask('older', 'Older session')..loadError = 'Unavailable'..lastActivity = 1;
    final newer = DesktopTask('newer', 'Newer session')..lastActivity = 2;
    session.projects.add(Project('project', '/project', '/project', [newer, older]));
    var opened = false;
    await tester.pumpWidget(ListenableBuilder(listenable: session, builder: (_, _) => sidebar(session, select: (_, _) => opened = true)));
    final row = find.byKey(const ValueKey('thread:older'));
    await tester.tap(row, buttons: kSecondaryMouseButton); await tester.pumpAndSettle();
    await tester.tap(find.text('Pin session'));
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(session.database.port, 'load', {}));
      expect(jsonDecode(saved['settings']['sidebar_pinned_tasks'] as String), [older.id]);
    });
    await tester.pumpAndSettle();
    expect(find.text('Pinned'), findsOneWidget);
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('thread:newer'))).dy));
    expect(opened, false); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
class _Database implements IsolateOwner {
  @override Future<void> close() async {}
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected database operation');
}
