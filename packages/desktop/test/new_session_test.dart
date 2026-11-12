import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/composer_attachments.dart';
import 'package:desktop/database.dart';
import 'package:desktop/new_session.dart';
import 'package:desktop/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  for (final completed in [false, true]) {
    test('catalog discovery during submission keeps one ${completed ? 'completed' : 'running'} thread', () async {
      final root = await Directory.systemTemp.createTemp('new-thread-discovery-');
      final database = await openDesktopDatabase(root.path);
      final client = _Client()
        ..startingTurn = Completer<void>()..releaseTurn = Completer<void>();
      final session = DesktopSession(client, database);
      addTearDown(() async {
        if (!client.releaseTurn!.isCompleted) client.releaseTurn!.complete();
        await session.close();
        await root.delete(recursive: true);
      });
      await session.load();
      await session.addProject(root.path);
      session.providers = [{'id': 'openai', 'status': 'signed_in', 'models': [
        {'id': 'fixture', 'reasoning_levels': <String>[]},
      ]}];
      session.chooseModel('fixture');
      final owner = session.project!, draft = session.currentDraft;
      final sending = session.send('Keep the new thread visible');
      await client.startingTurn!.future.timeout(const Duration(seconds: 5));
      client.events.add({'method': 'turn/started', 'params': {
        'threadId': 'created', 'turn': {'id': 'turn', 'status': 'inProgress'},
      }});
      client.events.add({'method': 'happen/inbox/enqueued', 'params': {
        'threadId': 'created', 'input': {'id': client.messageID, 'prompt': 'Keep the new thread visible'},
      }});
      client.events.add({'method': 'item/started', 'params': {
        'threadId': 'created', 'turnId': 'turn',
        'item': {'id': 'reply', 'type': 'agentMessage', 'text': ''},
      }});
      client.events.add({'method': 'item/agentMessage/delta', 'params': {
        'threadId': 'created', 'turnId': 'turn', 'itemId': 'reply', 'delta': 'Live ',
      }});
      await Future<void>.delayed(Duration.zero);
      client.threads = [{'id': 'created', 'cwd': owner.path, 'name': 'Discovered thread',
        'status': {'type': 'active'}, 'updatedAt': 1}];
      await session.refreshSessions();
      final discovered = owner.tasks.single;
      client.events.add({'method': 'happen/inbox/delivered', 'params': {
        'threadId': discovered.id, 'id': client.messageID,
      }});
      client.events.add({'method': 'item/agentMessage/delta', 'params': {
        'threadId': discovered.id, 'turnId': 'turn', 'itemId': 'reply', 'delta': 'reply',
      }});
      if (completed) {
        client.events.add({'method': 'item/completed', 'params': {
          'threadId': discovered.id, 'turnId': 'turn',
          'item': {'id': 'reply', 'type': 'agentMessage', 'text': 'Live reply'},
        }});
        client.events.add({'method': 'turn/completed', 'params': {
          'threadId': discovered.id, 'turn': {'id': 'turn', 'status': 'completed'},
        }});
      }
      await Future<void>.delayed(Duration.zero);
      client.releaseTurn!.complete();
      expect(await sending, isTrue, reason: session.error);
      expect(owner.tasks, hasLength(1));
      expect(session.task, same(discovered));
      expect(session.task!.title, 'Discovered thread');
      expect(session.task!.running, !completed);
      expect(session.task!.turns['turn']?['status'], completed ? 'completed' : 'inProgress');
      expect(session.task!.messages['reply']?['text'], 'Live reply');
      expect(session.task!.pending, isEmpty);
      expect(session.sessionDrafts, isNot(contains(draft)));
      expect(session.openTabIds, [discovered.id]);
      final saved = jsonObject(await callIsolate(database.port, 'load', {}));
      expect((saved['tasks'] as List).single['id'], discovered.id);
      expect((saved['tasks'] as List).single['title'], 'Discovered thread');
    });
  }

  test('restored empty duplicates are removed while active and invested drafts survive', () async {
    final root = await Directory.systemTemp.createTemp('restored-drafts-');
    final attachment = await File('${root.path}/keep.txt').writeAsString('Keep this attachment');
    final database = await openDesktopDatabase(root.path);
    final session = DesktopSession(_Client(), database);
    var closed = false;
    addTearDown(() async {
      if (!closed) await session.close();
      await root.delete(recursive: true);
    });
    await callIsolate(database.port, 'project.add', {
      'checkout_key': 'checkout', 'identity': 'project', 'path': root.path,
    });
    final savedDrafts = <Json>[
      {'id': 'old-empty', 'project': 'checkout'},
      {'id': 'active-empty', 'project': 'checkout', 'tracing': true},
      {'id': 'new-empty', 'project': 'checkout'},
      {'id': 'text', 'project': 'checkout', 'text': 'Keep this draft'},
      {'id': 'attachment', 'project': 'checkout', 'attachments': [
        {'type': 'file', 'name': 'keep.txt', 'path': attachment.path},
      ]},
      {'id': 'other-project', 'project': 'other-checkout'},
      {'id': 'old-unscoped', 'project': null},
      {'id': 'new-unscoped', 'project': null},
      {'id': 'new-unscoped', 'project': null},
    ];
    await callIsolate(database.port, 'settings.set', {
      'key': 'session_drafts',
      'value': jsonEncode({
        'active': 'active-empty',
        'tabs': [for (final draft in savedDrafts) draft['id']],
        'drafts': savedDrafts,
      }),
    });
    await session.load();
    const remaining = ['active-empty', 'text', 'attachment', 'other-project', 'new-unscoped'];
    expect(session.sessionDrafts.map((draft) => draft.id), remaining);
    expect(session.openTabIds, remaining);
    expect(session.currentDraft.id, 'active-empty');
    expect(session.currentDraft.tracing, isTrue);
    expect(session.drafts['text'], 'Keep this draft');
    expect(session.attachmentDrafts['attachment']!.single.path, attachment.path);
    expect(await attachment.readAsString(), 'Keep this attachment');
    for (var index = 0; index < 10; index++) { session.newSession(); }
    expect(session.currentDraft.id, 'active-empty');
    expect(session.sessionDrafts.map((draft) => draft.id), remaining);
    await session.close();
    closed = true;

    final reopened = await openDesktopDatabase(root.path);
    try {
      final saved = jsonObject(await callIsolate(reopened.port, 'load', {}));
      final restored = jsonObject(jsonDecode(saved['settings']['session_drafts'] as String));
      expect((restored['drafts'] as List).map((draft) => draft['id']), remaining);
      expect(restored['tabs'], remaining);
    } finally {
      await reopened.close();
    }
  });

  for (final projectCount in [1, 12]) {
    testWidgets('project dropdown opens, filters, and selects with $projectCount projects', (tester) async {
      final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('new-session-')))!;
      final session = DesktopSession(_Client(), (await tester.runAsync(() => openDesktopDatabase(root.path)))!);
      var closed = false;
      addTearDown(() => tester.runAsync(() async {
        if (!closed) await session.close();
        await root.delete(recursive: true);
      }));
      session.projects.addAll([
        for (var index = 0; index < projectCount; index++)
          Project('checkout-$index', 'project-$index', '/projects/project-$index'),
      ]);
      session.project = session.projects.first;
      Project? selected;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: NewSessionScreen(
        session: session, composer: const SizedBox(height: 100), picking: false,
        onSelect: (project) => selected = project, onAddProject: () {},
        onRemoveProject: (_) {}, onReturnFocus: () {},
      ))));
      if (projectCount == 1) {
        await tester.tap(find.byTooltip('Checkout options'));
        await tester.pumpAndSettle();
        final trace = find.widgetWithText(CheckedPopupMenuItem<String>, 'Trace this session');
        expect(tester.widget<CheckedPopupMenuItem<String>>(trace).checked, isFalse);
        await tester.tap(trace);
        await tester.pumpAndSettle();
        expect(session.currentDraft.tracing, isTrue);
        final tracedDraft = session.currentDraft;
        session.newSession();
        await tester.pump();
        expect(session.currentDraft, same(tracedDraft));
        expect(session.sessionDrafts, hasLength(1));
        expect(session.currentDraft.tracing, isTrue);
        session.drafts[tracedDraft.id] = 'Keep this draft';
        session.newSession();
        await tester.pump();
        expect(session.currentDraft.tracing, isFalse);
        final attachmentDraft = session.currentDraft;
        final attachment = ComposerAttachment(name: 'draft.txt', path: '/draft.txt', image: false);
        session.attachmentDrafts[attachmentDraft.id] = [attachment];
        session.newSession();
        expect(session.currentDraft, isNot(same(attachmentDraft)));
        expect(session.attachmentDrafts[attachmentDraft.id], [attachment]);
        expect(session.drafts[tracedDraft.id], 'Keep this draft');
        session.openDraft(tracedDraft);
        await tester.pump();
        expect(session.currentDraft.tracing, isTrue);
        session.submitting = true;
        session.notifyListeners();
        await tester.pump();
        await tester.tap(find.byTooltip('Checkout options'));
        await tester.pumpAndSettle();
        expect(tester.widget<CheckedPopupMenuItem<String>>(trace).enabled, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        session.submitting = false;
        session.notifyListeners();
        await tester.pump();
      }
      if (projectCount > 1) {
        final firstDraft = session.currentDraft;
        session.newSession(session.projects.last);
        expect(session.currentDraft, isNot(same(firstDraft)));
        session.newSession(session.projects.first);
        expect(session.currentDraft, same(firstDraft));
        expect(session.sessionDrafts, hasLength(2));
        await tester.pump();
      }

      final dropdown = find.byTooltip('Select project');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(dropdown));
      addTearDown(mouse.removePointer);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('project-search')), findsOneWidget);

      if (projectCount > 1) {
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byKey(const ValueKey('project-search')), 'not-a-project');
      await tester.pumpAndSettle();
      expect(find.text('No projects found.'), findsOneWidget);
      final target = session.projects.last;
      await tester.enterText(find.byKey(const ValueKey('project-search')), target.name);
      await tester.pumpAndSettle();
      final row = find.descendant(of: find.byType(ListView), matching: find.text(target.path));
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(selected, same(target));
      expect(find.byKey(const ValueKey('project-search')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('project-search')), findsOneWidget,
        reason: 'The dropdown remains usable after closing and reopening');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await session.close(); closed = true; });
      await tester.pump();
    });
  }
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => true;
  List<Json> threads = [];
  Completer<void>? startingTurn, releaseTurn;
  String? messageID;
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'turn/start') {
      messageID = params['clientUserMessageId'] as String;
      startingTurn!.complete();
      await releaseTurn!.future;
      return <String, Object?>{};
    }
    return switch (method) {
      'client.capabilities' => <String, Object?>{},
      'providers.list' => {'providers': <Object?>[]},
      'thread/list' => {'data': params['archived'] == true ? <Json>[] : threads, 'nextCursor': null},
      'thread/start' => {'thread': {'id': 'created'}, 'configuration': <String, Object?>{}},
      'workspace.inspect' => {'available': true, 'identity': 'path:${params['path']}',
        'path': params['path'], 'branch': null},
      _ => throw StateError('Unexpected client request: $method'),
    };
  }
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async =>
    jsonObject(await request(method, params));
  @override Future<Json> inspectWorkspace(String path, {required CancellationToken cancellation}) async =>
    jsonObject(await request('workspace.inspect', {'path': path}));
  @override Future<Json> gitRequest(String method, Json params, {required CancellationToken cancellation}) async =>
    method == 'git/status' ? {'isRepo': false, 'files': <Object?>[]}
      : throw StateError('Unexpected Git request: $method');
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
