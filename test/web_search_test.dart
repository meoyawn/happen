import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:crypto/crypto.dart';
import 'package:deepseek/deepseek.dart';
import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

// Codex 2681f8c, literature_search_web_run_schema.snap without its optional
// literature extension. Hash sorted JSON independently of wire property order.
const _codexWebSchemaHash = 'de3be87e7abfe9b67ba757f27804d4206b51c2a8de9e9799fa7db9ef4abe3539';

String _schemaHash(Object? schema) {
  Object? ordered(Object? value) {
    if (value is Map) {
      return SplayTreeMap<String, Object?>.from(
        value.map((key, item) => MapEntry(key as String, ordered(item))),
      );
    }
    if (value is List) return value.map(ordered).toList();
    return value;
  }
  return sha256.convert(utf8.encode(jsonEncode(ordered(schema)))).toString();
}

void main() {
  for (final lab in ['gpt', 'opencode']) {
    test('$lab executes shared web.run directly and in code mode, preserving results after restart', () async {
      final root = await Directory.systemTemp.createTemp('web-search-task-');
      final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final endpoint = 'http://127.0.0.1:${remote.port}';
      final sourceUrl = lab == 'gpt' ? 'https://dart.dev/docs' : '$endpoint/docs';
      final domain = Uri.parse(sourceUrl).host;
      final config = File('${root.path}/config.yaml');
      final modelRequests = <Json>[], searchRequests = <Json>[];
      final searches = <String>[];
      await config.writeAsString(jsonEncode({'providers': {
        'gpt': {'endpoint': '$endpoint/codex/responses'},
        'opencode': {
          'endpoint': '$endpoint/inference/openai/v1',
          'web_search': {'endpoint': '$endpoint/hosted/search'},
        },
      }}));
      await File('${root.path}/auth.json').writeAsString(jsonEncode({
        'type': 'chatgpt', 'access_token': 'fixture-access',
        'refresh_token': 'fixture-refresh', 'account_id': 'fixture-account',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }));
      await File('${root.path}/opencode-auth.json').writeAsString(jsonEncode({
        'version': 1, 'type': 'opencode', 'server': 'https://opencode.ai/console',
        'access_token': 'fixture-console', 'refresh_token': 'fixture-refresh', 'org_id': 'fixture-org',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }));
      remote.listen((request) async {
        if (request.method == 'GET') {
          expect(request.uri.path, '/docs');
          expect(request.headers.value('Authorization'), isNull);
          expect(request.headers.value('x-org-id'), isNull);
          request.response.headers.contentType = ContentType.html;
          request.response.write('<html><script>not-model-content</script><body><nav>excluded navigation</nav>'
              '<main><h1>Dart guide</h1><p>Cancel requests with their owner.</p><a href="/follow">More</a></main></body></html>');
          await request.response.close();
          return;
        }
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        if (request.uri.path == '/codex/alpha/search' || request.uri.path == '/hosted/search') {
          searchRequests.add(body);
          searches.add(request.uri.path);
          if (lab == 'gpt') {
            expect(request.headers.value('Authorization'), 'Bearer fixture-access');
            expect(request.headers.value('chatgpt-account-id'), 'fixture-account');
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'output': body['commands']['search_query'] != null
                ? '## [Dart guide](https://dart.dev/docs)\nSearch evidence'
                : 'Source: https://dart.dev/docs\nL1: Cancel requests with their owner.'}));
          } else {
            expect(request.headers.value('Authorization'), 'Bearer fixture-console');
            expect(request.headers.value('x-org-id'), 'fixture-org');
            expect(body['providerID'], 'opencode');
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'providerID': 'opencode', 'results': [
              {'url': sourceUrl, 'title': 'Dart guide', 'content': 'Search evidence',
                'time': {'published': DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch}},
              {'url': 'https://other.example/docs', 'content': 'excluded-domain', 'time': {}},
              {'url': sourceUrl, 'content': 'excluded-old', 'time': {'published': 0}},
            ]}));
          }
          await request.response.close();
          return;
        }
        modelRequests.add(body);
        final web = (body['tools'] as List).singleWhere((tool) => lab == 'gpt'
            ? tool['name'] == 'web' : tool['function']['name'] == 'web__run');
        final parameters = lab == 'gpt' ? web['tools'][0]['parameters'] : web['function']['parameters'];
        if (_schemaHash(parameters) != _codexWebSchemaHash) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': {
            'message': "Function 'web.run' is reserved for use by this model and must match the configured schema.",
            'type': 'invalid_request_error', 'param': 'tools', 'code': null,
          }}));
          await request.response.close();
          return;
        }
        final input = (body[lab == 'gpt' ? 'input' : 'messages'] as List).map(jsonObject).toList();
        final lastUser = input.lastIndexWhere((item) => item['role'] == 'user');
        final resumed = input[lastUser]['content'] == 'Continue';
        final results = input.skip(lastUser + 1).where((item) => lab == 'gpt'
            ? {'function_call_output', 'custom_tool_call_output'}.contains(item['type'])
            : item['role'] == 'tool').toList();
        final arguments = results.isEmpty ? jsonEncode({
          'search_query': [{'q': 'Dart guide', 'recency': 7, 'domains': [domain]}],
          'response_length': 'short',
        }) : 'text(await tools.web__run({open:[{ref_id:${jsonEncode(sourceUrl)},lineno:1}],'
            'find:[{ref_id:${jsonEncode(sourceUrl)},pattern:"cancel"}],response_length:"short"}));';
        final finished = resumed || results.length >= 2;
        if (finished) {
          expect(jsonEncode(input), contains('Search evidence'));
          expect(jsonEncode(input), contains('Cancel requests with their owner.'));
        }
        request.response.headers.contentType = ContentType('text', 'event-stream');
        if (lab == 'gpt') {
          expect(web['tools'][0]['name'], 'run');
          request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
            'status': 'completed', 'usage': {'input_tokens': 100, 'output_tokens': 10},
            'output': [finished ? {
              'type': 'message', 'role': 'assistant',
              'content': [{'type': 'output_text', 'text': 'Verified source links and page content'}],
            } : {
              'type': results.isEmpty ? 'function_call' : 'custom_tool_call',
              'namespace': results.isEmpty ? 'web' : 'functions',
              'name': results.isEmpty ? 'run' : 'exec',
              'call_id': 'call-${modelRequests.length}',
              results.isEmpty ? 'arguments' : 'input': arguments,
            }],
          }})}\n\n');
        } else {
          request.response.write('data: ${jsonEncode({'choices': [{
            'delta': finished ? {'content': 'Verified source links and page content'} : {
              'tool_calls': [{'index': 0, 'id': 'call-${modelRequests.length}', 'type': 'function', 'function': {
                'name': results.isEmpty ? 'web__run' : 'functions__exec',
                'arguments': results.isEmpty ? arguments : jsonEncode({'input': arguments}),
              }}],
            },
            'finish_reason': finished ? 'stop' : 'tool_calls',
          }]})}\n\ndata: [DONE]\n\n');
        }
        await request.response.close();
      });
      var server = await AgentServer.startEmbedded(directory: root.path, configPath: config.path);
      var client = await AgentClient.connect(server.uri);
      addTearDown(() async {
        await client.close();
        await server.close();
        await remote.close(force: true);
        await root.delete(recursive: true);
      });
      Future<Json> turn(String method, Json params) async {
        final terminal = client.events.stream.firstWhere((event) =>
          ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']));
        await client.request(method, params);
        final result = await terminal.timeout(const Duration(seconds: 15));
        expect(result['type'], 'turn.completed', reason: result.toString());
        return result;
      }
      final first = await turn('task.start', {'provider': lab, 'cwd': root.path, 'prompt': 'Research'});
      expect(modelRequests, hasLength(3));
      expect(searches, everyElement(lab == 'gpt' ? '/codex/alpha/search' : '/hosted/search'));
      if (lab == 'gpt') {
        expect(searchRequests, hasLength(2));
        expect(searchRequests.first['id'], first['task_id']);
        expect(searchRequests.first['settings']['external_web_access'], isTrue);
        expect(searchRequests.first['commands']['search_query'][0]['domains'], ['dart.dev']);
      } else {
        expect(searchRequests, hasLength(1));
        expect(searchRequests.first['query'], contains('site:$domain'));
        expect(searchRequests.first['query'], contains('after:'));
      }
      await client.close();
      await server.close();
      server = await AgentServer.startEmbedded(directory: root.path, configPath: config.path);
      client = await AgentClient.connect(server.uri);
      await turn('task.send', {'task_id': first['task_id'], 'prompt': 'Continue'});
      expect(modelRequests, hasLength(4));
      final history = jsonEncode(await client.request('history.page', {'task_id': first['task_id'], 'limit': 100}));
      expect(history, contains(sourceUrl));
      expect(history, isNot(contains('fixture-access')));
      expect(history, isNot(contains('not-model-content')));
      expect(history, isNot(contains('excluded-domain')));
      expect(history, isNot(contains('excluded-old')));
      expect(history, isNot(contains('excluded navigation')));
    });
  }

  for (final lab in ['gpt', 'deepseek']) {
    test('$lab search cancels owned I/O, bounds replies, and sanitizes errors without losing the pool', () async {
      final root = await Directory.systemTemp.createTemp('web-search-auth-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final http = HttpClient();
      final auth = OpenCodeAuthManager(root.path, http: http);
      await File('${root.path}/opencode-auth.json').writeAsString(jsonEncode({
        'version': 1, 'type': 'opencode', 'server': 'https://opencode.ai/console',
        'access_token': 'fixture-secret', 'refresh_token': 'fixture-refresh', 'org_id': 'fixture-org',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }));
      final waiting = Completer<void>(), release = Completer<void>();
      final refreshes = <bool>[];
      final bodies = <Json>[];
      var mode = 'refresh', attempts = 0;
      server.listen((request) async {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        if (lab == 'deepseek') {
          expect(request.headers.value('Authorization'), 'Bearer fixture-secret');
          expect(request.headers.value('x-org-id'), 'fixture-org');
        }
        bodies.add(body);
        attempts++;
        request.response.headers.contentType = ContentType.json;
        try {
          if (mode == 'refresh' && lab == 'gpt' && attempts == 1) {
            request.response.statusCode = 401;
            request.response.write('{"error":"fixture-secret"}');
          } else if (mode == 'wait') {
            request.response.write('{');
            await request.response.flush();
            waiting.complete();
            await release.future;
          } else if (mode == 'oversize') {
            request.response.write('{"output":"${'x' * (2 * 1024 * 1024)}"}');
          } else if (mode == 'malformed') {
            request.response.write('fixture-secret invalid JSON');
          } else if (mode == 'error') {
            request.response.statusCode = 429;
            request.response.write('{"error":"fixture-secret"}');
          } else {
            request.response.write(jsonEncode(lab == 'gpt' ? {'output': 'usable pool'} : {
              'providerID': 'opencode', 'results': [{
                'url': 'https://dart.dev', 'title': 'usable pool', 'content': 'usable pool', 'time': {},
              }],
            }));
          }
          await request.response.close();
        } catch (_) {
          // A cancelled/oversized response can close before the fixture finishes.
        }
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        auth.close();
        http.close(force: true);
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final ModelProvider provider = lab == 'gpt' ? GptProvider(ResponsesClient(
        http: http, endpoint: Uri.parse('http://127.0.0.1:${server.port}/responses'),
        credentials: ({bool refresh = false}) async {
          refreshes.add(refresh);
          return {'access_token': 'fixture-secret', 'account_id': 'fixture'};
        },
      )) : DeepSeekProvider(
        http: http, credentials: () async => 'unused-model-key',
        searchAuth: auth,
        openCodeSearchEndpoint: Uri.parse('http://127.0.0.1:${server.port}/hosted/search'),
      );
      final model = lab == 'gpt' ? 'gpt-6.1-sol' : 'deepseek-flash';
      final request = ModelRequest(
        taskId: 'task', model: model, instructions: 'fixture',
        input: [
          ConversationItem.text('user', 'old user'),
          ConversationItem.text('assistant', 'old answer'),
          ConversationItem.text('user', 'previous user'),
          ConversationItem.text('assistant', 'a' * 5000),
          ConversationItem.text('developer', 'private instructions'),
          ConversationItem.text('user', 'current user'),
          ConversationItem.text('assistant', 'current commentary'),
        ],
        tools: [webSearchDefinition], settings: provider.resolveSettings({'reasoning': 'low'}, model: model),
        effectiveReasoning: 'low',
      );
      Future<String> search(CancellationToken token) => provider.webSearch(request, {
        'search_query': [{'q': 'query'}],
      }, cancellation: token);
      expect(await search(CancellationToken()), contains('usable pool'));
      if (lab == 'gpt') {
        expect(refreshes, [false, true]);
        final context = jsonEncode(bodies.last['input']);
        expect(context, contains('previous user'));
        expect(context, contains('current user'));
        expect(context, isNot(contains('old user')));
        expect(context, isNot(contains('private instructions')));
        expect(context, isNot(contains('current commentary')));
        expect((bodies.last['input'][1]['content'][0]['text'] as String).length, 4000);
      }
      const specialized = {
        'finance': [{'ticker': 'BTC', 'type': 'crypto', 'market': ''}],
        'weather': [{'location': 'Paris, France', 'duration': 3}],
        'time': [{'utc_offset': '+03:00'}],
      };
      final beforeSpecialized = bodies.length;
      if (lab == 'gpt') {
        expect(await provider.webSearch(request, specialized, cancellation: CancellationToken()), contains('usable pool'));
        expect(bodies.last['commands'], specialized);
        expect(bodies, hasLength(beforeSpecialized + 1));
      } else {
        await expectLater(() => provider.webSearch(request, specialized, cancellation: CancellationToken()),
          throwsA(isA<ModelFailure>().having((error) => error.code, 'code', 'web_search_unsupported')));
        expect(bodies, hasLength(beforeSpecialized));
      }
      final beforeInvalid = bodies.length;
      await expectLater(() => provider.webSearch(request, {
        'finance': [{'ticker': 'AMD', 'type': 'invalid'}],
      }, cancellation: CancellationToken()), throwsFormatException);
      expect(bodies, hasLength(beforeInvalid));
      mode = 'wait';
      final token = CancellationToken();
      final cancelled = expectLater(search(token), throwsA(isA<CancelledException>()));
      await waiting.future.timeout(const Duration(seconds: 5));
      token.cancel();
      await cancelled.timeout(const Duration(seconds: 2));
      final beforeCancelled = bodies.length;
      await expectLater(search(token), throwsA(isA<CancelledException>()));
      expect(bodies, hasLength(beforeCancelled));
      for (final failure in ['error', 'malformed', 'oversize']) {
        mode = failure;
        await expectLater(search(CancellationToken()), throwsA(isA<ModelFailure>().having(
          (error) => error.toString(), 'sanitized error', isNot(contains('fixture-secret')),
        )));
      }
      mode = 'success';
      expect(await search(CancellationToken()), contains('usable pool'));
    });
  }
}
