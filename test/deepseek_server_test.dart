import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  for (final providerId in ['deepseek', 'opencode']) {
  test('$providerId Console backend executes code mode through UDS and reports hosted denials', () async {
    final root = await Directory.systemTemp.createTemp('console-agent-');
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    AgentServer? server;
    AgentClient? client;
    final denialStarted = Completer<void>(), releaseDenial = Completer<void>();
    addTearDown(() async {
      if (!releaseDenial.isCompleted) releaseDenial.complete();
      await client?.close();
      await server?.close();
      await provider.close(force: true);
      await root.delete(recursive: true);
    });
    await File('${root.path}/config.json').writeAsString(
      jsonEncode({
        'default_provider': providerId,
        'providers': {
          providerId: {
            if (providerId == 'deepseek') 'backend': 'opencode',
            'endpoint': 'http://127.0.0.1:${provider.port}/inference/openai/v1',
            'settings': {'reasoning': 'low'},
          },
        },
      }),
    );
    await File('${root.path}/opencode-auth.json').writeAsString(
      jsonEncode({
        'version': 1,
        'type': 'opencode',
        'server': 'https://opencode.ai/console',
        'access_token': 'fixture-access',
        'refresh_token': 'fixture-refresh',
        'org_id': 'fixture-org',
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      }),
    );
    final requests = <Json>[];
    var denied = false;
    provider.listen((request) async {
      final body = jsonObject(
        jsonDecode(await utf8.decoder.bind(request).join()),
      );
      requests.add(body);
      expect(request.uri.path, '/inference/openai/v1/chat/completions');
      expect(request.headers.value('Authorization'), 'Bearer fixture-access');
      expect(request.headers.value('x-org-id'), 'fixture-org');
      expect(body['model'], 'deepseek-v4.1-flash-free');
      expect(body['reasoning_effort'], 'low');
      if (denied) {
        denialStarted.complete();
        await releaseDenial.future;
        request.response.statusCode = 429;
        request.response.write(
          jsonEncode({
            'error': {
              'type': 'FreeUsageLimitError',
              'message': 'fixture-access must not escape',
            },
          }),
        );
      } else {
        final messages = (body['messages'] as List).map(jsonObject).toList();
        final lastUser = messages.lastIndexWhere((message) => message['role'] == 'user');
        final discover = messages[lastUser]['content'] == 'discover';
        final results = messages.skip(lastUser + 1).where((message) => message['role'] == 'tool').length;
        final hasResult = (body['messages'] as List).any(
          (m) => m['role'] == 'tool',
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        final delta = discover && results < 2 ? {
          'tool_calls': [{
            'index': 0, 'id': 'discovery-$results', 'type': 'function',
            'function': {
              'name': results == 0 ? 'tool_search' : 'mcp__archive__probe',
              'arguments': jsonEncode(results == 0
                ? {'query': 'mcp__archive__probe', 'limit': 1} : {'action': 'inspect'}),
            },
          }],
        } : hasResult
            ? {'content': 'Written'}
            : {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call-1',
                    'type': 'function',
                    'function': {
                      'name': 'functions__exec',
                      'arguments': jsonEncode({
                        'input': 'text(await tools.apply_patch("*** Begin Patch\\n*** Add File: verified.txt\\n+42\\n*** End Patch"));',
                      }),
                    },
                  },
                ],
              };
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {'delta': delta, 'finish_reason': delta.containsKey('tool_calls') ? 'tool_calls' : 'stop'},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
      }
      await request.response.close();
    });
    server = await AgentServer.startEmbedded(
      directory: root.path,
      configPath: '${root.path}/config.yaml',
    );
    client = await AgentClient.connect(server.uri);
    Future<Json> turn(String method, Json params) async {
      final completion = client!.events.stream.firstWhere(
        (e) => {
          'turn.completed',
          'turn.failed',
          'turn.cancelled',
        }.contains(e['type']),
      );
      await client.request(method, params);
      return completion.timeout(const Duration(seconds: 15));
    }

    final first = await turn('task.start', {
      'cwd': root.path,
      'prompt': 'Write 42.',
    });
    expect(first['type'], 'turn.completed', reason: first.toString());
    expect(await File('${root.path}/verified.txt').readAsString(), '42\n');
    expect(requests.length, 2);
    final previous = requests.last;
    final continued = await turn('task.send', {
      'task_id': first['task_id'], 'prompt': 'Check the result.',
    });
    expect(continued['type'], 'turn.completed', reason: continued.toString());
    expect(requests.length, 3);
    final messages = requests.last['messages'] as List;
    expect(messages.take((previous['messages'] as List).length).toList(), previous['messages']);
    expect(messages.length, (previous['messages'] as List).length + 2);
    expect(messages.where((message) => message['role'] == 'system'), hasLength(1));
    expect(messages.where((message) => message['role'] == 'tool'), hasLength(1));
    expect(messages.where((message) => message['tool_calls'] != null), hasLength(1));
    expect(requests.last['tools'], requests.first['tools']);
    await File('${root.path}/config.yaml').writeAsString(jsonEncode({
      'mcp_servers': {'archive': {
        'command': Platform.resolvedExecutable,
        'args': [File('test/fixtures/mcp_stdio.dart').absolute.path],
        'env': {'MCP_EXTRA_TOOLS': '120'},
        'legacy_fallback': false,
      }},
    }));
    final beforeDiscovery = requests.length;
    final discovered = await turn('task.send', {'task_id': first['task_id'], 'prompt': 'discover'});
    expect(discovered['type'], 'turn.completed', reason: discovered.toString());
    expect(requests.length, beforeDiscovery + 3);
    expect(jsonEncode(requests[beforeDiscovery]), isNot(contains('unused_schema_')));
    expect((requests[beforeDiscovery]['tools'] as List).where((tool) =>
      (tool['function']['name'] as String).startsWith('mcp__'),
    ), isEmpty);
    final loaded = (requests.last['tools'] as List).where((tool) =>
      (tool['function']['name'] as String).startsWith('mcp__'),
    ).toList();
    expect(loaded, hasLength(1));
    expect(loaded.single['function']['name'], 'mcp__archive__probe');
    final probe = (requests.last['messages'] as List).lastWhere((message) => message['role'] == 'tool');
    expect(jsonDecode(jsonDecode(probe['content'] as String)['output']['content'][0]['text'])['pid'], isPositive);
    final beforeDenial = requests.length;
    denied = true;
    final failure = turn('task.send', {
      'task_id': first['task_id'],
      'prompt': 'Continue.',
    });
    await denialStarted.future.timeout(const Duration(seconds: 15));
    await expectLater(client.request('task.send', {
      'task_id': first['task_id'], 'prompt': 'Change effort', 'reasoning': 'high', 'delivery': 'steer',
    }), throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Reasoning effort is fixed for this task'))));
    expect(jsonObject(await client.request('task.subscribe', {'task_id': first['task_id']}))['pending'], isEmpty);
    releaseDenial.complete();
    final failed = await failure;
    expect(failed['type'], 'turn.failed');
    expect(failed['data']['error'], contains('free_usage_limit'));
    expect(requests.length, beforeDenial + 1);
    final history = await client.request('history.page', {
      'task_id': first['task_id'],
    });
    expect(jsonEncode(history), isNot(contains('fixture-access')));
    expect(jsonEncode(history), isNot(contains('fixture-refresh')));
    await client.request('auth.logout', {'provider': 'opencode'});
    final catalog = jsonObject(await client.request('providers.list'));
    expect((catalog['providers'] as List).singleWhere((provider) => provider['id'] == 'opencode')['status'], 'signed_out');
    expect(await File('${root.path}/opencode-auth.json').exists(), isFalse);
  });
  }
}
