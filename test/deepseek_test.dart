import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:deepseek/deepseek.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

const _exec = ToolDefinition(
  name: 'exec',
  namespace: 'functions',
  description: 'Execute JavaScript.',
  format: 'text',
  grammar: 'start: /[\\s\\S]+/',
);

void main() {
  late _Harness harness;
  setUp(() async => harness = await _Harness.open());
  tearDown(() async => harness.close());

  ModelRequest request(
    List<ConversationItem> input, {
    Json settings = const {},
    String effort = 'high',
    List<ToolDefinition> tools = const [_exec],
  }) => ModelRequest(
    taskId: 'fixture-task',
    model: 'deepseek-flash',
    instructions: 'Complete the user task.',
    input: input,
    tools: tools,
    settings: harness.provider.resolveSettings(settings),
    effectiveReasoning: effort,
  );

  test('Messages replays signed thinking and raw Codex tool input after durable roundtrip', () async {
    var turn = 0;
    harness.handler = (http, _) async {
      if (turn++ == 0) {
        await _send(http.response, [
          _start,
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'thinking',
              'thinking': 'Plan',
              'signature': 'signed-',
            },
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': ' carefully'},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'signature_delta', 'signature': 'state'},
          },
          {'type': 'content_block_stop', 'index': 0},
          {
            'type': 'content_block_start',
            'index': 1,
            'content_block': {
              'type': 'tool_use',
              'id': 'call-one',
              'name': 'functions__exec',
              'input': {},
            },
          },
          {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': jsonEncode({'input': 'text("✓");'}),
            },
          },
          {'type': 'content_block_stop', 'index': 1},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': {'output_tokens': 9},
          },
          {'type': 'message_stop'},
        ], fragment: true);
      } else {
        await _send(http.response, _text('Done'));
      }
    };
    final events = <Json>[];
    final first = await harness.provider.respond(
      request([ConversationItem.text('user', 'Run the code')]),
      cancellation: CancellationToken(),
      onEvent: events.add,
    );
    expect(first.calls.single.namespace, 'functions');
    expect(first.calls.single.name, 'exec');
    expect(first.calls.single.format, 'text');
    expect(first.calls.single.input, 'text("✓");');
    expect(
      events
          .where((event) => event['type'] == 'reasoning.delta')
          .map((event) => event['delta'])
          .join(),
      'Plan carefully',
    );
    expect(first.usage.toJson(), {
      'input_tokens': 17,
      'output_tokens': 9,
      'cached_input_tokens': 5,
      'cache_write_tokens': 2,
    });
    final restored = ModelReply.fromJson(
      jsonObject(jsonDecode(jsonEncode(first.toJson()))),
    );
    await harness.provider.respond(
      request([
        ConversationItem.text('user', 'Run the code'),
        ...restored.output,
        ConversationItem.toolResult(restored.calls.single, '✓'),
      ]),
      cancellation: CancellationToken(),
    );
    expect(harness.paths, ['/v1/messages', '/v1/messages']);
    expect(harness.headers.first['anthropic-version'], '2023-06-01');
    expect(harness.headers.first['uses-api-key'], true);
    final tool = jsonObject((harness.bodies.first['tools'] as List).single);
    expect(tool['name'], 'functions__exec');
    expect(tool['input_schema'], {
      'type': 'object',
      'properties': {
        'input': {'type': 'string'},
      },
      'required': ['input'],
      'additionalProperties': false,
    });
    final messages = (harness.bodies.last['messages'] as List)
        .map(jsonObject)
        .toList();
    expect(messages[1]['content'], [
      {
        'type': 'thinking',
        'thinking': 'Plan carefully',
        'signature': 'signed-state',
      },
      {
        'type': 'tool_use',
        'id': 'call-one',
        'name': 'functions__exec',
        'input': {'input': 'text("✓");'},
      },
    ]);
    expect(messages.last['content'], [
      {
        'type': 'tool_result',
        'tool_use_id': 'call-one',
        'content': [
          {'type': 'text', 'text': '✓'},
        ],
      },
    ]);
  });

  test('Messages routes an added client tool and replays its correlated error result', () async {
    const added = ToolDefinition(
      name: 'browser_title',
      namespace: 'client',
      description: 'Get the title of a browser tab.',
      parameters: {
        'type': 'object',
        'properties': {
          'tab_id': {'type': 'integer'},
        },
        'required': ['tab_id'],
      },
    );
    final input = [
      ConversationItem.text('user', 'First'),
      ConversationItem.text('assistant', 'Ready'),
      ConversationItem(kind: 'tools', tools: const [added]),
      ConversationItem.text(
        'developer',
        'Use the newly available browser tool.',
      ),
      ConversationItem.text('user', 'Next'),
    ];
    harness.handler = (http, _) => _send(http.response, [
      _start,
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'tool_use',
          'id': 'client-call',
          'name': 'client__browser_title',
          'input': {},
        },
      },
      {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"tab_id":7}'},
      },
      {'type': 'content_block_stop', 'index': 0},
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'tool_use'},
      },
      {'type': 'message_stop'},
    ]);
    final reply = await harness.provider.respond(
      request(input),
      cancellation: CancellationToken(),
    );
    final restored = ModelReply.fromJson(
      jsonObject(jsonDecode(jsonEncode(reply.toJson()))),
    );
    final call = restored.calls.single;
    expect(call.namespace, 'client');
    expect(call.name, 'browser_title');
    expect(call.format, 'json');
    expect(jsonDecode(call.input), {'tab_id': 7});
    final body = harness.bodies.single;
    final messages = (body['messages'] as List).map(jsonObject).toList();
    expect(messages.map((message) => message['role']), [
      'user',
      'assistant',
      'user',
      'system',
    ]);
    expect((messages.last['content'] as List).first, {
      'type': 'tool_addition',
      'tool': {'type': 'tool_reference', 'name': 'client__browser_title'},
    });
    expect((body['tools'] as List).last['defer_loading'], true);
    expect(
      harness.headers.single['anthropic-beta'],
      'mid-conversation-tool-changes-2026-07-01',
    );
    harness.handler = (http, _) =>
        _send(http.response, _text('The tab was closed.'));
    await harness.provider.respond(
      request([
        ...input,
        ...restored.output,
        ConversationItem.toolResult(
          call,
          '{"error":"tab closed"}',
          isError: true,
        ),
      ]),
      cancellation: CancellationToken(),
    );
    final replay = (harness.bodies.last['messages'] as List)
        .map(jsonObject)
        .toList();
    expect((replay[4]['content'] as List).single, {
      'type': 'tool_use',
      'id': 'client-call',
      'name': 'client__browser_title',
      'input': {'tab_id': 7},
    });
    expect((replay.last['content'] as List).single, {
      'type': 'tool_result',
      'tool_use_id': 'client-call',
      'is_error': true,
      'content': [
        {'type': 'text', 'text': '{"error":"tab closed"}'},
      ],
    });
  });

  test('chat transport preserves structured reasoning and tool arguments on replay', () async {
    final provider = harness.chatProvider;
    var turn = 0;
    harness.handler = (http, _) async {
      if (turn++ == 0) {
        await _send(http.response, [
          {
            'id': 'chat-one',
            'choices': [
              {
                'index': 0,
                'delta': {
                  'reasoning_content': 'Check ',
                  'reasoning_details': [
                    {
                      'type': 'reasoning.encrypted',
                      'index': 0,
                      'data': 'opaque-',
                      'signature': 'sig',
                    },
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'index': 0,
                'delta': {
                  'reasoning_content': 'history',
                  'reasoning_details': [
                    {
                      'type': 'reasoning.encrypted',
                      'index': 0,
                      'data': 'state',
                    },
                  ],
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'chat-call',
                      'type': 'function',
                      'function': {
                        'name': 'functions__exec',
                        'arguments': '{"input":',
                      },
                    },
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'index': 0,
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '"text(42);"}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          },
          {
            'choices': [],
            'usage': {
              'prompt_tokens': 25,
              'completion_tokens': 7,
              'prompt_tokens_details': {'cached_tokens': 12},
            },
          },
        ], done: true);
      } else {
        await _send(http.response, [
          {
            'choices': [
              {
                'delta': {'content': '42'},
                'finish_reason': 'stop',
              },
            ],
          },
        ], done: true);
      }
    };
    final first = await provider.respond(
      request([ConversationItem.text('user', 'Recall')]),
      cancellation: CancellationToken(),
    );
    expect(first.calls.single.input, 'text(42);');
    expect(first.usage.cachedInputTokens, 12);
    final restored = ModelReply.fromJson(
      jsonObject(jsonDecode(jsonEncode(first.toJson()))),
    );
    await provider.respond(
      request([
        ConversationItem.text('user', 'Recall'),
        ...restored.output,
        ConversationItem.toolResult(restored.calls.single, '42'),
      ]),
      cancellation: CancellationToken(),
    );
    expect(harness.paths, ['/v1/chat/completions', '/v1/chat/completions']);
    expect(harness.headers.first['uses-bearer'], true);
    final assistant = (harness.bodies.last['messages'] as List)
        .map(jsonObject)
        .firstWhere((item) => item['role'] == 'assistant');
    expect(assistant['reasoning_content'], 'Check history');
    expect(assistant['reasoning_details'], [
      {
        'type': 'reasoning.encrypted',
        'index': 0,
        'data': 'opaque-state',
        'signature': 'sig',
      },
    ]);
    expect(assistant['tool_calls'], [
      {
        'id': 'chat-call',
        'type': 'function',
        'function': {
          'name': 'functions__exec',
          'arguments': '{"input":"text(42);"}',
        },
      },
    ]);
  });

  for (final phase in ['headers', 'body']) {
    test(
      'cancellation interrupts pending $phase and leaves the injected pool usable',
      () async {
        final waiting = Completer<void>();
        harness.handler = (http, _) async {
          if (phase == 'body') {
            http.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            http.response.write('data: ${jsonEncode(_start)}\n\n');
            await http.response.flush();
          }
          waiting.complete();
        };
        final cancellation = CancellationToken();
        final future = harness.provider.respond(
          request([ConversationItem.text('user', 'Wait')]),
          cancellation: cancellation,
        );
        final assertion = expectLater(
          future,
          throwsA(isA<CancelledException>()),
        );
        await waiting.future.timeout(const Duration(seconds: 3));
        cancellation.cancel();
        await assertion.timeout(const Duration(seconds: 2));
        harness.handler = (http, _) =>
            _send(http.response, _text('Still usable'));
        final next = await harness.provider.respond(
          request([ConversationItem.text('user', 'Continue')]),
          cancellation: CancellationToken(),
        );
        expect(next.text, 'Still usable');
      },
    );
  }

  test(
    'stream failures and truncation never return or retry partial output',
    () async {
      final cases = <List<Json>>[
        [
          _start,
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': 'partial'},
          },
        ],
        [
          ..._text('partial').take(3),
          {'type': 'message_stop'},
        ],
        [
          ..._text('partial').take(3),
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'max_tokens'},
          },
          {'type': 'message_stop'},
        ],
        [
          _start,
          {
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'try again'},
          },
        ],
      ];
      for (final events in cases) {
        harness.handler = (http, _) => _send(http.response, events);
        final count = harness.bodies.length;
        await expectLater(
          harness.provider.respond(
            request([ConversationItem.text('user', 'Do work')]),
            cancellation: CancellationToken(),
          ),
          throwsA(isA<ModelFailure>()),
        );
        expect(harness.bodies.length, count + 1);
      }
      harness.handler = (http, _) => _send(http.response, [
        {
          'choices': [
            {
              'delta': {'content': 'partial'},
              'finish_reason': 'stop',
            },
          ],
        },
      ]);
      await expectLater(
        harness.chatProvider.respond(
          request([ConversationItem.text('user', 'Do work')]),
          cancellation: CancellationToken(),
        ),
        throwsA(
          isA<ModelFailure>().having(
            (error) => error.code,
            'code',
            'incomplete',
          ),
        ),
      );
    },
  );

  test(
    'context overflow is a stable failure without exposing provider error text',
    () async {
      harness.handler = (http, _) async {
        http.response.statusCode = 400;
        http.response.write(
          jsonEncode({
            'error': {
              'type': 'invalid_request_error',
              'message': 'Maximum context length exceeded. secret-fixture-must-not-escape',
            },
          }),
        );
        await http.response.close();
      };
      await expectLater(
        harness.provider.respond(
          request([ConversationItem.text('user', 'Long')]),
          cancellation: CancellationToken(),
        ),
        throwsA(
          isA<ModelFailure>()
              .having((error) => error.code, 'code', 'context_overflow')
              .having(
                (error) => error.message,
                'message',
                isNot(contains('secret-fixture')),
              ),
        ),
      );
    },
  );

  test('compaction reduces old context and retains a recent complete tool exchange', () async {
    final updates = [
      ConversationItem(
        kind: 'tools',
        tools: const [
          ToolDefinition(
            name: 'lookup',
            namespace: 'history',
            description: 'Look up history.',
            parameters: {'type': 'object'},
          ),
        ],
      ),
      ConversationItem.text(
        'developer',
        'Preserve the requested project constraints.',
      ),
    ];
    const call = ToolCall(
      id: 'old-call',
      name: 'exec',
      namespace: 'functions',
      input: 'text(42);',
    );
    final recent = [
      ConversationItem.text('user', 'Recent task'),
      ConversationItem(role: 'assistant', content: [call.toJson()]),
      ConversationItem.toolResult(call, '42'),
      ConversationItem.text('assistant', 'Recent answer'),
    ];
    final input = [
      ConversationItem.text('user', 'Old objective. ' * 100),
      ConversationItem.text('assistant', 'Old findings. ' * 100),
      ...updates,
      ...recent,
    ];
    harness.handler = (http, _) =>
        _send(http.response, _text('Preserved old objective and findings.'));
    final result = await harness.provider.compact(
      request(input),
      cancellation: CancellationToken(),
    );
    expect(result.summary, 'Preserved old objective and findings.');
    expect(
      result.context.skip(1).map((item) => item.toJson()),
      [...updates, ...recent].map((item) => item.toJson()),
    );
    expect(result.context.first.text, contains(result.summary));
    expect(input.length, 8);
    expect(
      (harness.bodies.single['messages'] as List).toString(),
      isNot(contains('Recent task')),
    );
    expect(harness.bodies.single['tool_choice'], {'type': 'none'});
    await harness.provider.respond(
      request(result.context),
      cancellation: CancellationToken(),
    );
    expect(
      (harness.bodies.last['tools'] as List).last['name'],
      'history__lookup',
    );
    expect(
      (harness.bodies.last['messages'] as List).toString(),
      contains('Preserve the requested project constraints.'),
    );
    harness.handler = (http, _) => _send(http.response, [_start]);
    await expectLater(
      harness.provider.compact(
        request(input),
        cancellation: CancellationToken(),
      ),
      throwsA(isA<ModelFailure>()),
    );
  });

  test('task settings reject effort changes and invalid sampling before network I/O', () async {
    expect(
      () => harness.provider.resolveSettings({
        'reasoning': 'high',
        'temperature': 0.5,
      }),
      throwsArgumentError,
    );
    expect(
      () => harness.provider.resolveSettings({
        'reasoning': 'off',
        'temperature': 0.5,
        'personality': 'pragmatic',
      }),
      returnsNormally,
    );
    expect(
      () => harness.provider.resolveSettings({'api_key': 'must-not-persist'}),
      throwsArgumentError,
    );
    await expectLater(
      harness.provider.respond(
        request([ConversationItem.text('user', 'Hello')], effort: 'max'),
        cancellation: CancellationToken(),
      ),
      throwsArgumentError,
    );
    await expectLater(
      harness.provider.respond(
        request([
          ConversationItem(
            kind: 'configuration',
            settings: {'reasoning': 'max'},
          ),
          ConversationItem.text('user', 'Hello'),
        ]),
        cancellation: CancellationToken(),
      ),
      throwsArgumentError,
    );
    const unresolved = ToolCall(
      id: 'pending',
      name: 'exec',
      namespace: 'functions',
      input: 'text(1)',
    );
    await expectLater(
      harness.provider.respond(
        request([
          ConversationItem(role: 'assistant', content: [unresolved.toJson()]),
        ]),
        cancellation: CancellationToken(),
      ),
      throwsA(isA<ModelFailure>()),
    );
    expect(harness.bodies, isEmpty);
    await harness.provider.respond(
      request(
        [ConversationItem.text('user', 'Hello')],
        settings: {
          'reasoning': 'off',
          'temperature': 0.5,
          'personality': 'pragmatic',
        },
        effort: 'off',
      ),
      cancellation: CancellationToken(),
    );
    expect(harness.bodies.single['thinking'], {'type': 'disabled'});
    expect(harness.bodies.single['temperature'], 0.5);
    expect(harness.bodies.single['system'], contains('Be pragmatic'));
  });
}

