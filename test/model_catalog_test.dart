import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

import 'support/thread.dart';
import 'support/thread_names.dart';

// Codex models-manager: remote metadata wins, an authenticated catalog cache is
// reusable offline, and saved threads retain their own resolved model contract.
void main() {
  test('all supported GPT models use discovered metadata and retain their thread snapshots', () async {
    final root = await Directory.systemTemp.createTemp('model-catalog-');
    final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = 'http://127.0.0.1:${remote.port}/backend-api/codex/responses';
    var revision = 'A', offline = false, catalogReads = 0;
    var account = 'fixture-account';
    final requests = <Json>[];
    final bundled = (jsonDecode(await File('packages/openai/catalog/models.json').readAsString()) as Map)['models'] as List;
    remote.listen((request) async {
      if (request.method == 'GET') {
        catalogReads++;
        expect(request.uri.path, '/backend-api/codex/models');
        expect(request.uri.queryParameters['client_version'], isNotEmpty);
        expect(request.headers.value('authorization'), 'Bearer fixture-access');
        expect(request.headers.value('chatgpt-account-id'), account);
        request.response.headers.contentType = ContentType.json;
        if (offline) { request.response.statusCode = 503; }
        else {
          request.response.headers.set('etag', 'catalog-$revision');
          request.response.write(jsonEncode({'models': [for (final raw in bundled)
            if (supportedGptModels.contains(raw['slug'])) {
              ...raw as Map, 'default_reasoning_level': 'high', 'context_window': 333000,
              'supports_reasoning_effort_updates': revision == 'A',
              'model_messages': {...raw['model_messages'] as Map,
                'instructions_template': 'CATALOG_$revision:${raw['slug']}\n${raw['model_messages']['instructions_template']}'},
            },
          ]}));
        }
        await request.response.close();
        return;
      }
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      if (await respondToThreadName(request, body)) return;
      requests.add(body);
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
        'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
          'content': [{'type': 'output_text', 'text': 'Ready'}]}],
      }})}\n\n');
      await request.response.close();
    });
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture-access', 'refresh_token': 'fixture-refresh',
      'account_id': 'fixture-account', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    Future<AgentServer> launch() => AgentServer.startEmbedded(directory: root.path,
      configPath: '${root.path}/config.yaml', endpoint: endpoint, skillsHome: root.path);
    var server = await launch();
    var client = await AgentClient.connect(server.uri);
    addTearDown(() async { await client.close(); await server.close(); await remote.close(force: true); await root.delete(recursive: true); });
    final models = jsonObject(await client.request('providers.list'))['providers'][0]['models'] as List;
    expect(catalogReads, 1, reason: 'The provider discovers the current catalog instead of forcing bundled metadata');
    expect(models.map((model) => model['id']).toSet(), supportedGptModels);
    expect(models.map((model) => model['reasoning_updates']), everyElement(isTrue));
    final threads = <String, String>{};
    for (final model in supportedGptModels) {
      final page = jsonObject(await client.request('thread/start', {'cwd': root.path, 'model': model}));
      final id = page['thread']['id'] as String;
      threads[model] = id;
      expect(page['configuration']['provider_settings']['reasoning'], 'high');
      expect(page['configuration']['context_window'], 316350);
      expect((await runTurn(client, id, prompt: 'First'))['status'], 'completed');
      expect(jsonEncode(requests.last['input']), contains('CATALOG_A:$model'));
      expect(requests.last['reasoning']['effort'], 'high');
    }
    await client.close(); await server.close();
    offline = true;
    server = await launch(); client = await AgentClient.connect(server.uri);
    final cached = jsonObject(await client.request('providers.list'))['providers'][0]['models'] as List;
    expect(cached.map((model) => model['default_reasoning']), everyElement('high'));
    expect(catalogReads, 1, reason: 'Fresh cached model metadata remains available without another network request');
    await client.close(); await server.close();
    final cache = File('${root.path}/models_cache.json');
    final saved = jsonObject(jsonDecode(await cache.readAsString()));
    saved['fetched_at'] = '2000-01-01T00:00:00Z';
    await cache.writeAsString(jsonEncode(saved));
    offline = false; revision = 'B';
    server = await launch(); client = await AgentClient.connect(server.uri);
    final refreshed = jsonObject(await client.request('providers.list'))['providers'][0]['models'] as List;
    expect(refreshed.map((model) => model['reasoning_updates']), everyElement(isFalse));
    for (final entry in threads.entries) {
      expect((await runTurn(client, entry.value, prompt: 'Continue', settings: {'effort': 'low'}))['status'], 'completed');
      expect(jsonEncode(requests.last['input']), contains('CATALOG_A:${entry.key}'));
      expect(jsonEncode(requests.last['input']), isNot(contains('CATALOG_B:')));
      expect(requests.last['reasoning']['effort'], 'high', reason: 'The original request baseline stays frozen');
      expect(jsonEncode(requests.last['input']), contains('configuration_update'));
    }
    final fresh = await createThread(client, {'cwd': root.path, 'model': 'gpt-6-luna'});
    expect((await runTurn(client, fresh, prompt: 'New'))['status'], 'completed');
    expect(jsonEncode(requests.last['input']), contains('CATALOG_B:gpt-6-luna'));
    await client.close(); await server.close();
    // An expired cache remains useful offline, but belongs to its account.
    final expired = jsonObject(jsonDecode(await cache.readAsString()))..['fetched_at'] = '2000-01-01T00:00:00Z';
    await cache.writeAsString(jsonEncode(expired));
    offline = true;
    server = await launch(); client = await AgentClient.connect(server.uri);
    final offlineThread = await createThread(client, {'cwd': root.path, 'model': 'gpt-6-luna'});
    expect((await runTurn(client, offlineThread, prompt: 'Offline'))['status'], 'completed');
    expect(jsonEncode(requests.last['input']), contains('CATALOG_B:gpt-6-luna'));
    await client.close(); await server.close();
    account = 'different-account';
    final credentials = jsonObject(jsonDecode(await File('${root.path}/auth.json').readAsString()))..['account_id'] = account;
    await File('${root.path}/auth.json').writeAsString(jsonEncode(credentials));
    server = await launch(); client = await AgentClient.connect(server.uri);
    final different = await createThread(client, {'cwd': root.path, 'model': 'gpt-6-luna'});
    expect((await runTurn(client, different, prompt: 'Different account'))['status'], 'completed');
    expect(jsonEncode(requests.last['input']), isNot(contains('CATALOG_')), reason: 'An unavailable catalog cannot reuse another account\'s metadata');
  });
}
