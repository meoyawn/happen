import 'dart:async';
import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/appearance.dart';
import 'package:desktop/command_menu.dart';
import 'package:desktop/database.dart';
import 'package:desktop/composer_editor.dart';
import 'package:desktop/new_session.dart';
import 'package:desktop/session.dart';
import 'package:desktop/settings_screen.dart';
import 'package:desktop/workspace_navigation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('project selection groups machines and worktrees by project identity', (tester) async {
    late DesktopSession local, remote;
    late Directory root;
    Future<void>? closing;
    Future<void> close() => closing ??= (() async {
      await remote.close(); await local.close(); await root.delete(recursive: true);
    })();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-project-identity-');
      local = DesktopSession(_Client(), await openDesktopDatabase('${root.path}/local'));
      remote = DesktopSession(_Client(), local.database,
        sidebarOwner: local, machineAlias: 'vps', machineName: 'VPS');
    });
    addTearDown(() => tester.runAsync(close));
    const repository = 'https://github.com/example/agent';
    final checkout = Project('local-agent', repository, '/local/agent')
      ..workspace = {'repository': repository, 'subdirectory': ''};
    final worktree = Project('worktree', repository, '/worktrees/agent')
      ..workspace = {'repository': repository, 'subdirectory': '', 'worktree': true};
    final peer = Project('local-agent', repository, '/remote/agent')
      ..workspace = {'repository': repository, 'subdirectory': ''};
    final unrelated = Project('other-agent', 'https://github.com/other/agent', '/other/agent');
    local.projects.addAll([checkout, worktree, unrelated]); local.project = checkout;
    remote.projects.add(peer); remote.project = peer;
    for (final source in [local, remote]) {
      source.projects.addAll([
        Project('app', repository, '${source.machineAlias == null ? '/local' : '/remote'}/agent/packages/app')
          ..workspace = {'repository': repository, 'subdirectory': 'packages/app'},
        Project('scratch', '/scratch', '/scratch'),
      ]);
    }
    final sources = [local, remote];
    Project? selected;
    Widget menu() => MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () => unawaited(showDialog<void>(context: context, builder: (_) => CommandMenu(
        session: local, sources: sources, actions: const [], pickProject: true,
        onOpen: (_, _) {}, onNewThread: (project) => selected = project, onAddProject: () {}))),
      child: const Text('Choose project'))));
    await tester.pumpWidget(menu());
    await tester.tap(find.text('Choose project'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(CommandMenu), matching: find.text('agent')), findsNWidgets(2),
      reason: 'One project spans local, remote, and worktree checkouts; another repository stays separate');
    final search = find.byKey(const ValueKey('command-menu-search'));
    for (final (query, name, count) in [('packages/app', 'app', 1), ('/scratch', 'scratch', 2)]) {
      await tester.enterText(search, query);
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(CommandMenu), matching: find.text(name)), findsNWidgets(count),
        reason: 'Project subfolders share identity; unrelated folders with equal paths stay separate');
    }
    await tester.enterText(search, '/remote/agent');
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(CommandMenu), matching: find.text('agent')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, same(checkout), reason: 'Searching a remote path still selects the project on the current machine');

    checkout.available = false;
    worktree.available = false;
    selected = null;
    await tester.pumpWidget(menu());
    await tester.tap(find.text('Choose project'));
    await tester.pumpAndSettle();
    await tester.enterText(search, '/local/agent');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, same(peer), reason: 'An unavailable checkout must not disable a project available on another machine');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: NewSessionScreen(
      session: local, sources: sources, composer: const SizedBox(height: 80), picking: false,
      onSelect: (project) => selected = project, onAddProject: () {},
      onRemoveProject: (_) {}, onReturnFocus: () {},
    ))));
    await tester.tap(find.byTooltip('Select project'));
    await tester.pumpAndSettle();
    final picker = find.byType(ListView);
    expect(find.descendant(of: picker, matching: find.text('agent')), findsNWidgets(2));
    await tester.enterText(find.byKey(const ValueKey('project-search')), '/worktrees/agent');
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: picker, matching: find.text('agent')));
    await tester.pumpAndSettle();
    expect(selected, same(peer));

    checkout.tasks.add(DesktopTask('local-thread', 'Local session'));
    worktree.tasks.add(DesktopTask('worktree-thread', 'Worktree session'));
    peer.tasks.add(DesktopTask('remote-thread', 'Remote session'));
    unrelated.tasks.add(DesktopTask('unrelated-thread', 'Unrelated session'));
    local.sessionDrafts.add(SessionDraft('local-draft', worktree.checkoutKey));
    local.drafts['local-draft'] = 'Local draft';
    remote.sessionDrafts.add(SessionDraft('remote-draft', peer.checkoutKey));
    remote.drafts['remote-draft'] = 'Remote draft';
    String? filter;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(builder: (context, setState) => Scaffold(
      body: SizedBox(width: 276, child: ThreadSidebar(session: local, sources: sources, home: true,
        windowControls: false, projectKey: filter, onProjectFilter: (value) => setState(() => filter = value),
        onHome: () {}, onSearch: () {}, onNew: () {}, onSettings: () {}, onDraft: (_) {},
        onAddProject: () {}, onRefresh: () {}, onSelect: (_, _) {}, onArchive: (_, _) {}))))));
    await tester.tap(find.byTooltip('Filter by project'));
    await tester.pumpAndSettle();
    final choices = find.widgetWithText(CheckedPopupMenuItem<String>, 'agent');
    expect(choices, findsNWidgets(2));
    await tester.tap(choices.first);
    await tester.pumpAndSettle();
    expect(sidebarThreadIds(local, projectKey: filter, sources: sources), unorderedEquals([
      'local-thread', 'worktree-thread', remote.sidebarId('remote-thread'),
      'local-draft', remote.sidebarId('remote-draft'),
    ]));
    expect(find.text('Remote session'), findsOneWidget);
    expect(find.text('Unrelated session'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(close);
    await tester.pump();
  });

  testWidgets('new thread waits for a project and cancellation preserves the current conversation', (tester) async {
    late DesktopSession session;
    late Directory root;
    Future<void>? closing;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-new-thread-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      addTearDown(() => tester.runAsync(() => closing ??= session.close()));
    });
    final active = DesktopTask('active', 'Current conversation')..loaded = true;
    final original = Project('original', 'original', '${root.path}/original', [active]);
    final selected = Project('selected', 'selected', '${root.path}/selected');
    final unavailable = Project('unavailable', 'unavailable', '${root.path}/selected-offline')..available = false;
    final removing = Project('removing', 'removing', '${root.path}/selected-removing')..removing = true;
    session.projects.addAll([original, unavailable, selected, removing]);
    session.project = original;
    session.task = active;
    session.drafts[active.id] = 'Keep this reply';
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('happen/desktop'), null));
    await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    final draftIds = session.sessionDrafts.map((draft) => draft.id).toList();
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final search = find.byKey(const ValueKey('command-menu-search'));
    await tester.tap(find.byTooltip('New thread (${mac ? '⌘N' : 'Ctrl+N'})'));
    await tester.pumpAndSettle();
    expect(find.byType(CommandMenu), findsOneWidget);
    expect(find.byType(NewSessionScreen), findsNothing);
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    expect(session.task, same(active));
    expect(session.project, same(original));
    expect(session.sessionDrafts.map((draft) => draft.id), draftIds);
    expect(find.byKey(const ValueKey('command-menu:project:removing')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('command-menu:project:unavailable')));
    await tester.pumpAndSettle();
    expect(find.byType(CommandMenu), findsOneWidget);
    expect(session.task, same(active));
    await tester.enterText(search, 'no matching project');
    await tester.pumpAndSettle();
    expect(find.text('No projects found.'), findsOneWidget);
    expect(find.descendant(of: find.byType(CommandMenu), matching: find.text('Add project')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(CommandMenu), findsNothing);
    expect(session.task, same(active));
    expect(session.project, same(original));
    expect(session.sessionDrafts.map((draft) => draft.id), draftIds);
    expect(session.drafts[active.id], 'Keep this reply');

    final modifier = mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
    expect(find.byType(CommandMenu), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(find.text('New thread in…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    await tester.enterText(search, selected.path);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(CommandMenu), findsNothing);
    expect(find.byType(NewSessionScreen), findsOneWidget);
    expect(session.project, same(selected));
    expect(session.task, isNull);
    expect(session.currentDraft.checkoutKey, selected.checkoutKey);
    expect(session.drafts[active.id], 'Keep this reply');
    expect(tester.widget<ComposerEditor>(find.byType(ComposerEditor)).focusNode.hasFocus, isTrue);
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => closing ??= session.close());
    await tester.pump();
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows}));

  testWidgets('command menu opens full-height archive previews without suggesting archived chats', (tester) async {
    late DesktopSession session;
    late Directory root;
    final client = _Client();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-command-menu-');
      addTearDown(() => root.delete(recursive: true));
      session = DesktopSession(client, await openDesktopDatabase(root.path));
      addTearDown(() => tester.runAsync(session.close));
    });
    final archived = [
      for (var i = 0; i < 20; i++)
        DesktopTask('archived-$i', 'Archived-only conversation $i')..archived = true,
    ];
    final project = Project('project', 'project', root.path, [
      DesktopTask('active', 'Active conversation'), ...archived,
    ]);
    session.projects.add(project);
    session.project = project;
    session.viewingConversation = false;
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('happen/desktop'), null));

    await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    final modifier = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    Future<void> toggleMenu() async {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
    }

    await toggleMenu();
    expect(find.byType(CommandMenu), findsOneWidget);
    expect(find.text('Archived sessions'), findsOneWidget);
    expect(find.text('Archived-only conversation 0'), findsNothing);
    final search = find.byKey(const ValueKey('command-menu-search'));
    await tester.enterText(search, 'Archived-only');
    await tester.pumpAndSettle();
    expect(find.text('No results'), findsOneWidget);
    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(CommandMenu), findsNothing);
    expect(find.text('Archived tasks (20)'), findsOneWidget);
    final lowerRow = find.byKey(const ValueKey('archived:archived-6'));
    expect(lowerRow.hitTestable(), findsOneWidget,
      reason: 'The archive uses the available page height instead of a small nested viewport');
    expect(tester.getBottomLeft(lowerRow).dy, greaterThan(500));

    final last = archived.last;
    final lastRow = find.byKey(ValueKey('archived:${last.id}'));
    await tester.scrollUntilVisible(lastRow, 400,
      scrollable: find.descendant(of: find.byKey(const PageStorageKey('archived-sessions')),
        matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    await tester.tap(lastRow);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('archived-preview')), findsOneWidget);
    expect(find.text('Read-only archived preview'), findsOneWidget);
    expect(session.task, isNull);
    expect(session.viewingConversation, isFalse);
    expect(tester.getSize(find.byKey(ValueKey('archived-transcript:${last.id}'))).height, greaterThan(600));
    await tester.tap(find.text('Back to archived tasks'));
    await tester.pumpAndSettle();
    expect(lastRow.hitTestable(), findsOneWidget);
    await tester.tap(lastRow);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final restored = Completer<void>();
      void changed() {
        if (!last.archived && !last.archiving && !restored.isCompleted) restored.complete();
      }
      session.addListener(changed);
      try {
        await tester.tap(find.text('Restore'));
        await restored.future.timeout(const Duration(seconds: 10));
      } finally {
        session.removeListener(changed);
      }
    });
    await tester.pumpAndSettle();
    expect(client.restored, [last.id]);
    expect(session.task, isNull);
    expect(session.viewingConversation, isFalse);
    expect(find.byType(DesktopSettingsScreen), findsOneWidget);
    expect(find.text('Archived tasks (19)'), findsOneWidget);
    expect(lastRow, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await toggleMenu();
    expect(find.descendant(of: find.byType(CommandMenu), matching: find.text(last.title)), findsOneWidget);
    await toggleMenu();
    expect(find.byType(CommandMenu), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows}));
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => true;
  @override Future<Json> mcpInventory({bool verbose = false, String? server, String? cwd, required CancellationToken cancellation}) async =>
    {'servers': <Object?>[]};
  final restored = <String>[];
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async {
    if (method == 'thread/read') return {
      'notificationThrough': 1, 'archived': !restored.contains(params['threadId']),
      'thread': {'id': params['threadId'], 'preview': 'Archived-only conversation ${(params['threadId'] as String).split('-').last}'},
      'recentTurns': {'data': <Object?>[], 'nextCursor': null},
      'history': {'data': [{'turnId': 'turn', 'order': 1, 'startedAtMs': 1,
        'item': {'id': 'message', 'type': 'userMessage',
          'content': [{'type': 'text', 'text': 'Read-only archived preview'}]},
      }], 'nextCursor': null},
    };
    throw StateError('Unexpected read: $method');
  }
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'thread/unarchive') {
      restored.add(params['threadId'] as String);
      return null;
    }
    throw StateError('Unexpected request: $method');
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
