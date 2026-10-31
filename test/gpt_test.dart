import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  for (final transport in ['http', 'websocket']) {
    test(
      'GPT $transport preserves native state and ordered updates across requests',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final http = HttpClient();
        final bodies = <Json>[];
        final sockets = <WebSocket>[];
        final raw = ResponsesClient(
          http: http,
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/responses'),
          credentials: ({bool refresh = false}) async => {
            'access_token': 'fixture',
            'account_id': 'fixture',
          },
        );
        final provider = OpenAIProvider(raw);
        final settings = provider.resolveSettings({
          'reasoning': 'low',
          'transport': transport,
        });
        const tool = ToolDefinition(
          name: 'exec',
          namespace: 'functions',
          format: 'text',
          description: 'Execute JavaScript',
        );
        final native = <Json>[
          {
            'type': 'reasoning',
            'id': 'reasoning-1',
            'summary': [
              {'type': 'summary_text', 'text': 'Planning ✓'},
            ],
            'encrypted_content': 'opaque-reasoning',
          },
          {
            'type': 'message',
            'id': 'message-1',
            'role': 'assistant',
            'phase': 'commentary',
            'content': [
              {'type': 'output_text', 'text': 'Working'},
            ],
          },
          {
            'type': 'custom_tool_call',
            'id': 'item-1',
            'call_id': 'call-1',
            'namespace': 'functions',
            'name': 'exec',
            'input': 'text("✓");',
          },
        ];
        Future<void> respond(Json body, void Function(String) send) async {
          bodies.add(body);
          final input = (body['input'] as List).map(jsonObject).toList();
          final output = input.last['type'] == 'compaction_trigger'
              ? <Json>[
                  {
                    'type': 'compaction',
                    'id': 'checkpoint',
                    'encrypted_content': 'opaque-compaction',
                  },
                ]
              : bodies.length == 1
              ? native
              : <Json>[
                  {
                    'type': 'message',
                    'role': 'assistant',
                    'content': [
                      {'type': 'output_text', 'text': 'Done ✓'},
                    ],
                  },
                ];
          send(
            jsonEncode({
              'type': 'response.output_text.delta',
              'delta': 'Done ✓',
            }),
          );
          send(
            jsonEncode({
              'type': 'response.completed',
              'response': {
                'status': 'completed',
                'output': output,
                'usage': {
                  'input_tokens': 128,
                  'output_tokens': 20,
                  'input_tokens_details': {'cached_tokens': 64},
                },
              },
            }),
          );
        }

        server.listen((request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            final socket = await WebSocketTransformer.upgrade(request);
            sockets.add(socket);
            socket.listen((message) async {
              await respond(
                jsonObject(jsonDecode(message as String)),
                socket.add,
              );
            });
          } else {
            final body = jsonObject(
              jsonDecode(await utf8.decoder.bind(request).join()),
            );
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            await respond(body, (data) {
              final bytes = utf8.encode('data: $data\r\n\r\n');
              for (var i = 0; i < bytes.length; i += 3) {
                request.response.add(
                  bytes.sublist(i, (i + 3).clamp(0, bytes.length)),
                );
              }
            });
            await request.response.close();
          }
        });
        addTearDown(() async {
          for (final socket in sockets) {
            await socket.close();
          }
          http.close(force: true);
          await server.close(force: true);
        });
        ModelRequest request(List<ConversationItem> input) => ModelRequest(
          taskId: 'task',
          model: 'gpt-6.1-sol',
          instructions: 'fixture',
          input: input,
          tools: [tool],
          settings: settings,
          effectiveReasoning: 'high',
        );
        final user = ConversationItem.text('user', 'Create the result');
        final first = await provider.respond(
          request([user]),
          cancellation: CancellationToken(),
        );
        expect(first.calls.single.input, 'text("✓");');
        expect(first.usage.cachedInputTokens, 64);
        // Cross the actual durable record encoding before the next provider request.
        final restored =
            (jsonDecode(
                  jsonEncode(first.output.map((v) => v.toJson()).toList()),
                ) as List)
                .map((v) => ConversationItem.fromJson(jsonObject(v)))
                .toList();
        final context = [
          user,
          ...restored,
          ConversationItem.toolResult(first.calls.single, 'ok'),
          ConversationItem(
            kind: 'configuration',
            settings: {'reasoning': 'high'},
          ),
          ConversationItem.text('user', 'Continue'),
        ];
        final second = await provider.respond(
          request(context),
          cancellation: CancellationToken(),
        );
        expect(second.text, 'Done ✓');
        expect((bodies[1]['input'] as List).sublist(1, 4), native);
        expect(bodies[1]['reasoning'], {'effort': 'low'});
        expect(
          (bodies[1]['input'] as List).reversed.skip(1).first['type'],
          'configuration_update',
        );
        expect(bodies[1]['tools'][0]['name'], 'functions');
        expect(bodies[1]['tools'][0]['tools'][0]['type'], 'custom');
        if (transport == 'websocket') {
          expect(bodies[1]['type'], 'response.create');
        }

        final compacted = await provider.compact(
          request([...context, ...second.output]),
          cancellation: CancellationToken(),
        );
        expect(
          compacted.context.last.native['gpt']['encrypted_content'],
          'opaque-compaction',
        );
        expect(
          compacted.context
              .where((item) => item.role == 'user')
              .map((v) => v.text),
          ['Create the result', 'Continue'],
        );
        expect(bodies.last['input'].last, {'type': 'compaction_trigger'});
      },
    );
  }

  for (final transport in ['http', 'websocket']) {
    test('GPT $transport resets its idle limit, retries silence five times, and remains cancellable', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final http = HttpClient();
      final sockets = <WebSocket>[];
      final release = Completer<void>();
      var requests = 0;
      Future<void> respond(Json body, Future<void> Function(Json) send) async {
        requests++;
        await send({'type': 'response.created'});
        if (body['instructions'] == 'silent') {
          await release.future;
          return;
        }
        for (var i = 0; i < 2; i++) {
          // The client clock runs 600x faster: 380 ms is between the previous
          // three-minute limit and Codex's five-minute event-idle limit.
          await Future<void>.delayed(const Duration(milliseconds: 380));
          await send({'type': 'response.output_text.delta', 'delta': 'tick'});
        }
        await send({'type': 'response.completed', 'response': {
          'status': 'completed', 'output': [
            {'type': 'message', 'role': 'assistant', 'content': [
              {'type': 'output_text', 'text': 'Long response finished'},
            ]},
          ],
        }});
      }
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          socket.listen((raw) async {
            await respond(jsonObject(jsonDecode(raw as String)), (event) async {
              if (socket.readyState == WebSocket.open) socket.add(jsonEncode(event));
            });
          });
        } else {
          try {
            final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
            request.response.headers.contentType = ContentType('text', 'event-stream');
            request.response.bufferOutput = false;
            await respond(body, (event) async {
              request.response.write('data: ${jsonEncode(event)}\n\n');
              await request.response.flush();
            });
          } catch (_) {
            // A timed-out or cancelled client owns closing its stream.
          } finally {
            await request.response.close();
          }
        }
      });
      final cancellation = CancellationToken();
      final client = ResponsesClient(
        http: http,
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/responses'),
        credentials: ({bool refresh = false}) async => {
          'access_token': 'fixture', 'account_id': 'fixture',
        },
      );
      addTearDown(() async {
        cancellation.cancel();
        release.complete();
        for (final socket in sockets) {
          await socket.close();
        }
        http.close(force: true);
        await server.close(force: true);
      });
      final deltas = <String>[];
      final retries = <int>[];
      final progress = <String>[];
      var cancelOnRetry = false;
      Future<ResponsesReply> run(String mode) => runZoned(
        () => client.respond(
          model: 'gpt-6.1-sol', instructions: mode, input: [], tools: [],
          sessionId: newId(), cancellation: cancellation, transport: transport,
          onEvent: (event) {
            progress.add(event['type'] as String);
            if (event['type'] == 'text.delta') deltas.add(event['delta'] as String);
            if (event['type'] == 'model.retrying') {
              retries.add(event['attempt'] as int);
              if (cancelOnRetry) cancellation.cancel();
            }
          },
        ),
        zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
          parent.createTimer(zone, duration >= const Duration(minutes: 1) ? duration ~/ 600
              : duration >= const Duration(milliseconds: 100) && duration <= const Duration(seconds: 5) ? duration ~/ 100 : duration, callback)),
      );
      expect((await run('active')).text, 'Long response finished');
      expect(deltas, ['tick', 'tick']);
      expect(progress, ['model.connected', 'text.delta', 'text.delta']);
      progress.clear();
      await expectLater(run('silent'), throwsA(isA<ModelFailure>().having(
        (error) => error.code, 'code', 'stream_idle_timeout',
      )));
      expect(retries, [1, 2, 3, 4, 5]);
      expect(progress, [for (var attempt = 0; attempt < 6; attempt++) ...[
        'model.connected', if (attempt < 5) 'model.retrying',
      ]], reason: 'Accepted retries must report recovery even before the first text delta');
      expect((await run('active')).text, 'Long response finished');
      expect(requests, 8, reason: 'Retry exhaustion must not close the shared pool');
      cancelOnRetry = true;
      await expectLater(run('silent'), throwsA(isA<CancelledException>()));
      expect(requests, 9, reason: 'Cancellation during backoff must not send another request');
    });
  }

  test('GPT cancellation and provider incomplete responses do not retry or close the shared pool', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final http = HttpClient();
    final started = Completer<void>();
    final waiting = <HttpResponse>[];
    var requests = 0;
    server.listen((request) async {
      requests++;
      final body = jsonObject(
        jsonDecode(await utf8.decoder.bind(request).join()),
      );
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      if (body['instructions'] == 'wait') {
        request.response.write('data: {"type":"response.created"}\n\n');
        await request.response.flush();
        waiting.add(request.response);
        started.complete();
      } else {
        request.response.write(
          'data: {"type":"response.incomplete","response":{"status":"incomplete"}}\n\n',
        );
        await request.response.close();
      }
    });
    final client = ResponsesClient(
      http: http,
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      credentials: ({bool refresh = false}) async => {
        'access_token': 'fixture',
        'account_id': 'fixture',
      },
    );
    addTearDown(() async {
      http.close(force: true);
      for (final response in waiting) {
        unawaited(response.close());
      }
      await server.close(force: true);
    });
    Future<ResponsesReply> run(String instructions, CancellationToken token) =>
        client.respond(
          model: 'gpt-6.1-sol',
          instructions: instructions,
          input: [],
          tools: [],
          sessionId: newId(),
          cancellation: token,
        );
    final cancellation = CancellationToken();
    final cancelled = expectLater(
      run('wait', cancellation),
      throwsA(isA<CancelledException>()),
    );
    await started.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('GPT request never started'),
    );
    cancellation.cancel();
    await cancelled.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('GPT cancellation did not settle'),
    );
    await expectLater(
      run('incomplete', CancellationToken()).timeout(const Duration(seconds: 3)),
      throwsA(
        isA<ModelFailure>().having(
          (e) => e.code,
          'code',
          'incomplete_response',
        ),
      ),
    );
    expect(requests, 2);
  });
}
