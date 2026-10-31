import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  group('WebSocket agent protocol', () {
    late Directory root, work;
    late HttpServer provider;
    late AgentServer server;
    late AgentClient client;
    final requests = <Json>[];
    final streaming = <HttpResponse>[];
    late Completer<void> releaseStreams;
    var sequence = 0;
    var interruptedReplies = 0;

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
      interruptedReplies = 0;
      streaming.clear();
      releaseStreams = Completer<void>();
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
          final content = input[userIndex]['content'];
          final prompt = content is String ? content
              : (content as List).where((part) => part['type'] == 'input_text').firstOrNull?['text'] ?? '';
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
          final completedCalls = input
              .skip(userIndex + 1)
              .where((item) => item['type'] == 'custom_tool_call_output')
              .length;
          final hasOutput = completedCalls >= (prompt == 'long' ? 70 : 1);
          if (prompt == 'stream' || prompt == 'steering' && hasOutput) {
            request.response.bufferOutput = false;
            streaming.add(request.response);
            request.response.write('data: {"type":"response.created"}\n\n');
            await request.response.flush();
            await releaseStreams.future;
            await request.response.close();
            return;
          }
          if (prompt == 'recover' && hasOutput && interruptedReplies++ < 2) {
            request.response.write('data: {"type":"response.output_text.delta","delta":"Abandoned partial answer"}\n\n');
            await request.response.close();
            return;
          }
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
                    'input': prompt == 'long'
                        ? 'text("Step $completedCalls");'
                        : prompt == 'continue'
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
      releaseStreams.complete();
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

    test('live task notifications include the frozen context limit and task identity', () async {
      final events = <Json>[];
      final subscription = client.events.stream.listen(events.add);
      addTearDown(subscription.cancel);
      final completed = await turn('task.start', {
        'cwd': work.path, 'prompt': 'calculate',
        'settings': {'context_limit': 100000},
      });
      expect(completed['type'], 'turn.completed', reason: completed.toString());
      final id = completed['task_id'];
      final created = events.singleWhere((event) => event['type'] == 'task.created');
      expect(created['task_id'], id, reason: 'The desktop routes configuration by task identity');
      expect(created['data']['provider_settings']['context_limit'], 100000);
      expect(events.every((event) => event['task_id'] == id), isTrue);
      expect(events.where((event) => event['type'] == 'model.completed'), isNotEmpty);
      final history = await client.request('history.page', {'task_id': id}) as List;
      expect(created['seq'], history.first['seq']);
      expect(created['data'], history.first['data']);

      final legacyId = newId();
      final legacy = TaskStore(root.path, legacyId);
      try {
        final config = {
          'cwd': work.path, 'model': 'gpt-6.1-sol', 'reasoning': 'low',
          'instructions': 'Follow the user request.', 'tools': <Json>[],
        };
        legacy.append('task.created', config, metadata: {'config': config});
      } finally {
        legacy.close();
      }
      events.clear();
      final resumed = await turn('task.send', {'task_id': legacyId, 'prompt': 'continue'});
      expect(resumed['type'], 'turn.completed', reason: resumed.toString());
      final migrated = events.where((event) => event['type'] == 'task.configuration_migrated').toList();
      expect(migrated, hasLength(1), reason: 'Resolved settings must reach already subscribed clients');
      expect(migrated.single['task_id'], legacyId);
      expect(migrated.single['data']['provider_settings']['context_limit'], 272000);
      final replay = await client.request('history.page', {'task_id': legacyId}) as List;
      expect(migrated.single['data'], replay.singleWhere((event) => event['type'] == 'task.configuration_migrated')['data']);
    });

    test('turns stay active after 24, 48 and 72 hours and still stop explicitly', () async {
      await client.close();
      await server.close();
      final clock = FakeAsync();
      // Advance long deadlines in the server's isolate while real sockets and
      // workers continue running. Keep transport heartbeats on real time.
      server = await runZoned(
        () => AgentServer.start(
          directory: root.path,
          configPath: '${root.path}/config.yaml',
          port: 0,
          endpoint: 'http://127.0.0.1:${provider.port}/responses',
        ),
        zoneSpecification: ZoneSpecification(createTimer: (_, parent, zone, duration, callback) {
          if (duration < const Duration(minutes: 10)) {
            return parent.createTimer(zone, duration, callback);
          }
          return clock.run((_) => Timer(duration, () => zone.run(callback)));
        }),
      );
      client = await AgentClient.connect(server.uri);
      final terminal = <Json>[];
      final subscription = client.events.stream.where(
        (event) => {'turn.completed', 'turn.cancelled', 'turn.failed'}.contains(event['type']),
      ).listen(terminal.add);
      addTearDown(subscription.cancel);
      final id = jsonObject(await client.request('task.start', {
        'cwd': work.path, 'prompt': 'stream',
      }))['task_id'] as String;
      while (streaming.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (final hours in [24, 48, 72]) {
        clock.elapse(const Duration(hours: 24));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(terminal, isEmpty, reason: 'A turn must survive $hours hours');
        expect(jsonObject(await client.request('task.subscribe', {'task_id': id}))['running'], isTrue);
        expect(jsonObject(await client.request('ping'))['version'], '0.1.0');
      }
      final stopped = client.events.stream.firstWhere((event) => event['type'] == 'turn.cancelled');
      await client.request('task.cancel', {'task_id': id});
      final event = await stopped.timeout(const Duration(seconds: 5));
      expect(terminal.map((event) => event['type']), ['turn.cancelled']);
      final history = await client.request('history.page', {'task_id': id}) as List;
      expect(history.last['id'], event['id']);
      expect(jsonObject(await client.request('task.subscribe', {'task_id': id}))['running'], isFalse);
    });

    test('turns have no step limit, including resumed tasks with legacy limits', () async {
      final first = await turn('task.start', {'cwd': work.path, 'prompt': 'long'});
      expect(first['type'], 'turn.completed', reason: first.toString());
      final id = first['task_id'] as String;
      final store = TaskStore(root.path, id, create: false);
      try {
        final config = {...jsonObject(store.metadata('config')), 'max_steps': 1};
        store.append('task.configuration_migrated', config, metadata: {'config': config});
      } finally {
        store.close();
      }
      final resumed = await turn('task.send', {'task_id': id, 'prompt': 'long'});
      expect(resumed['type'], 'turn.completed', reason: resumed.toString());
      expect(requests.length, 142);
      expect((requests.last['input'] as List).where((item) => item['type'] == 'custom_tool_call_output'), hasLength(140));
    });

    test('steering preempts inference, preserves completed work, and leaves queued input for its turn', () async {
      final events = <Json>[];
      final subscription = client.events.stream.listen(events.add);
      addTearDown(subscription.cancel);
      final id = jsonObject(await client.request('task.start', {
        'cwd': work.path, 'prompt': 'steering', 'reasoning': 'low',
      }))['task_id'] as String;
      Future<void> until(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!ready()) {
          if (DateTime.now().isAfter(deadline)) fail('Steering did not advance the active turn');
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      await until(() => streaming.isNotEmpty);
      expect(await File('${work.path}/result.txt').readAsString(), '42\n');
      await client.request('task.send', {
        'task_id': id, 'prompt': 'continue', 'delivery': 'queue', 'reasoning': 'medium',
      });
      expect(requests, hasLength(2), reason: 'Queue must not interrupt inference');
      final firstSteer = jsonObject(await client.request('task.send', {
        'task_id': id, 'prompt': 'stream', 'delivery': 'steer', 'reasoning': 'high',
      }));
      // Both provider streams stay blocked. Only steering can advance the turn.
      await until(() => streaming.length == 2);
      final finished = Completer<void>();
      final terminal = <Json>[];
      final terminals = client.events.stream.where((event) => {
        'turn.completed', 'turn.cancelled', 'turn.failed',
      }.contains(event['type'])).listen((event) {
        terminal.add(event);
        if (!finished.isCompleted && (event['type'] != 'turn.completed' || terminal.length == 2)) finished.complete();
      });
      addTearDown(terminals.cancel);
      final secondSteer = jsonObject(await client.request('task.send', {
        'task_id': id, 'prompt': 'continue', 'delivery': 'steer', 'reasoning': 'max',
      }));
      await finished.future.timeout(const Duration(seconds: 5));
      expect(terminal.map((event) => event['type']), ['turn.completed', 'turn.completed']);
      expect(events.where((event) => event['type'] == 'model.retrying'), isEmpty);
      expect(requests, hasLength(7), reason: 'Interrupted requests must not retry stale input');
      final history = (await client.request('history.page', {'task_id': id}) as List).map(jsonObject).toList();
      expect(history.where((event) => event['type'] == 'model.completed'), hasLength(5));
      expect(history.where((event) => event['type'] == 'tool.started'), hasLength(3));
      final inputs = history.where((event) => event['type'] == 'input.committed').toList();
      expect(inputs.map((event) => event['data']['message_id']).skip(1).take(2), [firstSteer['message_id'], secondSteer['message_id']]);
      final commits = events.where((event) => event['type'] == 'input.committed').toList();
      expect(commits.take(3).map((event) => event['turn_id']).toSet(), {terminal.first['turn_id']});
      expect(commits.last['turn_id'], terminal.last['turn_id']);
      expect(terminal.last['turn_id'], isNot(terminal.first['turn_id']));
      for (final (request, effort) in [(requests[2], 'high'), (requests[3], 'max'), (requests[5], 'medium')]) {
        final input = (request['input'] as List).map(jsonObject).toList();
        final user = input.lastIndexWhere((item) => item['role'] == 'user');
        expect(input[user - 1], {'type': 'configuration_update', 'reasoning': {'effort': effort}});
        expect(request['reasoning'], {'effort': 'low'});
        expect(input.take((requests[1]['input'] as List).length), requests[1]['input']);
      }
      expect(jsonDecode((requests[4]['input'] as List).last['output'] as String)['output'], ['42']);
      expect(jsonDecode((requests[6]['input'] as List).last['output'] as String)['output'], ['42']);
      expect(releaseStreams.isCompleted, isFalse);
      expect(jsonObject(await client.request('telemetry'))['resident_tasks'], 0);
    });

    test('interrupted model streams recover without repeating executed tools', () async {
      final retries = <Json>[];
      final subscription = client.events.stream.where((event) => event['type'] == 'model.retrying').listen(retries.add);
      addTearDown(subscription.cancel);
      final result = await turn('task.start', {'cwd': work.path, 'prompt': 'recover'});
      expect(result['type'], 'turn.completed', reason: result.toString());
      expect(result['data']['text'], 'Verified 42 ✓');
      expect(retries.map((event) => event['attempt']), [1, 2]);
      expect(requests.length, 4);
      expect(await File('${work.path}/result.txt').readAsString(), '42\n');
      final history = await client.request('history.page', {'task_id': result['task_id']}) as List;
      expect(history.where((event) => event['type'] == 'tool.started'), hasLength(1));
      expect(history.where((event) => event['type'] == 'model.completed'), hasLength(2));
    });

    test(
      'executes tools and preserves attached images across restart, fork and import',
      () async {
        // A padded PNG exercises payloads larger than the old 2 MiB frame/context budget.
        final image = base64Encode([
          ...base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='),
          ...List.filled(2 * 1024 * 1024, 0),
        ]);
        final first = await turn('task.start', {
          'settings': {'verbosity': 'low'},
          'cwd': work.path,
          'prompt': 'calculate',
          'attachments': [
            {'type': 'image', 'name': 'screenshot.png', 'mime_type': 'image/png', 'data': image},
            {'type': 'file', 'name': 'numbers.txt', 'path': '${work.path}/numbers.txt'},
          ],
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
        expect(id, matches(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'));
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
        expect(fork['task_id'], matches(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'));
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
        expect(imported['task_id'], matches(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'));
        expect(imported['task_id'], isNot(operationId));
        final moved = await turn('task.send', {
          'task_id': imported['task_id'],
          'prompt': 'continue',
        });
        expect(moved['type'], 'turn.completed', reason: moved.toString());
        for (final request in requests) {
          final user = (request['input'] as List).firstWhere((item) => item['role'] == 'user' && item['content'] is List);
          final parts = user['content'] as List;
          expect(parts.where((part) => part['type'] == 'input_image').single['image_url'], 'data:image/png;base64,$image');
          expect(parts.where((part) => part['type'] == 'input_text').map((part) => part['text']).join('\n'), contains('${work.path}/numbers.txt'));
        }
        final history = await client.request('history.page', {'task_id': imported['task_id']}) as List;
        final input = history.firstWhere((event) => event['type'] == 'input.committed')['data']['item'];
        expect((input['content'] as List).firstWhere((part) => part['type'] == 'image')['data'], image);

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
      final started = jsonObject(await client.request('task.start', {'cwd': work.path, 'prompt': 'wait', 'reasoning': 'low'}));
      final id = started['task_id'] as String;
      await client.request('task.send', {'task_id': id, 'prompt': 'do not deliver', 'delivery': 'queue', 'reasoning': 'high'});
      await client.request('task.archive', {'task_id': id});
      final history = (await client.request('history.page', {'task_id': id}) as List).map(jsonObject).toList();
      expect(history.last['type'], 'task.archived');
      expect(history.any((event) => event['type'] == 'turn.cancelled'), isTrue);
      expect(history.any((event) => event['type'] == 'configuration.updated'), isFalse);
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

    test('active turns outlive RPC deadlines and still drain queued input', () async {
      await client.close();
      await server.close();
      // Advance long RPC deadlines 600 times faster without changing production
      // configuration. Agent/network isolates retain their real transport clocks.
      server = await runZoned(
        () => AgentServer.start(
          directory: root.path,
          configPath: '${root.path}/config.yaml',
          port: 0,
          endpoint: 'http://127.0.0.1:${provider.port}/responses',
        ),
        zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
          parent.createTimer(zone, duration >= const Duration(minutes: 1) ? duration ~/ 600 : duration, callback)),
      );
      client = await AgentClient.connect(server.uri);
      final terminal = <Json>[];
      final finished = Completer<void>();
      final events = client.events.stream.listen((event) {
        if ({'turn.completed', 'turn.failed', 'turn.cancelled'}.contains(event['type'])) {
          terminal.add(event);
          if (terminal.length == 2 && !finished.isCompleted) finished.complete();
        }
      });
      addTearDown(events.cancel);
      final id = jsonObject(await client.request('task.start', {
        'cwd': work.path, 'prompt': 'stream',
      }))['task_id'] as String;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (streaming.isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('Provider stream did not start');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await client.request('task.send', {'task_id': id, 'prompt': 'continue', 'delivery': 'queue'});
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(terminal, isEmpty, reason: 'An RPC deadline must not stop a running turn');
      expect(jsonObject(await client.request('task.subscribe', {'task_id': id}))['running'], isTrue);
      expect(jsonObject(await client.request('ping'))['version'], '0.1.0');
      streaming.single.write('data: ${jsonEncode({
        'type': 'response.completed',
        'response': {'status': 'completed', 'output': [
          {'type': 'message', 'role': 'assistant', 'content': [
            {'type': 'output_text', 'text': 'Long turn finished'},
          ]},
        ]},
      })}\n\n');
      await streaming.single.flush();
      await finished.future.timeout(const Duration(seconds: 10));
      expect(terminal.map((event) => event['type']), ['turn.completed', 'turn.completed']);
      expect(terminal.first['data']['text'], 'Long turn finished');
      expect(terminal.every((event) => event['seq'] is int), isTrue);
      expect(jsonObject(await client.request('telemetry'))['resident_tasks'], 0);
    });

    test(
      'one socket searches files while 100 tasks stream, and cancels one task independently',
      () async {
        final taskIds = <String>[];
        final deltas = <String, String>{};
        final subscription = client.events.stream.listen((event) {
          if (event['type'] == 'text.delta') {
            deltas.update(event['task_id'] as String, (text) => text + (event['delta'] as String), ifAbsent: () => event['delta'] as String);
          }
        });
        addTearDown(subscription.cancel);
        for (var i = 0; i < 100; i++) {
          taskIds.add(jsonObject(await client.request('task.start', {
            'cwd': work.path,
            'prompt': 'stream',
          }))['task_id'] as String);
        }
        Future<void> until(bool Function() ready) async {
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (!ready()) {
            if (DateTime.now().isAfter(deadline)) fail('Timed out: ${streaming.length} provider streams, ${deltas.length} task deltas');
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        await until(() => streaming.length == 100);
        Future<void> pulse(String text) async {
          for (final response in streaming) {
            response.write('data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': text})}\n\n');
          }
          await Future.wait(streaming.map((response) => response.flush()));
        }
        await pulse('first ');
        await until(() => deltas.length == 100);
        expect(jsonObject(await client.request('telemetry'))['active_tasks'], 100);

        final token = CancellationToken();
        final search = client.searchFiles(work.path, 'numbers', cancellation: token);
        final ping = client.request('ping');
        await pulse('second');
        expect((await search.timeout(const Duration(seconds: 5)))['paths'], ['numbers.txt']);
        expect(jsonObject(await ping)['version'], '0.1.0');
        await until(() => deltas.values.every((text) => text == 'first second'));
        expect(deltas.keys, unorderedEquals(taskIds));
        token.cancel();
        // Hold event acknowledgements to model a mobile uplink falling behind.
        // RPC replies must still pass while the event window is exhausted.
        final slow = await WebSocket.connect(server.uri.toString());
        final replies = <int, Completer<Json>>{};
        final slowText = <String, String>{};
        final disconnected = Completer<void>();
        var rpcId = 0, slowDeltas = 0;
        final slowEvents = slow.listen((raw) {
          final message = jsonObject(jsonDecode(raw as String));
          if (message['event']?['type'] == 'text.delta') {
            slowDeltas++;
            final event = jsonObject(message['event']);
            slowText.update(event['task_id'] as String, (text) => text + (event['delta'] as String), ifAbsent: () => event['delta'] as String);
          }
          if (message['id'] case final int id) {
            final reply = replies.remove(id);
            if (message.containsKey('error')) {
              reply?.completeError(StateError(message['error'].toString()));
            } else {
              reply?.complete(jsonObject(message['result']));
            }
          }
        }, onDone: () {
          for (final reply in replies.values) {
            reply.completeError(StateError('Socket closed: ${slow.closeCode} ${slow.closeReason}'));
          }
          replies.clear();
          disconnected.complete();
        });
        addTearDown(() async { await slow.close(); await slowEvents.cancel(); });
        Future<Json> slowCall(String method, Json params) {
          if (slow.readyState != WebSocket.open) {
            throw StateError('Socket closed: ${slow.closeCode} ${slow.closeReason}');
          }
          final id = ++rpcId, reply = Completer<Json>();
          replies[id] = reply;
          slow.add(jsonEncode({'id': id, 'method': method, 'params': params}));
          return reply.future.timeout(const Duration(seconds: 5));
        }
        for (final id in taskIds) {
          await slowCall('task.subscribe', {'task_id': id});
        }
        for (var i = 0; i < 3; i++) {
          await pulse(' buffered$i');
        }
        await until(() => deltas.values.every((text) => text.endsWith(' buffered0 buffered1 buffered2')));
        expect((await slowCall('files.search', {'cwd': work.path, 'query': 'numbers'}))['paths'], ['numbers.txt']);
        expect(slowDeltas, 256);
        slow.add(jsonEncode({'method': 'events.ack', 'params': {'count': 100}}));
        await until(() => slowDeltas == 300);
        expect(slowText.keys, unorderedEquals(taskIds));
        expect(slowText.values, everyElement(' buffered0 buffered1 buffered2'));
        // An indefinitely stalled client still has a bounded backlog.
        for (var i = 0; i < 12; i++) {
          await pulse(' stalled');
        }
        await disconnected.future.timeout(const Duration(seconds: 5));
        expect(slow.closeCode, 1008);
        await slow.close();
        final stopped = client.events.stream.firstWhere((event) => event['type'] == 'turn.cancelled');
        final success = client.events.stream.firstWhere(
          (event) => event['type'] == 'turn.completed',
        );
        await client.request('task.start', {
          'cwd': work.path,
          'prompt': 'calculate',
        });
        await client.request('task.cancel', {'task_id': taskIds.first});
        expect(
          (await success.timeout(const Duration(seconds: 10)))['data']['text'],
          'Verified 42 ✓',
        );
        expect(
          (await stopped.timeout(const Duration(seconds: 5)))['task_id'],
          taskIds.first,
        );
        expect(jsonObject(await client.request('telemetry'))['active_tasks'], 99);
        expect((await client.request('ping') as Map)['version'], '0.1.0');
      },
    );
  });
}
