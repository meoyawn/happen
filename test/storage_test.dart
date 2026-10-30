import 'dart:async';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('cancelling paged history work preserves the writer and never publishes a partial fork', () async {
    final root = await Directory.systemTemp.createTemp('history-cancel-');
    final owner = await startStore(root.path, newId());
    addTearDown(() async {
      await owner.close();
      await root.delete(recursive: true);
    });
    for (var page = 0; page < 10; page++) {
      await callIsolate(owner.port, 'append_batch', {
        'events': List.generate(
          1000,
          (i) => {
            'type': 'host_tool.completed',
            'data': {
              'id': '$page:$i',
              'name': 'probe',
              'output': 'ordinary historical text ' * 40,
            },
          },
        ),
      });
    }
    await callIsolate(owner.port, 'append', {
      'type': 'turn.completed',
      'data': {},
    });
    final searching = CancellationToken();
    final result = expectLater(
      callIsolate(owner.port, 'history.search_contents', {
        'query': 'not-present-anywhere',
        'limit': 1,
      }, cancellation: searching),
      throwsA(isA<CancelledException>()),
    );
    final timer = Timer(const Duration(milliseconds: 1), searching.cancel);
    await result;
    timer.cancel();
    expect(
      await callIsolate(owner.port, 'history', {'limit': 1}),
      hasLength(1),
    );

    final child = newId(), copying = CancellationToken();
    final fork = expectLater(
      callIsolate(owner.port, 'fork', {'id': child}, cancellation: copying),
      throwsA(isA<CancelledException>()),
    );
    final stage = Directory('${root.path}/staging');
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!await stage.exists() || await stage.list().isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('Fork never started');
      await Future<void>.delayed(Duration.zero);
    }
    copying.cancel();
    await fork;
    // This request queues behind the cancelled copy and its cleanup.
    await callIsolate(owner.port, 'append', {
      'type': 'turn.completed',
      'data': {'after_cancel': true},
    });
    expect(await Directory('${root.path}/tasks/$child').exists(), isFalse);
    expect(await stage.list().isEmpty, isTrue);
    expect(
      (await callIsolate(owner.port, 'history.search_contents', {
        'query': 'ordinary historical text',
        'limit': 1,
      }) as List).single['role'],
      'tool',
    );
  });
}
