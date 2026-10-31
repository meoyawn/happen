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
    addTearDown(() async {
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
        final hasResult = (body['messages'] as List).any(
          (m) => m['role'] == 'tool',
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        final delta = hasResult
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
              {'delta': delta, 'finish_reason': hasResult ? 'stop' : 'tool_calls'},
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
    denied = true;
    final failed = await turn('task.send', {
      'task_id': first['task_id'],
      'prompt': 'Continue.',
    });
    expect(failed['type'], 'turn.failed');
    expect(failed['data']['error'], contains('free_usage_limit'));
    expect(requests.length, 3);
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
