import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:opencode/src/instructions.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
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
    final sessions = <String?>[];
    final resetAt = HttpDate.format(DateTime.now().add(const Duration(hours: 1)));
    var denied = false;
    provider.listen((request) async {
      final body = jsonObject(
        jsonDecode(await utf8.decoder.bind(request).join()),
      );
      requests.add(body);
      expect(request.uri.path, '/inference/openai/v1/chat/completions');
      expect(request.headers.value('Authorization'), 'Bearer fixture-access');
      expect(request.headers.value('x-opencode-org-id'), 'fixture-org');
      expect(request.headers.value('x-org-id'), isNull);
      expect(request.headers.value('x-opencode-client'), 'cli');
      expect(request.headers.value('User-Agent'), 'opencode/latest/2.2.5/cli');
      sessions.add(request.headers.value('x-opencode-session'));
      expect(body['model'], 'deepseek-v4.1-flash-free');
      expect(body['reasoning_effort'], 'low');
      final messages = (body['messages'] as List).map(jsonObject).toList();
      final lastUser = messages.lastIndexWhere((message) => message['role'] == 'user');
      final results = messages.skip(lastUser + 1).where((message) => message['role'] == 'tool').length;
      if (denied && results > 0) {
        denialStarted.complete();
        await releaseDenial.future;
        request.response.statusCode = 429;
        request.response.headers.set(HttpHeaders.retryAfterHeader, resetAt);
        request.response.write(
          jsonEncode({
            'error': {
              'type': 'FreeUsageLimitError',
              'message': 'fixture-access must not escape',
            },
          }),
        );
      } else {
        final discover = messages[lastUser]['content'] == 'discover';
        final hasResult = (body['messages'] as List).any(
          (m) => m['role'] == 'tool',
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        final delta = denied ? {
          'tool_calls': [{
            'index': 0, 'id': 'quota-call', 'type': 'function',
            'function': {
              'name': 'execute',
              'arguments': jsonEncode({'code': 'return await tools.archive.probe({action: "inspect"});'}),
            },
          }],
        } : discover && results < 2 ? {
          'tool_calls': [{
            'index': 0, 'id': 'discovery-$results', 'type': 'function',
            'function': {
              'name': 'execute',
              'arguments': jsonEncode({'code': results == 0
                ? 'return await search({query: "probe", namespace: "archive", limit: 1});'
                : 'return await tools.archive.probe({action: "inspect"});'}),
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
                      'name': 'patch',
                      'arguments': jsonEncode({
                        'patchText': '*** Begin Patch\n*** Add File: verified.txt\n+42\n*** End Patch',
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
    expect(first['task_id'], matches(r'^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$'));
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
    final systems = messages.where((message) => message['role'] == 'system').toList();
    expect(systems, hasLength(3));
    expect(systems.first['content'], openCodeInstructions);
    expect(systems[1]['content'], contains('Here is some useful information about the environment you are running in:'));
    expect(systems[2]['content'], startsWith('# Code Mode\n'));
    expect(messages.where((message) => message['role'] == 'tool'), hasLength(1));
    expect(messages.where((message) => message['tool_calls'] != null), hasLength(1));
    expect(requests.last['tools'], requests.first['tools']);
    final fork = jsonObject(await client.request('task.fork', {'task_id': first['task_id']}));
    expect(fork['task_id'], matches(r'^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$'));
    final bundle = '${root.path}/opencode-task.jsonl';
    await client.request('history.export', {'task_id': fork['task_id'], 'path': bundle});
    final operationId = newId();
    final imports = await Future.wait(List.generate(3, (_) => client!.request('history.import', {
      'path': bundle, 'operation_id': operationId,
    })));
    final imported = jsonObject(imports.first);
    expect(imports, everyElement(imported));
    expect(imported['task_id'], matches(r'^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$'));
    expect(imported['task_id'], isNot(operationId));
    expect((await client.request('history.page', {'task_id': imported['task_id']}) as List).last['type'], 'task.imported');
    await File('${root.path}/config.yaml').writeAsString(jsonEncode({
      ...jsonObject(jsonDecode(await File('${root.path}/config.json').readAsString())),
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
    expect(jsonEncode(requests[beforeDiscovery]['tools']), isNot(contains('unused_schema_')));
    expect(jsonEncode(requests[beforeDiscovery]['messages']), contains('The catalog is partial.'));
    expect((requests[beforeDiscovery]['tools'] as List).where((tool) =>
      (tool['function']['name'] as String).startsWith('mcp__'),
    ), isEmpty);
    final loaded = (requests.last['tools'] as List).where((tool) =>
      (tool['function']['name'] as String).startsWith('mcp__'),
    ).toList();
    expect(loaded, isEmpty, reason: 'OpenCode tools stay in Code Mode instead of loading native schemas');
    final probe = (requests.last['messages'] as List).lastWhere((message) => message['role'] == 'tool');
    expect(jsonDecode(probe['content'] as String)['pid'], isPositive);
    String? legacyId;
    if (providerId == 'opencode') {
      final history = await client.request('history.page', {'task_id': first['task_id'], 'limit': 500}) as List;
      final legacyConfig = jsonObject(history.firstWhere((event) => event['type'] == 'task.created')['data'])
        ..remove('tool_interface');
      legacyConfig['instructions'] = 'Obsolete shared Codex instructions.';
      legacyConfig['tools'] = [const ToolDefinition(name: 'exec', namespace: 'functions', format: 'text', description: 'Earlier shared tool').toJson()];
      legacyId = newId();
      final store = TaskStore(root.path, legacyId);
      final call = ToolCall(id: 'legacy-call', name: 'exec', namespace: 'functions', format: 'text',
        input: 'text("Earlier work")', native: {'wire_name': 'functions__exec'});
      try {
        store.append('task.created', legacyConfig, metadata: {'config': legacyConfig, 'status': 'idle'});
        store.append('input.committed', {'item': ConversationItem.text('user', 'Earlier question').toJson()});
        store.append('model.completed', ModelReply([ConversationItem(role: 'assistant', content: [call.toJson()])], const ModelUsage()).toJson());
        store.append('tool.completed', {'item': ConversationItem.toolResult(call, 'Earlier work').toJson()});
        store.append('model.completed', ModelReply([ConversationItem.text('assistant', 'Earlier answer')], const ModelUsage()).toJson());
      } finally { store.close(); }
      await client.close();
      await server.close();
      server = await AgentServer.startEmbedded(directory: root.path, configPath: '${root.path}/config.yaml');
      client = await AgentClient.connect(server.uri);
      expect(await client.request('history.import', {'path': bundle, 'operation_id': operationId}), imported);
      for (var pass = 0; pass < 2; pass++) {
        if (pass > 0) {
          final compacted = await turn('task.compact', {'task_id': legacyId});
          expect(compacted['type'], 'turn.completed', reason: compacted.toString());
        }
        final resumed = await turn('task.send', {'task_id': legacyId, 'prompt': 'discover'});
        expect(resumed['type'], 'turn.completed', reason: resumed.toString());
        final body = requests.last;
        expect((body['messages'] as List).first['content'], startsWith(openCodeInstructions));
        expect((body['tools'] as List).map((tool) => tool['function']['name']), contains('execute'));
        expect((body['tools'] as List).map((tool) => tool['function']['name']), isNot(contains('functions__exec')));
        expect(jsonEncode(body['tools']), isNot(contains('unused_schema_')));
        expect(jsonEncode(body['messages']), contains('The catalog is partial.'));
        expect(jsonEncode(body), isNot(contains('Obsolete shared Codex instructions.')));
        final result = (body['messages'] as List).lastWhere((message) => message['role'] == 'tool');
        expect(jsonDecode(result['content'] as String)['pid'], isPositive);
      }
    }
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
    expect(failed['data']['error'], contains(resetAt));
    expect(requests.length, beforeDenial + 2, reason: 'One model call runs the tool; its follow-up reports quota without retries');
    expect(sessions.where((session) => session != legacyId), everyElement(first['task_id']));
    final history = await client.request('history.page', {
      'task_id': first['task_id'],
    }) as List;
    final savedResult = (requests.last['messages'] as List).lastWhere((message) => message['role'] == 'tool');
    expect(savedResult['tool_call_id'], 'quota-call');
    expect(jsonDecode(savedResult['content'] as String)['pid'], isPositive);
    final hostCalls = history.where((event) => event['type'] == 'host_tool.started').length;
    denied = false;
    final resumed = await turn('task.send', {'task_id': first['task_id'], 'prompt': 'Continue from the saved result.'});
    expect(resumed['type'], 'turn.completed', reason: resumed.toString());
    expect(requests.length, beforeDenial + 3);
    expect((requests.last['messages'] as List).lastWhere((message) => message['role'] == 'tool'), savedResult);
    final resumedHistory = await client.request('history.page', {'task_id': first['task_id']}) as List;
    expect(resumedHistory.where((event) => event['type'] == 'host_tool.started'), hasLength(hostCalls),
      reason: 'Resuming a quota-interrupted turn must reuse the durable MCP result');
    expect(jsonEncode(history), isNot(contains('fixture-access')));
    expect(jsonEncode(history), isNot(contains('fixture-refresh')));
    await client.request('auth.logout', {'provider': 'opencode'});
    final catalog = jsonObject(await client.request('providers.list'));
    expect((catalog['providers'] as List).singleWhere((provider) => provider['id'] == 'opencode')['status'], 'signed_out');
    expect(await File('${root.path}/opencode-auth.json').exists(), isFalse);
  });
  }
}
