import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  group('WebSocket agent protocol', () {
    late Directory root, work;
    late HttpServer provider;
    late AgentServer server;
    late AgentClient client;
    final requests = <Json>[];
    var sequence = 0;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('agent-contract-');
      work = await Directory('${root.path}/work').create();
      await File('${work.path}/numbers.txt').writeAsString('19\n23\n');
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
      requests.clear();
      provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      provider.listen((request) async {
        try {
          final body = jsonObject(
            jsonDecode(await utf8.decoder.bind(request).join()),
          );
          requests.add(body);
          final input = (body['input'] as List).map(jsonObject).toList();
          final userIndex = input.lastIndexWhere(
            (item) => item['role'] == 'user',
          );
          final prompt = input[userIndex]['content'] as String;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          if (prompt == 'wait') {
            request.response.write('data: {"type":"response.created"}\n\n');
            await request.response.flush();
            await Future<void>.delayed(const Duration(seconds: 2));
            await request.response.close();
            return;
          }
          final hasOutput = input
              .skip(userIndex + 1)
              .any((item) => item['type'] == 'custom_tool_call_output');
          final output = hasOutput
              ? <Json>[
                  {
                    'type': 'message',
                    'role': 'assistant',
                    'content': [
                      {'type': 'output_text', 'text': 'Verified 42 ✓'},
                    ],
                  },
                ]
              : <Json>[
                  {
                    'type': 'reasoning',
                    'id': 'reasoning_fixture',
                    'summary': [],
                    'encrypted_content': 'opaque-history',
                  },
                  {
                    'type': 'custom_tool_call',
                    'namespace': 'functions',
                    'call_id': 'call_${++sequence}',
                    'name': 'exec',
                    'input': prompt == 'continue'
                        ? 'text(load("sum"));'
                        : '''
                    const file = await tools.exec_command({cmd:"cat numbers.txt",login:false});
                    const sum = file.output.trim().split(/\\s+/).map(Number).reduce((a,b)=>a+b,0);
                    await tools.apply_patch("*** Begin Patch\\n*** Add File: result.txt\\n+"+sum+"\\n*** End Patch");
                    store("sum",sum);
                    text(await tools.exec_command({cmd:"cat result.txt"}));
                  ''',
                  },
                ];
          if (hasOutput) {
            request.response.write(
              'data: {"type":"response.output_text.delta","delta":"Verified 42 ✓"}\n\n',
            );
          }
          final bytes = utf8.encode(
            'data: ${jsonEncode({
              'type': 'response.completed',
              'response': {
                'status': 'completed',
                'output': output,
                'usage': {'input_tokens': 10, 'output_tokens': 5},
              },
            })}\r\n\r\n',
          );
          for (var i = 0; i < bytes.length; i += 7) {
            request.response.add(
              bytes.sublist(i, (i + 7).clamp(0, bytes.length)),
            );
          }
          await request.response.close();
        } catch (_) {
          await request.response.close();
        }
      });
      server = await AgentServer.start(
        directory: root.path,
        configPath: '${root.path}/config.yaml',
        port: 0,
        endpoint: 'http://127.0.0.1:${provider.port}/responses',
      );
      client = await AgentClient.connect(server.uri);
    });

    tearDown(() async {
      await client.close();
      await server.close();
      await provider.close(force: true);
      await root.delete(recursive: true);
    });

    Future<Json> turn(String method, Json params) async {
      final completion = client.events.stream.firstWhere(
        (event) => [
          'turn.completed',
          'turn.failed',
          'turn.cancelled',
        ].contains(event['type']),
      );
      await client.request(method, params);
      return completion.timeout(const Duration(seconds: 15));
    }

    test(
      'executes tools, resumes after restart, forks and imports independently',
      () async {
        final first = await turn('task.start', {
          'settings': {'verbosity': 'low'},
          'cwd': work.path,
          'prompt': 'calculate',
        });
        expect(first['type'], 'turn.completed', reason: first.toString());
        final toolResult = (requests.last['input'] as List).lastWhere(
          (item) => item['type'] == 'custom_tool_call_output',
        );
        expect(
          jsonDecode(toolResult['output'] as String),
          isNot(contains('error')),
        );
        expect(await File('${work.path}/result.txt').readAsString(), '42\n');
        expect(first['data']['text'], 'Verified 42 ✓');
        expect(
          requests.last['input'].any(
            (item) => item['encrypted_content'] == 'opaque-history',
          ),
          isTrue,
        );
        final id = first['task_id'] as String;
        final page = await client.request('history.page', {
          'task_id': id,
          'limit': 2,
        }) as List;
        expect(page.length, 2);
        final nextPage = await client.request('history.page', {
          'task_id': id,
          'after': page.last['seq'],
          'limit': 2,
        }) as List;
        expect(nextPage.first['seq'], greaterThan(page.last['seq'] as int));

        await client.close();
        await server.close();
        server = await AgentServer.start(
          directory: root.path,
          configPath: '${root.path}/config.yaml',
          port: 0,
          endpoint: 'http://127.0.0.1:${provider.port}/responses',
        );
        client = await AgentClient.connect(server.uri);
        final resumed = await turn('task.send', {
          'task_id': id,
          'prompt': 'continue',
        });
        expect(resumed['type'], 'turn.completed', reason: resumed.toString());
        final outputs = (requests.last['input'] as List)
            .where((item) => item['type'] == 'custom_tool_call_output')
            .toList();
        expect(jsonDecode(outputs.last['output'] as String)['output'], ['42']);

        final fork = jsonObject(
          await client.request('task.fork', {
            'task_id': id,
            'through': first['seq'],
          }),
        );
        final bundle = '${root.path}/portable.jsonl';
        await client.request('history.export', {
          'task_id': fork['task_id'],
          'path': bundle,
        });
        await Directory('${root.path}/tasks/$id').delete(recursive: true);
        final child = await turn('task.send', {
          'task_id': fork['task_id'],
          'prompt': 'continue',
        });
        expect(child['type'], 'turn.completed', reason: child.toString());
        final operationId = newId();
        final imported = jsonObject(
          await client.request('history.import', {
            'path': bundle,
            'operation_id': operationId,
          }),
        );
        final retry = await client.request('history.import', {
          'path': bundle,
          'operation_id': operationId,
        });
        expect(retry, imported);
        final moved = await turn('task.send', {
          'task_id': imported['task_id'],
          'prompt': 'continue',
        });
        expect(moved['type'], 'turn.completed', reason: moved.toString());

        await File(bundle).writeAsString(
          (await File(
            bundle,
          ).readAsString()).replaceFirst('opaque-history', 'broken-history'),
        );
        await expectLater(
          client.request('history.import', {'path': bundle}),
          throwsStateError,
        );
      },
    );

    test('archive stops work, survives cleanup, restores, and releases idle owners', () async {
      for (var i = 0; i < 12; i++) {
        final finished = await turn('task.start', {'cwd': work.path, 'prompt': 'continue'});
        expect(finished['type'], 'turn.completed');
        final metrics = jsonObject(await client.request('telemetry'));
        expect(metrics['resident_tasks'], 0);
        expect(metrics['active_tasks'], 0);
      }
      final started = jsonObject(await client.request('task.start', {'cwd': work.path, 'prompt': 'wait'}));
      final id = started['task_id'] as String;
      await client.request('task.send', {'task_id': id, 'prompt': 'do not deliver', 'delivery': 'queue'});
      await client.request('task.archive', {'task_id': id});
      final history = (await client.request('history.page', {'task_id': id}) as List).map(jsonObject).toList();
      expect(history.last['type'], 'task.archived');
      expect(history.any((event) => event['type'] == 'turn.cancelled'), isTrue);
      expect(history.any((event) => event['data']['item']?['content']?.toString().contains('do not deliver') == true), isFalse);

      final old = await Directory('${root.path}/staging/${'a' * 32}').create(recursive: true);
      await File('${old.path}/unfinished').writeAsString('interrupted transfer');
      expect((await Process.run('touch', ['-t', '200001010000', old.path])).exitCode, 0);
      final fresh = await Directory('${root.path}/staging/${'b' * 32}').create();
      final link = await Link('${root.path}/staging/${'c' * 32}').create(work.path);
      final cleanup = jsonObject(await client.request('maintenance.run'));
      expect(cleanup['staging_removed'], 1);
      expect(cleanup['archived_tasks'], 1);
      expect(await old.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
      expect(await link.exists(), isTrue);
      expect(await File('${work.path}/numbers.txt').readAsString(), '19\n23\n');
      expect((await client.request('history.page', {'task_id': id}) as List).length, history.length);
      final blocked = await turn('task.send', {'task_id': id, 'prompt': 'continue'});
      expect(blocked['type'], 'turn.failed');
      expect(blocked['data']['error'], contains('Restore this task'));
      await client.request('task.unarchive', {'task_id': id});
      final continued = await turn('task.send', {'task_id': id, 'prompt': 'continue'});
      expect(continued['type'], 'turn.completed', reason: continued.toString());
      expect(jsonObject(await client.request('telemetry'))['resident_tasks'], 0);
    });

    test(
      'one multiplexed socket serves independent tasks and cancellation',
      () async {
        final stopped = client.events.stream.firstWhere(
          (event) => event['type'] == 'turn.cancelled',
        );
        final waiting = jsonObject(
          await client.request('task.start', {
            'cwd': work.path,
            'prompt': 'wait',
          }),
        );
        while (!requests.any(
          (request) => (request['input'] as List).any(
            (item) => item['content'] == 'wait',
          ),
        )) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final success = client.events.stream.firstWhere(
          (event) => event['type'] == 'turn.completed',
        );
        await client.request('task.start', {
          'cwd': work.path,
          'prompt': 'calculate',
        });
        await client.request('task.cancel', {'task_id': waiting['task_id']});
        expect(
          (await success.timeout(const Duration(seconds: 10)))['data']['text'],
          'Verified 42 ✓',
        );
        expect(
          (await stopped.timeout(const Duration(seconds: 5)))['task_id'],
          waiting['task_id'],
        );
        expect((await client.request('ping') as Map)['version'], '0.1.0');
      },
    );
  });
}
