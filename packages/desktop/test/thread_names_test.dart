import 'dart:async';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:desktop/workspace_navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('thread titles refresh, edit with focus and selection, and save only on Enter', (tester) async {
    late Directory root;
    late IsolateOwner database;
    late DesktopSession session;
    final client = _Client();
    final active = DesktopTask('active', 'Current conversation')..loaded = true;
    final background = DesktopTask('background', 'Original prompt');
    late Project project;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('sidebar-thread-names-');
      database = await openDesktopDatabase(root.path);
      project = Project('checkout', root.path, root.path, [active, background]);
      await callIsolate(database.port, 'project.add', {
        'checkout_key': project.checkoutKey, 'identity': project.id, 'path': project.path,
      });
      for (final task in project.tasks) {
        await callIsolate(database.port, 'task.add', {
          'id': task.id, 'checkout_key': project.checkoutKey, 'title': task.title, 'last_activity': 100,
        });
      }
      session = DesktopSession(client, database)..projects.add(project)..project = project..task = active;
    });
    addTearDown(() async {
      await session.close();
      await root.delete(recursive: true);
    });
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(
      listenable: session,
      builder: (context, _) => ThreadSidebar(session: session, home: false, windowControls: false,
        onHome: () {}, onSearch: () {}, onNew: () {}, onSettings: () {}, onSelect: (_, _) {},
        onArchive: (_, _) {}, onDraft: (_) {}, onAddProject: () {}, onRefresh: () {}, onProjectFilter: (_) {}),
    ))));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('thread:background'));
    expect(find.descendant(of: row, matching: find.text('Original prompt')), findsOneWidget);

    const savedName = 'A saved context name that remains complete even when it exceeds the former seventy-two character cache limit';
    client.threads = [
      {'id': active.id, 'cwd': root.path, 'name': active.title, 'preview': 'Active prompt', 'updatedAt': 1},
      {'id': background.id, 'cwd': root.path, 'name': savedName, 'preview': 'Original prompt', 'updatedAt': 1},
    ];
    await tester.runAsync(() => session.refreshSessions());
    await tester.pumpAndSettle();
    expect(find.descendant(of: row, matching: find.text(savedName)), findsOneWidget);
    expect(session.task, same(active));

    client.events.add({'method': 'thread/name/updated', 'params': {
      'threadId': background.id, 'threadName': 'Updated context name',
    }});
    await tester.pumpAndSettle();
    expect(find.descendant(of: row, matching: find.text('Updated context name')), findsOneWidget);
    expect(session.task, same(active));
    await tester.runAsync(() async {
      final cache = jsonObject(await callIsolate(database.port, 'load', {}));
      expect((cache['tasks'] as List).singleWhere((task) => task['id'] == background.id)['title'], 'Updated context name');
    });

    client.threads.last['name'] = '   ';
    await tester.runAsync(() => session.refreshSessions());
    await tester.pumpAndSettle();
    expect(find.descendant(of: row, matching: find.text('Original prompt')), findsOneWidget);
    expect(session.error, isNull);

    final input = find.byKey(const ValueKey('thread-title:background'));
    void expectReady(String title) {
      final field = tester.widget<TextField>(input);
      expect(field.focusNode!.hasPrimaryFocus, isTrue);
      expect(field.controller!.text, title);
      expect(field.controller!.selection, TextSelection(baseOffset: 0, extentOffset: title.length));
    }

    await tester.tap(row, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename thread'));
    await tester.pumpAndSettle();
    expectReady('Original prompt');
    await tester.enterText(input, 'Canceled with Escape');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(background.title, 'Original prompt');
    expect(client.renames, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    expectReady('Original prompt');
    await tester.enterText(input, 'Canceled on blur');
    await tester.tap(find.text('Happen'));
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(background.title, 'Original prompt');
    expect(client.renames, isEmpty);

    await tester.tap(find.text('Original prompt'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Original prompt'));
    await tester.pumpAndSettle();
    expectReady('Original prompt');
    await tester.enterText(input, '  A title chosen by the user  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(background.title, 'A title chosen by the user');
    expect(client.renames, [{'threadId': background.id, 'name': 'A title chosen by the user'}]);
    expect(session.task, same(active));
    await tester.runAsync(() async {
      final cache = jsonObject(await callIsolate(database.port, 'load', {}));
      expect((cache['tasks'] as List).singleWhere((task) => task['id'] == background.id)['title'], 'A title chosen by the user');
    });
    expect(session.error, isNull);

    client.renamePending = Completer<void>();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    expectReady('A title chosen by the user');
    await tester.enterText(input, 'Keep this name for retry');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    expect(input, findsNothing, reason: 'A pending save cannot start another edit');
    expect(client.renames, hasLength(2));
    expect(background.title, 'A title chosen by the user');

    client.renamePending!.completeError(StateError('Offline'));
    await tester.pumpAndSettle();
    client.renamePending = null;
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    expectReady('Keep this name for retry');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(background.title, 'Keep this name for retry');
    expect(client.renames, hasLength(3));
    await tester.runAsync(() async {
      final cache = jsonObject(await callIsolate(database.port, 'load', {}));
      expect((cache['tasks'] as List).singleWhere((task) => task['id'] == background.id)['title'], 'Keep this name for retry');
    });

    final cancelled = CancellationToken()..cancel();
    await expectLater(session.renameTask(background, 'Never sent', cancellation: cancelled),
      throwsA(isA<CancelledException>()));
    expect(client.renames, hasLength(3));

    client.renamePending = Completer<void>();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    await tester.enterText(input, 'Late acknowledgement');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(client.renames, hasLength(4));
    await tester.pumpWidget(const SizedBox.shrink());
    client.renamePending!.complete();
    await tester.pump();
    expect(background.title, 'Keep this name for retry', reason: 'An abandoned editor ignores a late acknowledgement');
    expect(tester.takeException(), isNull);
  });
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => true;
  List<Json> threads = [];
  final renames = <Json>[];
  Completer<void>? renamePending;
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method != 'thread/name/set') throw StateError('Unexpected request: $method');
    renames.add(params);
    await renamePending?.future;
    return <String, dynamic>{};
  }
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async {
    if (method != 'thread/list') throw StateError('Unexpected session read: $method');
    return {'data': params['archived'] == true ? <Json>[] : threads, 'nextCursor': null};
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