const _start = {
  'type': 'message_start',
  'message': {
    'id': 'native-one',
    'usage': {
      'input_tokens': 10,
      'cache_read_input_tokens': 5,
      'cache_creation_input_tokens': 2,
    },
  },
};

List<Json> _text(String text) => [
  _start,
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'text', 'text': text},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
    'usage': {'output_tokens': 2},
  },
  {'type': 'message_stop'},
];

Future<void> _send(
  HttpResponse response,
  List<Json> events, {
  bool fragment = false,
  bool done = false,
}) async {
  response.headers.contentType = ContentType(
    'text',
    'event-stream',
    charset: 'utf-8',
  );
  final bytes = utf8.encode(
    '${events.map((event) => 'data: ${jsonEncode(event)}\r\n\r\n').join()}${done ? 'data: [DONE]\n\n' : ''}',
  );
  if (fragment) {
    for (var i = 0; i < bytes.length; i += 7) {
      response.add(bytes.sublist(i, (i + 7).clamp(0, bytes.length)));
    }
  } else {
    response.add(bytes);
  }
  await response.close();
}

class _Harness {
  _Harness(this.server) {
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    provider = DeepSeekProvider(
      http: http,
      credentials: () async => 'fixture-only',
      endpoint: endpoint,
    );
    chatProvider = DeepSeekProvider(
      http: http,
      credentials: () async => 'fixture-only',
      endpoint: endpoint,
      transport: 'chat',
    );
    server.listen((request) async {
      try {
        final body = jsonObject(
          jsonDecode(await utf8.decoder.bind(request).join()),
        );
        bodies.add(body);
        paths.add(request.uri.path);
        headers.add({
          'anthropic-version': request.headers.value('anthropic-version'),
          'anthropic-beta': request.headers.value('anthropic-beta'),
          'uses-api-key': request.headers.value('x-api-key') == 'fixture-only',
          'uses-bearer':
              request.headers.value(HttpHeaders.authorizationHeader) ==
              'Bearer fixture-only',
        });
        await handler(request, body);
      } catch (_) {
        await request.response.close().catchError((Object _) {});
      }
    });
  }
  static Future<_Harness> open() async =>
      _Harness(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer server;
  final HttpClient http = HttpClient();
  final bodies = <Json>[], headers = <Json>[];
  final paths = <String>[];
  late final DeepSeekProvider provider, chatProvider;
  Future<void> Function(HttpRequest, Json) handler = (request, _) =>
      _send(request.response, _text('Okay'));
  Future<void> close() async {
    http.close(force: true);
    await server.close(force: true);
  }
}
