import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/appearance.dart';
import 'package:desktop/database.dart';
import 'package:desktop/opencode_navigation.dart';
import 'package:desktop/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  final partialReply = ValueVariant<String>({'metadata', 'empty', 'partial'});
  testWidgets('interrupted saved sessions remain visible in Inbox without becoming active', (tester) async {
    final session = DesktopSession(_Client(), _Database())
      ..openCodeLayout = OpenCodeLayout.inbox
      ..inboxSince = DateTime.now().millisecondsSinceEpoch;
    addTearDown(session.close);
    final interrupted = DesktopTask('interrupted', 'Saved work interrupted by a crash')
      ..loaded = partialReply.currentValue != 'metadata';
    interrupted.projectionState['summary'] = {'time': {'created': 1, 'busy': 2}};
    if (partialReply.currentValue == 'partial') {
      interrupted.messages['assistant'] = {
        'id': 'assistant', 'type': 'assistant', 'time': {'created': 1}, 'metadata': {'seq': 3}, 'content': [],
      };
    }
    final completed = DesktopTask('completed', 'An older finished session')..loaded = true;
    completed.messages.addAll({...interrupted.messages, 'idle': {
      'id': 'idle', 'type': 'idle', 'time': {'created': 2}, 'metadata': {'seq': 4}, 'outcome': 'succeeded',
    }});
    session.viewedTasks[interrupted.id] = DateTime.now().millisecondsSinceEpoch;
    session.projects.add(Project('project', '/project', '/project', [interrupted, completed]));
    DesktopTask? opened;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 276,
      child: OpenCodeSidebar(session: session, home: true, windowControls: false,
        onHome: () {}, onSearch: () {}, onNew: () {}, onSettings: () {},
        onSelect: (_, task) => opened = task, onDraft: (_) => fail('Not a session'), onArchive: (_, _) {})))));
    expect(find.byKey(const ValueKey('inbox:interrupted')), findsOneWidget);
    expect(find.byKey(const ValueKey('inbox:completed')), findsNothing);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Interrupted'), findsOneWidget);
    expect(find.text('Working'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('inbox:interrupted')));
    expect(opened, same(interrupted));
    expect(interrupted.running, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: partialReply);

  testWidgets('failed inbox sessions offer archive by right click and hover without opening history', (tester) async {
    final session = DesktopSession(_Client(), _Database())..openCodeLayout = OpenCodeLayout.inbox;
    addTearDown(session.close);
    final failed = DesktopTask('failed', 'Cannot load conversation')..loadError = 'History failed';
    session.projects.add(Project('project', '/project', '/project', [failed]));
    final actions = <(DesktopTask, bool)>[];
    var opened = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 276,
      child: OpenCodeSidebar(session: session, home: true, windowControls: false,
        onHome: () {}, onSearch: () {}, onNew: () {}, onSettings: () {},
        onSelect: (_, _) => opened = true, onDraft: (_) => opened = true,
        onArchive: (task, archived) => actions.add((task, archived)))))));
    final row = find.byKey(const ValueKey('inbox:failed'));
    await tester.tap(row, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive session'));
    await tester.pumpAndSettle();
    expect(actions, [(failed, true)]);
    expect(opened, false);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 700));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Archive session'));
    await tester.pumpAndSettle();
    expect(actions, [(failed, true), (failed, true)]);
    expect(opened, false, reason: 'Archiving must not select or load the broken conversation');
    expect(tester.takeException(), isNull);
  });

  final pinView = ValueVariant<String>({'inbox', 'side', 'top', 'home'});
  testWidgets('sessions pin on hover and unpin by right click without opening history', (tester) async {
    late DesktopSession session;
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('desktop-pinning-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      addTearDown(() => tester.runAsync(session.close));
    });
    final view = pinView.currentValue!;
    session.openCodeLayout = OpenCodeLayout.values.where((layout) => layout.name == view).firstOrNull ?? OpenCodeLayout.top;
    final older = DesktopTask('older', 'Older session')..loadError = 'History unavailable'..lastActivity = 1;
    final newer = DesktopTask('newer', 'Newer session')..lastActivity = 2;
    newer.projectionState['summary'] = {'time': {'idle': 2}, 'outcome': 'succeeded'};
    session.projects.add(Project('project', '/project', '/project', [newer, older]));
    session.openTabIds.addAll([newer.id, older.id]);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var opened = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(
      listenable: session, builder: (context, _) => switch (view) {
        'home' => OpenCodeHome(session: session, focusNode: focus,
          onSelect: (_, _) => opened = true, onNew: (_) => opened = true,
          onAddProject: () => opened = true, onArchive: (_, _) => opened = true),
        'inbox' => SizedBox(width: 276, child: OpenCodeSidebar(session: session, home: true, windowControls: false,
          onHome: () {}, onSearch: () {}, onNew: () {}, onSettings: () {},
          onSelect: (_, _) => opened = true, onDraft: (_) => opened = true, onArchive: (_, _) => opened = true)),
        _ => SizedBox(height: view == 'top' ? 44 : 200, width: 276,
          child: OpenCodeTabStrip(session: session, vertical: view == 'side', home: true,
            onSelect: (_, _) => opened = true, onDraft: (_) => opened = true, onArchive: (_, _) => opened = true)),
      },
    ))));
    await tester.pumpAndSettle();
    Finder row(String id) => find.byKey(ValueKey('${view == 'home' ? 'home' : view == 'inbox' ? 'inbox' : 'opencode-tab'}:$id'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 700));
    addTearDown(mouse.removePointer);
    expect(find.byKey(const ValueKey('pin:older')), findsNothing);
    await mouse.moveTo(tester.getCenter(row(older.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: row(older.id), matching: find.byTooltip('Pin session')).hitTestable());
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(session.database.port, 'load', {}));
      expect(jsonDecode(saved['settings']['sidebar_pinned_tasks'] as String), [older.id]);
    });
    await mouse.moveTo(const Offset(1000, 700));
    await tester.pumpAndSettle();
    expect(row(older.id), findsOneWidget);
    expect(session.pinnedTaskIds, [older.id]);
    if (view == 'inbox') expect(find.text('Pinned'), findsOneWidget);
    if (view == 'top') {
      expect(tester.getTopLeft(row(older.id)).dx, lessThan(tester.getTopLeft(row(newer.id)).dx));
    } else {
      expect(tester.getTopLeft(row(older.id)).dy, lessThan(tester.getTopLeft(row(newer.id)).dy));
    }
    await tester.tap(row(older.id), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin session'));
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(session.database.port, 'load', {}));
      expect(jsonDecode(saved['settings']['sidebar_pinned_tasks'] as String), isEmpty);
    });
    await tester.pumpAndSettle();
    expect(session.pinnedTaskIds, isEmpty);
    expect(opened, false, reason: 'Pinning never selects, archives, or opens the broken conversation');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: pinView);
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
