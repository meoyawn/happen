import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import '../support/thread_names.dart';
import '../support/openai_output.dart';
import '../support/thread.dart';

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
    var compactMode = 'success', sequence = 0, overflows = 0, compactFailures = 0;
    Completer<void>? compactStarted;
    provider.listen((request) async {
      final payload = await utf8.decoder.bind(request).join();
      if (payload.isEmpty) {
        await request.response.close();
        return;
      }
      final body = jsonObject(jsonDecode(payload));
      if (await respondToThreadName(request, body)) return;
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
              'error': {'code': compact ? compactFailures++ == 0 ? 'server_error' : 'invalid_prompt'
                : 'context_length_exceeded', 'message': 'Fixture failure'},
              'status': 'failed',
            },
          })}\n\n',
        );
        await request.response.close();
        return;
      }
      final lastUser = input.lastIndexWhere((v) => v['role'] == 'user');
      final prompt = openAIMessageText(input[lastUser]);
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
                  {'type': 'output_text', 'text': jsonEncode(outputs.last['output'])},
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
    final id = await createThread(client, {'cwd': work.path});
    Future<Json> turn({String? thread, String prompt = '', bool compact = false, Json settings = const {}}) =>
      runTurn(client, thread ?? id, prompt: prompt, compact: compact, settings: settings);
    Future<String> activeTurn() async => (jsonObject(await client.request('thread/read',
      {'threadId': id, 'includeTurns': true}))['thread']['turns'] as List).last['id'] as String;
    final first = await turn(prompt: 'seed', settings: {'effort': 'low'});
    expect(first['status'], 'completed', reason: first.toString());
    await turn(prompt: 'next', settings: {'effort': 'high'});
    expect(live.any((event) => event['method'] == 'item/agentMessage/delta' && event['params']['delta'] == 'Visible reply'), isTrue);
    compactMode = 'fail';
    live.clear();
    expect(
      (await turn(compact: true))['status'],
      'failed',
    );
    expect(live.where((event) => event['method'] == 'item/started' && event['params']['item']['type'] == 'contextCompaction'), hasLength(1));
    expect((await rolloutLines(client, id)).where((line) => line['type'] == 'compacted'), isEmpty);
    expect(live.any((event) => event['method'] == 'item/agentMessage/delta'), isFalse);
    expect(live.any((event) => event['method'] == 'item/reasoning/summaryTextDelta'), isFalse);
    expect(live.where((event) => event['method'] == 'happen/turn/retrying'), isNotEmpty);
    await turn(prompt: 'next');
    expect(jsonEncode(requests.last['input']), contains('receipt-867'));
    compactMode = 'wait';
    compactStarted = Completer<void>();
    final cancelled = turn(compact: true);
    await compactStarted.future.timeout(const Duration(seconds: 5));
    // Codex starts stay live; another client discovers them in the snapshot overlay.
    final observer = await AgentClient.connect(server.uri);
    try {
      final snapshot = jsonObject(await observer.request('thread/resume', {'threadId': id}));
      expect(snapshot['running'], isTrue);
      expect((snapshot['liveItems'] as List).where((item) => item['type'] == 'contextCompaction' && item['live'] == true), hasLength(1));
      final stopped = observer.events.stream.firstWhere((event) => event['method'] == 'turn/completed');
      await client.request('turn/interrupt', {'threadId': id, 'turnId': await activeTurn()});
      expect((await stopped.timeout(const Duration(seconds: 5)))['params']['threadId'], id);
    } finally {
      await observer.close();
    }
    expect((await cancelled)['status'], 'interrupted');
    expect((await rolloutLines(client, id)).where((line) => line['type'] == 'compacted'), isEmpty);
    compactMode = 'success';
    await File('${root.path}/repo/AGENTS.md')
        .writeAsString('Repository instruction: use cedar.');
    live.clear();
    final compacted = await turn(compact: true);
    expect(compacted['status'], 'completed', reason: compacted.toString());
    final checkpoint = (await rolloutLines(client, id)).singleWhere((line) => line['type'] == 'compacted');
    final lifecycle = live.where((event) => event['method'] == 'turn/completed' ||
      {'item/started', 'item/completed'}.contains(event['method']) && event['params']['item']['type'] == 'contextCompaction').toList();
    expect(lifecycle.map((event) => event['method']), ['item/started', 'item/completed', 'turn/completed']);
    final durable = jsonObject(await client.request('thread/items/list', {'threadId': id, 'turnId': compacted['id']}));
    expect(durable['data'][0]['item']['id'], lifecycle[1]['params']['item']['id']);
    expect(checkpoint['payload']['replacement_history'], isNotEmpty);
    expect(live.any((event) => event['method'] == 'item/agentMessage/delta'), isFalse);
    expect(live.any((event) => event['method'] == 'item/reasoning/summaryTextDelta'), isFalse);
    final restored = (await contextItems(client, id)).where((item) =>
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
    final recalled = await turn(prompt: 'recall');
    expect(recalled['status'], 'completed', reason: recalled.toString());
    final continuation = requests[requestIndex];
    expect(jsonEncode(continuation['input']), isNot(contains('receipt-867')));
    expect(jsonEncode(continuation['input']), contains('opaque-checkpoint'));
    expect(jsonEncode(continuation['input']), contains('use cedar'));
    final instructionItems = (continuation['input'] as List).where((item) => item['role'] == 'user')
      .map((item) => openAIMessageText(item as Map)).where((text) => text.startsWith('# AGENTS.md instructions')).toList();
    expect(instructionItems, hasLength(1));
    expect(instructionItems.single, contains('use cedar'));
    expect(instructionItems.single, isNot(contains('use maple')));
    expect(instructionItems.single, isNot(contains('replace all previously provided AGENTS.md instructions')));
    expect(jsonEncode(continuation['input']), contains('retain the newline'));
    expect(continuation['reasoning']['effort'], 'low');
    expect((continuation['input'] as List)
      .where((v) => v['type'] == 'configuration_update')
      .map((v) => v['reasoning']['effort']), ['high', 'high']);
    expect((continuation['input'] as List).last,
      {'type': 'configuration_update', 'reasoning': {'effort': 'high'}});
    Future<Json> recalledItem(String thread, Json turn) async {
      final page = jsonObject(await client.request('thread/items/list', {'threadId': thread, 'turnId': turn['id']}));
      final answer = (page['data'] as List).lastWhere((entry) => entry['item']['type'] == 'agentMessage')['item']['text'] as String;
      return jsonObject(jsonDecode(printedOpenAIOutput(jsonDecode(answer)).first));
    }
    final record = await recalledItem(id, recalled);
    expect(record['content'], contains('receipt-867'));
    await turn(compact: true);
    final latestInstructions = (await contextItems(client, id)).where((item) =>
      item['native']?['harness']?['context'] == 'agents_md',
    ).toList();
    expect(latestInstructions, hasLength(1));
    expect(jsonEncode(latestInstructions.single), contains('use cedar'));
    expect(jsonEncode(latestInstructions.single), isNot(contains('use maple')));
    expect(jsonEncode(latestInstructions.single), isNot(contains('replace all previously')));
    final fork = jsonObject(
      await client.request('thread/fork', {
        'threadId': id,
        'lastTurnId': compacted['id'],
      }),
    );
    final bundle = '${root.path}/saved.jsonl';
    await client.request('history.export', {
      'task_id': fork['thread']['id'],
      'path': bundle,
    });
    final imported = jsonObject(
      await client.request('history.import', {'path': bundle}),
    );
    for (final task in [fork['thread']['id'] as String, imported['task_id'] as String]) {
      final result = await turn(thread: task, prompt: 'recall');
      expect(result['status'], 'completed', reason: result.toString());
      expect(await recalledItem(task, result), record);
    }
    overflows = 1;
    live.clear();
    final recovered = await turn(prompt: 'next');
    expect(recovered['status'], 'completed', reason: recovered.toString());
    expect(live.where((event) => event['method'] == 'item/started' && event['params']['item']['type'] == 'contextCompaction'), hasLength(1));
    final before = requests
        .where((v) => v['input'].last['type'] == 'compaction_trigger')
        .length;
    overflows = 2;
    expect(
      (await turn(prompt: 'next'))['status'],
      'failed',
    );
    expect(
      requests
          .where((v) => v['input'].last['type'] == 'compaction_trigger')
          .length,
      before + 1,
    );
  });
}
