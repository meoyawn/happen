import 'dart:async';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/machines.dart';
import 'package:desktop/remote_settings.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('server settings commit SSH options to desktop SQLite and survive relaunch', (tester) async {
    late Directory root;
    late DesktopSession session;
    late MachinesController machines;
    var closed = false;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-remotes-');
      session = DesktopSession(_Client(), await openDesktopDatabase(root.path));
      machines = MachinesController(session, root.path);
      await machines.refresh();
    });
    addTearDown(() => tester.runAsync(() async {
      if (!closed) { await machines.close(); await session.close(); }
      await root.delete(recursive: true);
    }));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Padding(padding: const EdgeInsets.all(24),
      child: RemoteSettings(machines: machines)))));
    await tester.tap(find.text('Connect server'));
    await tester.pumpAndSettle();
    Finder field(String label) => find.widgetWithText(TextField, label);
    await tester.enterText(field('Name'), 'Test server');
    await tester.enterText(field('Hostname or SSH alias'), '127.0.0.1');
    await tester.enterText(field('User (optional)'), 'fixture');
    await tester.enterText(field('Port (optional)'), '1');
    await tester.enterText(field('SSH key path (optional)'), '~/.ssh/fixture-key');
    await tester.enterText(field('Workspace directories (optional, one per line)'), '/tmp/workspace');
    await tester.runAsync(() async {
      await tester.tap(find.text('Save & connect'));
      final saved = Completer<void>();
      void changed() { if (machines.writeState is RemoteWriteSaved && machines.hosts.isNotEmpty && !saved.isCompleted) saved.complete(); }
      machines.addListener(changed); changed();
      try { await saved.future.timeout(const Duration(seconds: 10)); }
      finally { machines.removeListener(changed); }
    });
    await tester.pumpAndSettle();
    expect(find.text('Test server'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await machines.close(); await session.close(); closed = true;
      final reopened = await openDesktopDatabase(root.path);
      try {
        final rows = (await callIsolate(reopened.port, 'remotes.list', {}) as List).map(jsonObject).toList();
        expect(rows, hasLength(1));
        expect(rows.single, containsPair('name', 'Test server'));
        expect(rows.single['host'], '127.0.0.1'); expect(rows.single['user'], 'fixture');
        expect(rows.single['port'], 1); expect(rows.single['identityFile'], '~/.ssh/fixture-key');
        expect(rows.single['projects'], ['/tmp/workspace']);
        await callIsolate(reopened.port, 'remotes.remove', {'alias': rows.single['alias']});
        expect(await callIsolate(reopened.port, 'remotes.list', {}), isEmpty);
      } finally { await reopened.close(); }
    });
  });
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async =>
    method == 'thread/list' ? {'data': <Object?>[], 'nextCursor': null} : throw StateError('Unexpected read: $method');
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client call');
}
