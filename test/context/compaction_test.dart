import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('compaction restores instructions and effort while durable recall survives restart and transfer', () async {
    final root = await Directory.systemTemp.createTemp('context-contract-');
    final work = await Directory('${root.path}/repo/sub')
        .create(recursive: true);
    await Directory('${root.path}/repo/.git').create();
    await File('${root.path}/repo/AGENTS.md')
        .writeAsString('Repository instruction: use maple.');
    await File('${work.path}/AGENTS.override.md')
        .writeAsString('Subdirectory instruction: retain the newline.');
    await File('${root.path}/auth.json').writeAsString(
      jsonEncode({
        'type': 'chatgpt',
        'access_token': 'fixture',
        'refresh_token': 'fixture',
        'account_id': 'fixture',
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      }),
    );
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Json>[];
    final waiting = <HttpResponse>[];
    var compactMode = 'success', sequence = 0, overflows = 0;
    Completer<void>? compactStarted;
    provider.listen((request) async {
      final payload = await utf8.decoder.bind(request).join();
      if (payload.isEmpty) {
        await request.response.close();
        return;
      }
      final body = jsonObject(jsonDecode(payload));
      requests.add(body);
      final input = (body['input'] as List).map(jsonObject).toList();
      final compact = input.last['type'] == 'compaction_trigger';
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      if (compact) {
        request.response.write('data: {"type":"response.output_text.delta","delta":"Internal compaction text"}\n\n');
        request.response.write('data: {"type":"response.reasoning_summary_text.delta","delta":"Internal compaction reasoning"}\n\n');
      } else {
        request.response.write('data: {"type":"response.output_text.delta","delta":"Visible reply"}\n\n');
      }
      if (compact && compactMode == 'wait') {
        waiting.add(request.response);
        request.response.write('data: {"type":"response.created"}\n\n');
        await request.response.flush();
        compactStarted!.complete();
        return;
      }
      if (compact && compactMode == 'fail' || !compact && overflows-- > 0) {
        request.response.write(
          'data: ${jsonEncode({
            'type': 'response.failed',
            'response': {
              'error': {'code': compact ? 'server_error' : 'context_length_exceeded', 'message': 'Fixture failure'},
              'status': 'failed',
            },
          })}\n\n',
        );
        await request.response.close();
        return;
      }
      final lastUser = input.lastIndexWhere((v) => v['role'] == 'user');
      final prompt = input[lastUser]['content'];
      final outputs = input
          .skip(lastUser + 1)
          .where((v) => v['type'] == 'custom_tool_call_output')
          .toList();
      final output = compact
          ? <Json>[
              {'type': 'compaction', 'encrypted_content': 'opaque-checkpoint'},
            ]
          : outputs.isNotEmpty
          ? <Json>[
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': outputs.last['output']},
                ],
              },
            ]
          : prompt == 'seed' || prompt == 'recall'
          ? <Json>[
              {
                'type': 'custom_tool_call',
                'namespace': 'functions',
                'name': 'exec',
                'call_id': 'call_${++sequence}',
                'input': prompt == 'seed'
                    ? 'text("receipt-867");'
                    : '''
            const hits = await tools.history__search_contents({query:"receipt-867",role:"tool",tool_name:"exec",recent_first:false,limit:1});
            const item = await tools.history__read_item({item_id:hits[0].item_id,window_id:hits[0].window_id,limit_chars:8000});
            text({item_id:item.item_id,window_id:item.window_id,content:item.content});
          ''',
              },
            ]
          : <Json>[
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': 'Ready'},
                ],
              },
            ];
      request.response.write(
        'data: ${jsonEncode({
          'type': 'response.completed',
          'response': {
            'status': 'completed',
            'output': output,
            'usage': {'input_tokens': 100, 'output_tokens': 10},
          },
        })}\n\n',
      );
      await request.response.close();
    });
    final endpoint = 'http://127.0.0.1:${provider.port}/responses';
    var server = await AgentServer.startEmbedded(
      directory: root.path,
      configPath: '${root.path}/config.yaml',
      endpoint: endpoint,
    );
    var client = await AgentClient.connect(server.uri);
    final live = <Json>[];
    var subscription = client.events.stream.listen(live.add);
    addTearDown(() async {
      await subscription.cancel();
      await client.close();
      await server.close();
      for (final response in waiting) {
        unawaited(response.close().catchError((Object _) {}));
      }
      await provider.close(force: true);
      await root.delete(recursive: true);
    });
    Future<Json> turn(String method, Json params) async {
      final done = client.events.stream.firstWhere(
        (v) => [
          'turn.completed',
          'turn.failed',
          'turn.cancelled',
        ].contains(v['type']),
      );
      await client.request(method, params);
      return done.timeout(const Duration(seconds: 10));
    }

    final first = await turn('task.start', {
      'cwd': work.path,
      'prompt': 'seed',
      'reasoning': 'low',
    });
    expect(first['type'], 'turn.completed', reason: first.toString());
    final id = first['task_id'];
    await turn('task.send', {
      'task_id': id,
      'prompt': 'next',
      'reasoning': 'high',
    });
    expect(live.any((event) => event['type'] == 'text.delta' && event['delta'] == 'Visible reply'), isTrue);
    compactMode = 'fail';
    live.clear();
    expect(
      (await turn('task.compact', {'task_id': id}))['type'],
      'turn.failed',
    );
    expect(live.where((event) => event['type'] == 'compaction.started').single['data']['reason'], 'manual');
    expect(live.any((event) => event['type'] == 'context.compacted'), isFalse);
    expect(live.any((event) => event['type'] == 'text.delta'), isFalse);
    expect(live.any((event) => event['type'] == 'reasoning.delta'), isFalse);
    expect(live.where((event) => event['type'] == 'model.retrying'), isNotEmpty);
    await turn('task.send', {'task_id': id, 'prompt': 'next'});
    expect(jsonEncode(requests.last['input']), contains('receipt-867'));
    compactMode = 'wait';
    compactStarted = Completer<void>();
    final cancelled = turn('task.compact', {'task_id': id});
    await compactStarted.future.timeout(const Duration(seconds: 5));
    // A second client discovers the in-flight compaction through durable history.
    final observer = await AgentClient.connect(server.uri);
    try {
      expect(jsonObject(await observer.request('task.subscribe', {'task_id': id}))['running'], isTrue);
      final history = await observer.request('history.page', {'task_id': id, 'limit': 500}) as List;
      expect(history.last['type'], 'compaction.started');
      final stopped = observer.events.stream.firstWhere((event) => event['type'] == 'turn.cancelled');
      await client.request('task.cancel', {'task_id': id});
      expect((await stopped.timeout(const Duration(seconds: 5)))['task_id'], id);
    } finally {
      await observer.close();
    }
    expect((await cancelled)['type'], 'turn.cancelled');
    expect(
      (await client.request('history.page', {
        'task_id': id,
        'limit': 500,
      }) as List).any((v) => v['type'] == 'context.compacted'),
      isFalse,
    );
    compactMode = 'success';
    await File('${root.path}/repo/AGENTS.md')
        .writeAsString('Repository instruction: use cedar.');
    live.clear();
    final compacted = await turn('task.compact', {'task_id': id});
    expect(compacted['type'], 'turn.completed', reason: compacted.toString());
    final checkpoint = (await client.request('history.page', {
      'task_id': id, 'limit': 500,
    }) as List).singleWhere((event) => event['type'] == 'context.compacted');
    final lifecycle = live.where((event) => {'compaction.started', 'context.compacted', 'turn.completed'}.contains(event['type'])).toList();
    expect(lifecycle.map((event) => event['type']), ['compaction.started', 'context.compacted', 'turn.completed']);
    expect(lifecycle[1]['id'], checkpoint['id']);
    expect(lifecycle[1]['created_at'], checkpoint['created_at']);
    expect(live.any((event) => event['type'] == 'text.delta'), isFalse);
    expect(live.any((event) => event['type'] == 'reasoning.delta'), isFalse);
    final restored = (checkpoint['data']['input'] as List).where((item) =>
      item['native']?['harness']?['context'] == 'agents_md',
    ).toList();
    expect(restored, hasLength(1));
    expect(jsonEncode(restored.single), contains('use cedar'));
    expect(jsonEncode(restored.single), isNot(contains('use maple')));
    await subscription.cancel();
    await client.close();
    await server.close();
    server = await AgentServer.startEmbedded(
      directory: root.path,
      configPath: '${root.path}/config.yaml',
      endpoint: endpoint,
    );
    client = await AgentClient.connect(server.uri);
    subscription = client.events.stream.listen(live.add);
    final requestIndex = requests.length;
    final recalled = await turn('task.send', {
      'task_id': id,
      'prompt': 'recall',
    });
    expect(recalled['type'], 'turn.completed', reason: recalled.toString());
    final continuation = requests[requestIndex];
    expect(jsonEncode(continuation['input']), isNot(contains('receipt-867')));
    expect(jsonEncode(continuation['input']), contains('opaque-checkpoint'));
    expect(jsonEncode(continuation['input']), contains('use cedar'));
    final instructionItems = (continuation['input'] as List).where((item) =>
      item['role'] == 'user' && item['content'] is String &&
      (item['content'] as String).startsWith('# AGENTS.md instructions'),
    ).toList();
    expect(instructionItems, hasLength(1));
    expect(instructionItems.single['content'], contains('use cedar'));
    expect(instructionItems.single['content'], isNot(contains('use maple')));
    expect(instructionItems.single['content'], isNot(contains('replace all previously provided AGENTS.md instructions')));
    expect(jsonEncode(continuation['input']), contains('retain the newline'));
    expect(continuation['reasoning']['effort'], 'low');
    expect(
      (continuation['input'] as List)
          .where((v) => v['type'] == 'configuration_update')
          .single['reasoning']['effort'],
      'high',
    );
    Json recalledItem(Json event) => jsonObject(
      jsonDecode(
        jsonDecode(event['data']['text'] as String)['output'][0] as String,
      ),
    );
    final record = recalledItem(recalled);
    expect(record['content'], contains('receipt-867'));
    await turn('task.compact', {'task_id': id});
    final latestCheckpoint = (await client.request('history.page', {
      'task_id': id, 'limit': 500,
    }) as List).lastWhere((event) => event['type'] == 'context.compacted');
    final latestInstructions = (latestCheckpoint['data']['input'] as List).where((item) =>
      item['native']?['harness']?['context'] == 'agents_md',
    ).toList();
    expect(latestInstructions, hasLength(1));
    expect(jsonEncode(latestInstructions.single), contains('use cedar'));
    expect(jsonEncode(latestInstructions.single), isNot(contains('use maple')));
    expect(jsonEncode(latestInstructions.single), isNot(contains('replace all previously')));
    final fork = jsonObject(
      await client.request('task.fork', {
        'task_id': id,
        'through': compacted['seq'],
      }),
    );
    final bundle = '${root.path}/saved.jsonl';
    await client.request('history.export', {
      'task_id': fork['task_id'],
      'path': bundle,
    });
    final imported = jsonObject(
      await client.request('history.import', {'path': bundle}),
    );
    for (final task in [fork['task_id'], imported['task_id']]) {
      final result = await turn('task.send', {
        'task_id': task,
        'prompt': 'recall',
      });
      expect(result['type'], 'turn.completed', reason: result.toString());
      expect(recalledItem(result), record);
    }
    overflows = 1;
    final recovered = await turn('task.send', {
      'task_id': id,
      'prompt': 'next',
    });
    expect(recovered['type'], 'turn.completed', reason: recovered.toString());
    expect(live.where((event) => event['type'] == 'compaction.started').last['data']['reason'], 'overflow');
    final before = requests
        .where((v) => v['input'].last['type'] == 'compaction_trigger')
        .length;
    overflows = 2;
    expect(
      (await turn('task.send', {'task_id': id, 'prompt': 'next'}))['type'],
      'turn.failed',
    );
    expect(
      requests
          .where((v) => v['input'].last['type'] == 'compaction_trigger')
          .length,
      before + 1,
    );
  });
}
