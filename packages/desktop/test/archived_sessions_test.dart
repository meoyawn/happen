import 'dart:async';
import 'dart:io';

import 'package:desktop/archived_sessions.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('archived tasks sort by archive time across projects and search like active tasks', (tester) async {
    late Directory root;
    late DesktopSession session;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-archived-list-');
      session = DesktopSession(_Client(), await openDesktopDatabase('${root.path}/desktop'));
    });
    addTearDown(() async {
      await tester.runAsync(session.close);
      await root.delete(recursive: true);
    });
    final older = DesktopTask('older', 'Fix editor')
      ..archived = true
      ..archivedAt = DateTime.utc(2026, 1, 1);
    final newest = DesktopTask('newest', 'Fix terminal')
      ..archived = true
      ..archivedAt = DateTime.utc(2026, 1, 3);
    final middle = DesktopTask('middle', 'Inspect output')
      ..archived = true
      ..archivedAt = DateTime.utc(2026, 1, 2);
    session.projects.addAll([
      Project('alpha', 'alpha', '${root.path}/alpha', [older, newest]),
      Project('beta', 'beta', '${root.path}/beta', [middle]),
    ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ArchivedSessions(
      session: session, run: (effect) => effect()))));
    final newestRow = find.byKey(const ValueKey('archived:newest'));
    final middleRow = find.byKey(const ValueKey('archived:middle'));
    final olderRow = find.byKey(const ValueKey('archived:older'));
    expect(tester.getTopLeft(newestRow).dy, lessThan(tester.getTopLeft(middleRow).dy));
    expect(tester.getTopLeft(middleRow).dy, lessThan(tester.getTopLeft(olderRow).dy));

    final search = find.byKey(const ValueKey('archived-search'));
    await tester.enterText(search, 'beta');
    await tester.pump();
    expect(middleRow, findsOneWidget);
    expect(newestRow, findsNothing);
    await tester.enterText(search, 'Fix terminal');
    await tester.pump();
    expect(newestRow, findsOneWidget);
    expect(middleRow, findsNothing);
    await tester.enterText(search, 'missing');
    await tester.pump();
    expect(find.text('No matching archived tasks.'), findsOneWidget);
    expect(find.text('Archived tasks (3)'), findsOneWidget);
  });
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => true;
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
