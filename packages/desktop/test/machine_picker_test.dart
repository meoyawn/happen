import 'dart:async';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/machines.dart';
import 'package:desktop/machine_icons.dart';
import 'package:desktop/new_session.dart';
import 'package:desktop/session.dart';
import 'package:desktop/thread_machine_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('default environment icon also resolves through its tunnel alias after relaunch', () async {
    final root = await Directory.systemTemp.createTemp('default-machine-icon-');
    final database = await openDesktopDatabase(root.path);
    final session = DesktopSession(_Client(), database, machineAlias: 'tunnel-default');
    var machines = MachinesController(session, root.path);
    final cancellation = CancellationToken();
    try {
      await machines.refresh();
      await machines.chooseIcon(null, MachineIcon.ubuntu, cancellation: cancellation);
      expect(machines.iconFor(null), MachineIcon.ubuntu);
      expect(machines.iconFor(session.machineAlias), MachineIcon.ubuntu);
      await machines.close();
      machines = MachinesController(session, root.path);
      await machines.refresh();
      expect(machines.iconFor(session.machineAlias), MachineIcon.ubuntu);
      expect(machines.iconFor('another-server'), MachineIcon.server);
    } finally {
      cancellation.cancel();
      await machines.close();
      await session.close();
      await database.close();
      await root.delete(recursive: true);
    }
  });

  testWidgets('new-session project choices remember different machines after relaunch', (tester) async {
    late Directory root;
    late DesktopSession local, remote;
    late MachinesController machines;
    late Project localA, localB, remoteA, remoteB;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('project-machines-');
      local = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      remote = DesktopSession(_Client(), local.database, sidebarOwner: local, machineAlias: 'vps');
      localA = Project('local-a', 'https://example.com/a.git', '/local/A');
      localB = Project('local-b', 'https://example.com/b.git', '/local/B');
      remoteA = Project('remote-a', 'https://example.com/a.git', '/remote/A');
      remoteB = Project('remote-b', 'https://example.com/b.git', '/remote/B');
      for (final project in [localA, remoteA]) { project.displayName = 'Alpha project'; }
      for (final project in [localB, remoteB]) { project.displayName = 'Beta project'; }
      local.projects.addAll([localA, localB]);
      remote.projects.addAll([remoteA, remoteB]);
      machines = MachinesController(local, root.path);
      await machines.refresh();
      machines.rememberProjectMachine(remote, remoteA);
      machines.rememberProjectMachine(local, localB);
      await callIsolate(local.database.port, 'load', {});
      await machines.close();
      machines = MachinesController(local, root.path);
      await machines.refresh();
    });
    addTearDown(() => tester.runAsync(() async {
      await machines.close();
      await remote.close();
      await local.close();
      await root.delete(recursive: true);
    }));

    Project? selected;
    Widget screen() => MaterialApp(home: Scaffold(body: NewSessionScreen(
      session: local, sources: [local, remote], lastMachineForProject: machines.lastMachineForProject,
      composer: const SizedBox.shrink(), picking: false,
      onSelect: (project) { selected = project; },
      onAddProject: () {}, onRemoveProject: (_) {}, onReturnFocus: () {},
    )));
    await tester.pumpWidget(screen());
    await tester.tap(find.byTooltip('Select project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha project'));
    await tester.pumpAndSettle();
    expect(selected, same(remoteA));
    await tester.tap(find.byTooltip('Select project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta project'));
    await tester.pumpAndSettle();
    expect(selected, same(localB), reason: 'Project B must not inherit project A’s machine');

    remote.connected = false;
    await tester.pumpWidget(screen());
    await tester.tap(find.byTooltip('Select project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha project'));
    expect(selected, same(localA), reason: 'A disconnected saved machine must not block a new session');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('new-session dropdowns show cached checkouts without dispatching requests', (tester) async {
    final client = _Client();
    late Directory root;
    late DesktopSession session;
    late MachinesController machines;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('machine-picker-');
      session = DesktopSession(client, await openDesktopDatabase(root.path));
      final project = Project('checkout', 'example/repo', '/repo')
        ..branch = 'main' ..workspace = _checkout('/repo', 'main', false);
      session.projects.add(project);
      session.project = project;
      session.currentDraft.checkoutKey = project.checkoutKey;
      machines = MachinesController(session, root.path);
      await machines.refresh();
    });
    addTearDown(() => tester.runAsync(() async {
      await machines.close();
      await session.close();
      await root.delete(recursive: true);
    }));
    final before = (client.inspections, client.discoveries);
    for (var opening = 0; opening < 2; opening++) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child:
        ThreadMachinePicker(key: ValueKey(opening), machines: machines, session: session)))));
      expect((client.inspections, client.discoveries), before,
        reason: 'Mounting a new-session screen must only read the application catalog');
      await tester.tap(find.text('Current checkout'));
      await tester.pumpAndSettle();
      expect(find.text('Worktree · feature'), findsOneWidget);
      expect((client.inspections, client.discoveries), before,
        reason: 'Opening the checkout dropdown must not fetch locations');
      if (opening == 0) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.ancestor(of: find.text('Current checkout · main'), matching: find.byType(MenuItemButton)),
          _containsKeyboardFocus());
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.ancestor(of: find.text('Worktree · feature'), matching: find.byType(MenuItemButton)),
          _containsKeyboardFocus());
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Worktree · feature'), findsNothing);
      }
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('local'));
      await tester.pumpAndSettle();
      expect(find.text('Run on'), findsOneWidget);
      expect((client.inspections, client.discoveries), before,
        reason: 'Opening the machine dropdown must not fetch or connect');
      if (opening == 0) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('Run on'), findsNothing);
        expect(find.text('Worktree · feature'), findsOneWidget,
          reason: 'Down and Enter choose the machine and open its workspace choices');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Matcher _containsKeyboardFocus() => predicate<Finder>((finder) => FocusManager.instance.primaryFocus?.context
  ?.findAncestorWidgetOfExactType<MenuItemButton>() == finder.evaluate().single.widget,
  'contains the keyboard focus');

Json _checkout(String path, String branch, bool worktree) => {
  'available': true, 'path': path, 'repository': 'example/repo',
  'repositoryRoot': path, 'subdirectory': '', 'branch': branch,
  'worktree': worktree, 'bare': false,
};

class _Client implements AgentClient {
  int inspections = 0, discoveries = 0;
  @override final sharedFilesystem = false;
  @override final events = StreamController<Json>.broadcast();
  @override Future<Json> inspectWorkspace(String path, {required CancellationToken cancellation}) async {
    inspections++;
    throw StateError('Screen requested workspace inspection');
  }
  @override Future<Json> discoverWorkspaces({required List<String> paths, String? repository,
    String subdirectory = '', List<String> subdirectories = const [], required CancellationToken cancellation}) async {
    discoveries++;
    return {'checkouts': [_checkout('/repo', 'main', false), _checkout('/worktree', 'feature', true)], 'truncated': false};
  }
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async =>
    method == 'thread/list' ? {'data': <Object?>[], 'nextCursor': null} : throw StateError('Unexpected read: $method');
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client call: ${invocation.memberName}');
}
