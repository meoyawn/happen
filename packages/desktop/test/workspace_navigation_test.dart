import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/pinned_sidebar_preferences.dart';
import 'package:desktop/session.dart';
import 'package:desktop/workspace_navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  Widget sidebar(DesktopSession session, {void Function(Project, DesktopTask)? select,
      void Function(DesktopTask, bool)? archive, List<DesktopSession>? sources, bool home = true}) => MaterialApp(home: Scaffold(body: SizedBox(width: 276,
    child: ThreadSidebar(session: session, sources: sources, home: home, windowControls: false,
      onHome: () {}, onSearch: () {}, onNew: () {}, onSettings: () {}, onDraft: (_) {},
      onAddProject: () {}, onRefresh: () {}, onProjectFilter: (_) {},
      onSelect: select ?? (_, _) {}, onArchive: archive ?? (_, _) {}))));

  testWidgets('working threads lead the list while empty drafts and archives stay out', (tester) async {
    late DesktopSession session;
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('sidebar-drafts-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      await session.pinnedSidebar.ready;
      addTearDown(() => tester.runAsync(session.close));
    });
    final interrupted = DesktopTask('interrupted', 'Saved work interrupted by a crash')..loaded = true;
    interrupted.turns['turn'] = {'id': 'turn', 'status': 'inProgress'};
    final completed = DesktopTask('completed', 'An older finished session');
    final working = DesktopTask('working', 'Currently running')..running = true;
    final archived = DesktopTask('archived', 'Archived work')..archived = true;
    session.projects.add(Project('project', '/project', '/project', [interrupted, completed, working, archived]));
    session.sessionDrafts.addAll([SessionDraft('empty', 'project'), SessionDraft('saved', 'project')]);
    session.drafts['saved'] = 'An unsent idea';
    DesktopTask? opened;
    await tester.pumpWidget(sidebar(session, select: (_, task) => opened = task));
    expect(find.byKey(const ValueKey('thread:interrupted')), findsOneWidget);
    expect(find.byKey(const ValueKey('thread:completed')), findsOneWidget);
    expect(find.byTooltip('Interrupted'), findsOneWidget);
    expect(find.byTooltip('Working'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('thread:working'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('thread:interrupted'))).dy));
    expect(find.byKey(const ValueKey('draft:empty')), findsNothing);
    expect(find.text('An unsent idea'), findsOneWidget);
    expect(find.byKey(const ValueKey('thread:archived')), findsNothing);
    expect(find.text('Settled'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thread:interrupted')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(opened, same(interrupted)); expect(interrupted.running, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('working thread order follows user sends through activity and queued delivery', (tester) async {
    late DesktopSession session;
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('workspace-working-order-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      await session.pinnedSidebar.ready;
      addTearDown(() => tester.runAsync(session.close));
    });
    final now = DateTime.now().millisecondsSinceEpoch - 60000;
    final older = DesktopTask('older', 'Older user message')..running = true..loaded = true..lastActivity = now + 3000;
    older.messages['first'] = {'id': 'first', 'type': 'userMessage', 'startedAtMs': now + 1000};
    final newer = DesktopTask('newer', 'Newer user message')..running = true..loaded = true..lastActivity = now + 2000;
    newer.messages['second'] = {'id': 'second', 'type': 'userMessage', 'startedAtMs': now + 2000};
    session.projects.add(Project('project', '/project', '/project', [older, newer]));
    await tester.pumpWidget(ListenableBuilder(listenable: session, builder: (_, _) => sidebar(session)));
    expect(sidebarThreadIds(session), [newer.id, older.id]);

    void event(DesktopTask task, String method, Json params, int time) =>
      session.client.events.add({'method': method, 'params': {
        'threadId': task.id, ...params, 'happen': {'createdAt': now + time},
      }});
    event(older, 'turn/started', {'turn': {'id': 'background', 'status': 'inProgress'}}, 5000);
    await tester.pump();
    expect(sidebarThreadIds(session), [newer.id, older.id]);

    event(older, 'happen/inbox/enqueued', {'input': {
      'id': 'queued', 'prompt': 'Follow up', 'created_at': DateTime.fromMillisecondsSinceEpoch(now + 6000).toIso8601String(),
    }}, 6000);
    await tester.pump();
    expect(sidebarThreadIds(session), [older.id, newer.id]);
    event(newer, 'happen/inbox/enqueued', {'input': {
      'id': 'latest', 'prompt': 'More recent follow up', 'created_at': DateTime.fromMillisecondsSinceEpoch(now + 7000).toIso8601String(),
    }}, 7000);
    await tester.pump();
    expect(sidebarThreadIds(session), [newer.id, older.id]);

    event(older, 'item/completed', {'item': {
      'id': 'delivered', 'type': 'userMessage', 'startedAtMs': now + 9000,
    }}, 9000);
    event(older, 'happen/inbox/delivered', {'id': 'queued'}, 9000);
    await tester.pump();
    expect(sidebarThreadIds(session), [newer.id, older.id]);
    expect(tester.getTopLeft(find.byKey(const ValueKey('thread:newer'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('thread:older'))).dy));

    session.releaseHistory(newer);
    event(newer, 'happen/inbox/delivered', {'id': 'latest'}, 10000);
    event(older, 'turn/started', {'turn': {'id': 'continuation', 'status': 'inProgress'}}, 11000);
    await tester.pump();
    expect(sidebarThreadIds(session), [newer.id, older.id]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('switching the active server retains both sidebars and scopes equal thread IDs', (tester) async {
    late DesktopSession local, remote;
    late Directory root;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('shared-sidebar-');
      local = DesktopSession(_Client(), await openDesktopDatabase('${root.path}/local'));
      remote = DesktopSession(_Client(), await openDesktopDatabase('${root.path}/remote'),
        sidebarOwner: local, machineAlias: 'other-server', machineName: 'Other server');
      await local.pinnedSidebar.ready;
    });
    addTearDown(() => tester.runAsync(() async {
      await local.close(); await remote.close(); await root.delete(recursive: true);
    }));
    final first = DesktopTask('same-id', 'Local thread')..loaded = true;
    final second = DesktopTask('same-id', 'Remote thread')..loaded = true;
    final left = Project('same-project', 'repo', '/checkout', [first]);
    final right = Project('same-project', 'repo', '/checkout', [second]);
    local.projects.add(left); local.project = left; local.task = first;
    remote.projects.add(right); remote.project = right; remote.task = second;
    final sources = [local, remote];
    final opened = <DesktopTask>[];
    Widget view(DesktopSession active) => sidebar(active, sources: sources, home: false,
      select: (_, task) => opened.add(task));
    await tester.pumpWidget(view(local));
    expect(find.text('Local thread'), findsOneWidget);
    expect(find.text('Remote thread'), findsOneWidget);
    expect(find.byKey(const ValueKey('thread:same-id')), findsOneWidget);
    final remoteRow = find.byKey(ValueKey('thread:${remote.sidebarId(second.id)}'));
    expect(remoteRow, findsOneWidget);
    expect(sidebarThreadIds(local, sources: sources).toSet(), {first.id, remote.sidebarId(second.id)});
    await tester.pumpWidget(view(remote));
    expect(find.text('Local thread'), findsOneWidget);
    expect(find.text('Remote thread'), findsOneWidget);
    await tester.tap(remoteRow);
    await tester.pump(const Duration(milliseconds: 350));
    expect(opened, [second]);
    await tester.runAsync(() => remote.pinTask(second, true));
    await tester.pump();
    expect(local.pinnedTaskIds, [remote.sidebarId(second.id)]);
    expect(remote.pinnedTaskIds, [second.id]);
    expect(sidebarThreadIds(remote, sources: sources).first, remote.sidebarId(second.id));
    remote.connected = false; remote.notifyListeners();
    await tester.pumpWidget(view(local));
    expect(find.text('Remote thread'), findsOneWidget, reason: 'A disconnected server retains its cached threads');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed threads can archive without selecting or loading their broken history', (tester) async {
    final session = DesktopSession(_Client(), _Database());
    await tester.runAsync(() => session.pinnedSidebar.ready);
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
    await tester.tap(find.byKey(const ValueKey('archive:failed')));
    await tester.pump(const Duration(milliseconds: 99));
    expect(actions, [(failed, true), (failed, true)],
      reason: 'Archiving must not wait for the row double-click timeout');
    expect(opened, false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('parent questions override working status until the native resolution arrives', (tester) async {
    final session = DesktopSession(_Client(), _Database());
    await tester.runAsync(() => session.pinnedSidebar.ready);
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
    event('happen/question/replied', {'requestID': 'request'});
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Input'), findsNothing); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pinning moves a thread before other idle threads without opening its history', (tester) async {
    late DesktopSession session;
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('workspace-pinning-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      await session.pinnedSidebar.ready;
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
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('thread:newer'))).dy));
    expect(opened, false); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing a pinned project disclosure preserves scroll until the selected thread changes', (tester) async {
    tester.view.physicalSize = const Size(900, 450);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late DesktopSession session;
    late Directory root;
    late Project project;
    late String projectId;
    late DesktopTask next;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('sidebar-reveal-selection-');
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      await session.pinnedSidebar.ready;
      final pinned = [for (var index = 0; index < 3; index++) DesktopTask('pin-$index', 'Pinned $index')];
      final others = [for (var index = 0; index < 20; index++)
        DesktopTask('other-$index', 'Other $index')..lastActivity = 20 - index];
      next = others[18];
      project = Project('project', '/project', '/project', [...pinned, ...others]);
      projectId = projectIdentity(session, project);
      session.projects.add(project);
      session.project = project;
      session.task = others.last;
      for (final task in pinned) { await session.pinTask(task, true); }
      await session.pinnedSidebar.chooseCollapsed(projectId, true);
    });
    addTearDown(() => tester.runAsync(() async {
      await session.close(); await root.delete(recursive: true);
    }));
    await tester.pumpWidget(sidebar(session, home: false));
    await tester.pumpAndSettle();
    final scroller = tester.widget<CustomScrollView>(find.byKey(const PageStorageKey('thread-sidebar'))).controller!;
    expect(scroller.position.maxScrollExtent, greaterThan(0));
    scroller.jumpTo(0);
    await tester.pumpAndSettle();

    final folder = find.byKey(ValueKey('pinned-project:$projectId'));
    await tester.runAsync(() => tester.tap(folder));
    await tester.pumpAndSettle();
    expect(scroller.offset, closeTo(0, 1), reason: 'Disclosing the folder must not seek the selected thread below the viewport');
    await tester.runAsync(() => tester.tap(folder));
    await tester.pumpAndSettle();
    expect(scroller.offset, closeTo(0, 1), reason: 'Closing the folder must also preserve manual scroll');

    session.task = next;
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(scroller.offset, greaterThan(0), reason: 'Changing threads must still reveal the newly selected card');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('project folders keep pin order and disclosure through dragging, layout changes, and relaunch', (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late DesktopSession session;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('pinned-project-folders-');
      final database = await openDesktopDatabase(root.path);
      for (final (checkout, identity, path, ids) in [
        ('alpha', 'https://github.com/example/alpha.git', '/alpha', ['a1', 'a2']),
        ('worktree', 'https://github.com/example/alpha.git', '/alpha-worktree', ['a3']),
        ('beta', '/beta', '/beta', ['b1']),
        ('other', '/other/alpha', '/other/alpha', ['c1']),
      ]) {
        await callIsolate(database.port, 'project.add', {'checkout_key': checkout, 'identity': identity, 'path': path});
        for (final id in ids) {
          await callIsolate(database.port, 'task.add', {'id': id, 'checkout_key': checkout, 'title': 'Thread $id'});
        }
      }
      session = DesktopSession(_Client(), database);
      await session.restore();
      for (final id in ['a1', 'b1', 'a2', 'c1', 'a3']) {
        await session.pinTask(session.projects.expand((project) => project.tasks).singleWhere((task) => task.id == id), true);
      }
    });
    addTearDown(() => tester.runAsync(() async {
      await session.close(); await root.delete(recursive: true);
    }));
    final alphaId = projectIdentity(session, session.projects.first);
    final folder = find.byKey(ValueKey('pinned-project:$alphaId'));

    Future<void> settled() async {
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.runAsync(() => callIsolate(session.database.port, 'load', {}));
        await tester.pumpAndSettle();
        if (!session.savingTaskPins && session.pinnedSidebar.enabled) return;
      }
      fail('Pinned sidebar did not acknowledge persistence');
    }

    Future<void> drag(Finder from, Finder to) async {
      final start = tester.getCenter(from);
      final grab = (tester.getSize(from).height / 2).clamp(0.0, tester.getSize(to).height / 2);
      final end = Offset(start.dx, tester.getTopLeft(to).dy + grab + 4);
      final pointer = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      for (var step = 1; step <= 12; step++) {
        await pointer.moveTo(Offset.lerp(start, end, step / 12)!);
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pump(const Duration(milliseconds: 300));
      await pointer.up();
      await settled();
    }

    await tester.pumpWidget(sidebar(session));
    await settled();
    expect(find.byKey(ValueKey('pinned-group:$alphaId')), findsOneWidget,
      reason: 'Worktrees share a project folder; unrelated folders with the same name stay separate');
    expect(sidebarThreadIds(session), ['a1', 'a2', 'a3', 'b1', 'c1']);
    expect(find.byIcon(Icons.circle_outlined), findsNothing);
    final active = session.projects.expand((project) => project.tasks).singleWhere((task) => task.id == 'a3');
    active.running = true;
    session.notifyListeners();
    await tester.pump();
    expect(find.byTooltip('Working'), findsNWidgets(2));
    active.running = false;
    session.notifyListeners();
    await tester.pumpAndSettle();
    await drag(find.byKey(const ValueKey('thread:a3')), find.byKey(const ValueKey('thread:a1')));
    expect(session.pinnedTaskIds, ['a3', 'b1', 'a1', 'c1', 'a2']);
    expect(sidebarThreadIds(session), ['a3', 'a1', 'a2', 'b1', 'c1']);

    await tester.runAsync(() => tester.tap(folder, kind: PointerDeviceKind.mouse));
    await settled();
    expect(find.byKey(const ValueKey('thread:a1')), findsNothing);
    expect(sidebarThreadIds(session), ['b1', 'c1']);
    await tester.runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.arrowRight));
    await settled();
    expect(find.byKey(const ValueKey('thread:a1')), findsOneWidget);
    await tester.runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft));
    await settled();
    expect(sidebarThreadIds(session), ['b1', 'c1']);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.runAsync(() => tester.tap(folder, kind: PointerDeviceKind.mouse));
    await settled();
    expect(find.byKey(const ValueKey('thread:a1')), findsOneWidget);
    await tester.runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft));
    await settled();
    expect(sidebarThreadIds(session), ['b1', 'c1']);
    await drag(find.byKey(const ValueKey('thread:c1')), folder);
    expect(session.pinnedTaskIds, ['c1', 'a3', 'a1', 'a2', 'b1']);

    await tester.runAsync(() => session.pinnedSidebar.chooseLayout(PinnedThreadLayout.flat));
    await tester.pumpAndSettle();
    expect(folder, findsNothing);
    expect(sidebarThreadIds(session), ['c1', 'a3', 'a1', 'a2', 'b1']);
    await tester.runAsync(() => session.pinnedSidebar.chooseLayout(PinnedThreadLayout.byProject));
    await tester.pumpAndSettle();
    expect(sidebarThreadIds(session), ['c1', 'b1']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await session.close();
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      await session.restore();
    });
    await tester.pumpWidget(sidebar(session));
    await tester.pumpAndSettle();
    expect(sidebarThreadIds(session), ['c1', 'b1']);
    expect(session.pinnedTaskIds, ['c1', 'a3', 'a1', 'a2', 'b1']);
    await tester.runAsync(() => tester.tap(folder));
    await settled();
    expect(sidebarThreadIds(session), ['c1', 'a3', 'a1', 'a2', 'b1']);
    await drag(folder, find.byKey(const ValueKey('thread:c1')));
    expect(session.pinnedTaskIds, ['a3', 'a1', 'a2', 'c1', 'b1']);
    await tester.runAsync(() async {
      for (var index = 0; index < 12; index++) {
        final task = DesktopTask('extra-$index', 'Extra pinned thread $index');
        session.projects.add(Project('extra-$index', '/extra-$index', '/extra-$index', [task]));
        await session.pinTask(task, true);
      }
    });
    tester.view.physicalSize = const Size(900, 450);
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byKey(const PageStorageKey('thread-sidebar')));
    final start = tester.getCenter(folder), end = Offset(viewport.center.dx, viewport.bottom - 4);
    final pointer = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    for (var step = 1; step <= 12; step++) {
      await pointer.moveTo(Offset.lerp(start, end, step / 12)!);
      await tester.pump(const Duration(milliseconds: 30));
    }
    for (var frame = 0; frame < 40; frame++) { await tester.pump(const Duration(milliseconds: 30)); }
    await pointer.up();
    await settled();
    expect(session.pinnedTaskIds.indexOf('a3'), greaterThan(session.pinnedTaskIds.indexOf('extra-0')),
      reason: 'Holding a folder at the viewport edge scrolls and drops at the newly visible project');
    final moved = session.pinnedTaskIds.indexOf('a3');
    expect(session.pinnedTaskIds.sublist(moved, moved + 3), ['a3', 'a1', 'a2']);
    expect(tester.takeException(), isNull);
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
