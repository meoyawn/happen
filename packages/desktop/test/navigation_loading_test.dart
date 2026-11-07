import 'dart:async';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('switching away cancels history and a stale read cannot finish a newer selection', () async {
    final directory = await Directory.systemTemp.createTemp('navigation-history-');
    final client = _Client();
    final session = DesktopSession(client, await openDesktopDatabase(directory.path));
    addTearDown(() async {
      for (final read in client.reads) {
        if (!read.reply.isCompleted) read.reply.complete(_snapshot('Cleanup'));
      }
      await session.close();
      await directory.delete(recursive: true);
    });
    final first = DesktopTask('first', 'First');
    final cached = DesktopTask('cached', 'Cached')..loaded = true;
    final project = Project('project', directory.path, directory.path, [first, cached]);
    session.projects.add(project);
    session.project = project;

    final cancelled = expectLater(session.select(project, first), throwsA(isA<CancelledException>()));
    expect(first.loading, true);
    final older = client.reads.single;
    await session.select(project, cached);
    expect(older.cancellation.isCancelled, true);
    expect(first.loading, false);
    expect(session.task, cached);

    final selected = session.select(project, first);
    final newer = client.reads.last;
    older.reply.complete(_snapshot('Stale title'));
    await cancelled;
    expect(first.loading, true);
    expect(first.loaded, false);
    expect(first.title, 'First');
    expect(newer.cancellation.isCancelled, false);

    newer.reply.complete(_snapshot('Fresh title'));
    await selected;
    expect(session.task, first);
    expect(first.loaded, true);
    expect(first.loading, false);
    expect(first.title, 'Fresh title');
  });
}

Json _snapshot(String title) => {
  'thread': {'id': 'first', 'name': title},
  'configuration': {'provider': 'openai', 'model': 'fixture'},
  'history': {'data': <Object?>[], 'turns': <Object?>[], 'nextCursor': null},
  'recentTurns': {'data': <Object?>[]},
};

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  final reads = <({CancellationToken cancellation, Completer<Json> reply})>[];
  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) {
    final reply = Completer<Json>();
    reads.add((cancellation: cancellation, reply: reply));
    return reply.future;
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
