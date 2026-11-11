import 'dart:async';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/machines.dart';
import 'package:desktop/session.dart';
import 'package:desktop/thread_machine_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
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
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('local'));
      await tester.pumpAndSettle();
      expect(find.text('Run on'), findsOneWidget);
      expect((client.inspections, client.discoveries), before,
        reason: 'Opening the machine dropdown must not fetch or connect');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

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
