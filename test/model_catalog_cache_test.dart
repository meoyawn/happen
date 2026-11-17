import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

// Codex models-manager/{manager_tests,cache_identity_tests}.rs and
// core/tests/suite/models_cache_ttl.rs, exercised through real HTTP and files.
void main() {
  for (final miss in ['fresh', 'expired', 'missing version', 'wrong version', 'missing identity', 'wrong identity', 'corrupt']) {
    test('catalog cache eligibility: $miss', () async {
      var reads = 0;
      final fixture = await _fixture((request) async {
        await _reply(request, [_model(++reads == 1 ? 'old' : 'current')]);
      });
      await fixture.catalog.refresh(fixture.lifetime);
      final saved = jsonObject(jsonDecode(await fixture.cache.readAsString()));
      switch (miss) {
        case 'expired': saved['fetched_at'] = '2000-01-01T00:00:00Z';
        case 'missing version': saved.remove('client_version');
        case 'wrong version': saved['client_version'] = 'other-version';
        case 'missing identity': saved.remove('identity');
        case 'wrong identity': saved['identity'] = 'other-provider-or-account';
      }
      await fixture.cache.writeAsString(miss == 'corrupt' ? '{' : jsonEncode(saved));
      final restarted = fixture.restart();
      await restarted.refresh(fixture.lifetime, strategy: CatalogRefresh.offline);
      expect(reads, 1, reason: 'Offline never fetches');
      expect(restarted.available('old'), miss == 'fresh');
      await restarted.refresh(fixture.lifetime);
      expect(restarted.defaultModel, miss == 'fresh' ? 'old' : 'current');
      expect(reads, miss == 'fresh' ? 1 : 2);
      final stored = jsonObject(jsonDecode(await fixture.cache.readAsString()));
      expect(stored['client_version'], gptCatalogClientVersion);
      expect(stored['identity'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(await fixture.cache.readAsString(), isNot(contains('fixture-access')));
    });
  }

  test('online refresh replaces removed models and updates metadata with an unchanged ETag', () async {
    var reads = 0;
    final fixture = await _fixture((request) async {
      expect(request.headers.value('if-none-match'), isNull);
      await _reply(request, ++reads == 1 ? [_model('removed')] : [
        _model('second', priority: 2), _model('hidden', visibility: 'hide'),
        {..._model('first', priority: 1), 'supported_in_api': false, 'context_window': 500000},
      ], etag: 'unchanged');
    });
    await fixture.catalog.refresh(fixture.lifetime);
    await fixture.catalog.refresh(fixture.lifetime, strategy: CatalogRefresh.online);
    expect(reads, 2);
    expect(fixture.catalog.models.map((model) => model.id), ['first', 'second']);
    expect(fixture.catalog.defaultModel, 'first');
    expect(fixture.catalog.available('removed'), isFalse);
    expect(fixture.catalog.model('first').contextWindow, 500000);
    expect(fixture.catalog.model('hidden').instructions, 'Instructions for hidden');
    final restarted = fixture.restart();
    await restarted.refresh(fixture.lifetime);
    expect(reads, 2);
    expect(restarted.model('first').contextWindow, 500000);
  });

  for (final hiddenOnly in [false, true]) {
    test('${hiddenOnly ? 'hidden-only' : 'empty'} catalog keeps the bundled picker and is cached', () async {
      var reads = 0;
      final fixture = await _fixture((request) async {
        reads++;
        await _reply(request, [if (hiddenOnly) _model('hidden', visibility: 'hide')]);
      });
      await fixture.catalog.refresh(fixture.lifetime);
      final restarted = fixture.restart();
      await restarted.refresh(fixture.lifetime);
      expect(reads, 1);
      expect(restarted.models.map((model) => model.id), contains('gpt-6.1-sol'));
      expect(restarted.models.map((model) => model.id), isNot(contains('hidden')));
      if (hiddenOnly) expect(restarted.model('hidden').instructions, 'Instructions for hidden');
    });
  }

  for (final failure in [429, 503, 404, 'malformed']) {
    test('failed discovery preserves the snapshot and its freshness: $failure', () async {
      var reads = 0;
      final fixture = await _fixture((request) async {
        if (++reads == 1) { await _reply(request, [_model('last-success')]); return; }
        request.response.statusCode = failure is int ? failure : 200;
        request.response.write('not a catalog');
        await request.response.close();
      });
      await fixture.catalog.refresh(fixture.lifetime);
      final saved = await fixture.cache.readAsString();
      await fixture.catalog.refreshIfNewEtag('new-etag', fixture.lifetime);
      expect(fixture.catalog.defaultModel, 'last-success');
      expect(fixture.catalog.model('last-success').instructions, 'Instructions for last-success');
      expect(await fixture.cache.readAsString(), saved);
      final restarted = fixture.restart();
      await restarted.refresh(fixture.lifetime);
      expect(restarted.defaultModel, 'last-success');
      expect(reads, 2);
    });
  }

  test('cache write errors do not discard fetched models and a later refresh recovers', () async {
    var reads = 0;
    final fixture = await _fixture((request) async {
      await _reply(request, [_model('remote-${++reads}')]);
    });
    await Directory(fixture.cache.path).create();
    await fixture.catalog.refresh(fixture.lifetime);
    expect(fixture.catalog.defaultModel, 'remote-1');
    await Directory(fixture.cache.path).delete();
    await fixture.catalog.refresh(fixture.lifetime);
    expect(fixture.catalog.defaultModel, 'remote-2');
    final restarted = fixture.restart();
    await restarted.refresh(fixture.lifetime, strategy: CatalogRefresh.offline);
    expect(restarted.defaultModel, 'remote-2');
    expect(reads, 2);
  });

  for (final stored in ['recent', 'half expired', 'expired', 'wrong identity', 'wrong version', 'wrong etag']) {
    test('matching response ETag renews only the matching aged disk entry: $stored', () async {
      var reads = 0;
      final fixture = await _fixture((request) async {
        reads++;
        await _reply(request, [_model('cached')], etag: 'stable');
      });
      await fixture.catalog.refresh(fixture.lifetime);
      final saved = jsonObject(jsonDecode(await fixture.cache.readAsString()));
      if (stored != 'recent') {
        saved['fetched_at'] = stored == 'half expired'
          ? DateTime.now().toUtc().subtract(const Duration(minutes: 3)).toIso8601String()
          : '2000-01-01T00:00:00Z';
      }
      switch (stored) {
        case 'wrong identity': saved['identity'] = 'another-account';
        case 'wrong version': saved['client_version'] = 'another-version';
        case 'wrong etag': saved['etag'] = 'another-etag';
      }
      final before = jsonEncode(saved);
      await fixture.cache.writeAsString(before);
      await fixture.catalog.refreshIfNewEtag('stable', fixture.lifetime);
      expect(reads, 1);
      final after = await fixture.cache.readAsString();
      if (stored == 'half expired' || stored == 'expired') {
        final renewed = jsonObject(jsonDecode(after));
        expect(DateTime.parse(renewed['fetched_at'] as String).isAfter(DateTime.parse(saved['fetched_at'] as String)), isTrue);
        renewed['fetched_at'] = saved['fetched_at'];
        expect(renewed, saved, reason: 'Renewing TTL preserves the catalog payload and identity');
        final restarted = fixture.restart();
        await restarted.refresh(fixture.lifetime, strategy: CatalogRefresh.offline);
        expect(restarted.defaultModel, 'cached');
        await fixture.catalog.refreshIfNewEtag('stable', fixture.lifetime);
        expect(await fixture.cache.readAsString(), after, reason: 'Recent entries are not rewritten');
      } else { expect(after, before); }
    });
  }

  for (final transport in ['http', 'websocket']) {
    test('$transport response metadata refreshes a fresh catalog when the ETag changes', () async {
      var reads = 0;
      final fixture = await _fixture((request) async {
        if (request.uri.path.endsWith('/models')) {
          expect(request.uri.queryParameters['route'], 'fixture');
          expect(request.uri.queryParameters['client_version'], gptCatalogClientVersion);
          expect(request.headers.value('authorization'), 'Bearer fixture-access');
          expect(request.headers.value('chatgpt-account-id'), 'fixture-account');
          await _reply(request, [_model(++reads == 1 ? 'initial' : 'updated')], etag: reads == 1 ? 'one' : 'two');
          return;
        }
        final completed = jsonEncode({'type': 'response.completed', 'response': {'output': <Json>[]}});
        if (transport == 'http') {
          await request.drain<void>();
          request.response.headers.set('X-Models-Etag', 'two');
          request.response.headers.contentType = ContentType('text', 'event-stream');
          request.response.write('data: $completed\n\n');
          await request.response.close();
        } else {
          final socket = await WebSocketTransformer.upgrade(request);
          try {
            await for (final _ in socket) {
              socket.add(jsonEncode({'type': 'codex.response.metadata', 'headers': {'X-Models-Etag': 'two'}}));
              socket.add(completed);
            }
          } finally { await socket.close(); }
        }
      }, query: 'route=fixture');
      await fixture.catalog.refresh(fixture.lifetime);
      final info = fixture.catalog.model('initial').data;
      await fixture.client.respond(model: 'initial', modelInfo: info, instructions: 'Instructions', input: [], tools: [],
        sessionId: 'fixture', transport: transport, cancellation: fixture.lifetime);
      expect(reads, 2);
      expect(fixture.catalog.defaultModel, 'updated');
      expect(fixture.catalog.revision, 'two');
    });
  }

  test('in-memory reads do not resolve credentials or access the network', () async {
    var authReads = 0, reads = 0;
    final fixture = await _fixture((request) async { reads++; await _reply(request, []); },
      credentials: () async { authReads++; return {}; });
    await fixture.catalog.refresh(fixture.lifetime, strategy: CatalogRefresh.inMemory);
    expect(authReads, 0);
    expect(reads, 0);
  });

  for (final customEndpoint in [false, true]) {
    test('discovery skips ${customEndpoint ? 'custom Responses routes' : 'missing authentication'}', () async {
      var reads = 0;
      final fixture = await _fixture((request) async { reads++; await _reply(request, []); },
        path: customEndpoint ? '/v1/responses' : null, credentials: customEndpoint ? null : () async => {});
      await fixture.catalog.refresh(fixture.lifetime, strategy: CatalogRefresh.online);
      expect(reads, 0);
      expect(fixture.catalog.available('gpt-6.1-sol'), isTrue);
      expect(await fixture.cache.exists(), isFalse);
    });
  }

  test('token rotation reuses an account catalog while account, plan and route changes do not', () async {
    String token(String user, int expires) => 'header.${base64Url.encode(utf8.encode(jsonEncode({
      'sub': user, 'exp': expires, 'https://api.openai.com/auth': {'chatgpt_plan_type': 'pro'},
    })))}.signature';
    var auth = <String, dynamic>{'access_token': token('first-user', 100), 'account_id': 'first-account', 'plan_type': 'pro'};
    var reads = 0;
    final fixture = await _fixture((request) async { await _reply(request, [_model('remote-${++reads}')]); },
      credentials: () async => auth);
    await fixture.catalog.refresh(fixture.lifetime);
    auth = {...auth, 'access_token': token('first-user', 200)};
    await fixture.restart().refresh(fixture.lifetime);
    expect(reads, 1);
    for (final change in [<String, dynamic>{'account_id': 'second-account'}, {'plan_type': 'free'},
      {'access_token': token('another-user', 300)}]) {
      auth = {...auth, ...change};
      await fixture.catalog.refresh(fixture.lifetime);
    }
    expect(reads, 4);
    final routed = ResponsesClient(credentials: ({bool refresh = false}) async => auth,
      endpoint: fixture.client.endpoint.replace(query: 'route=other'));
    addTearDown(routed.close);
    final catalog = GptCatalog(routed, directory: fixture.cache.parent.path, lifetime: fixture.lifetime);
    await catalog.refresh(fixture.lifetime);
    expect(reads, 5);
  });

  test('a response from previous credentials cannot be published or cached', () async {
    var account = 'previous';
    final started = Completer<void>(), release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final fixture = await _fixture((request) async {
      final requested = request.headers.value('chatgpt-account-id')!;
      if (requested == 'previous') { started.complete(); await release.future; }
      await _reply(request, [_model(requested)]);
    }, credentials: () async => {'access_token': 'fixture', 'account_id': account});
    final pending = fixture.catalog.refresh(fixture.lifetime);
    await started.future;
    account = 'current';
    release.complete();
    await pending;
    expect(fixture.catalog.available('previous'), isFalse);
    expect(await fixture.cache.exists(), isFalse);
    await fixture.catalog.refresh(fixture.lifetime);
    expect(fixture.catalog.defaultModel, 'current');
  });

  for (final cancelCaller in [false, true]) {
    test('${cancelCaller ? 'caller cancellation' : 'invalidation'} cancels discovery and ignores late completion', () async {
      var reads = 0;
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() { if (!release.isCompleted) release.complete(); });
      final fixture = await _fixture((request) async {
        if (++reads == 1) { started.complete(); await release.future; }
        await _reply(request, [_model(reads == 1 ? 'stale' : 'current')]);
      });
      final caller = CancellationToken();
      final pending = fixture.catalog.refresh(caller);
      final stopped = cancelCaller ? expectLater(pending, throwsA(isA<CancelledException>())) : pending;
      await started.future;
      if (cancelCaller) { caller.cancel(); } else { fixture.catalog.invalidate(); }
      await stopped;
      release.complete();
      expect(fixture.catalog.available('stale'), isFalse);
      expect(await fixture.cache.exists(), isFalse);
      await fixture.catalog.refresh(fixture.lifetime);
      expect(fixture.catalog.defaultModel, 'current');
    });
  }

  test('simultaneous cache misses share the catalog request', () async {
    var reads = 0;
    final started = Completer<void>(), release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final fixture = await _fixture((request) async {
      reads++;
      started.complete();
      await release.future;
      await _reply(request, [_model('shared')]);
    });
    final first = fixture.catalog.refresh(fixture.lifetime);
    await started.future;
    final second = fixture.catalog.refresh(fixture.lifetime);
    release.complete();
    await Future.wait([first, second]);
    expect(reads, 1);
    expect(fixture.catalog.defaultModel, 'shared');
  });

  test('catalog startup bounds credential resolution to five seconds', () async {
    final auth = Completer<Json>();
    addTearDown(() { if (!auth.isCompleted) auth.complete({}); });
    final fixture = await _fixture((request) => _reply(request, []), credentials: () => auth.future);
    await fixture.catalog.refresh(fixture.lifetime).timeout(const Duration(seconds: 7));
    expect(fixture.catalog.available('gpt-6.1-sol'), isTrue);
    expect(await fixture.cache.exists(), isFalse);
  });
}

Json _model(String id, {int priority = 0, String visibility = 'list'}) => {
  ...GptModel('gpt-6.1-sol').data,
  'slug': id, 'display_name': id, 'priority': priority, 'visibility': visibility,
  'model_messages': {'instructions_template': 'Instructions for $id'},
};

Future<void> _reply(HttpRequest request, List<Json> models, {String etag = 'catalog'}) async {
  request.response.headers.contentType = ContentType.json;
  request.response.headers.set('etag', etag);
  request.response.write(jsonEncode({'models': models}));
  await request.response.close();
}

typedef _CatalogFixture = ({GptCatalog catalog, File cache, ResponsesClient client,
  CancellationToken lifetime, GptCatalog Function() restart});

Future<_CatalogFixture> _fixture(Future<void> Function(HttpRequest) handler, {
  Future<Json> Function()? credentials, String? path, String? query,
}) async {
  final root = await Directory.systemTemp.createTemp('catalog-cache-');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final lifetime = CancellationToken();
  late final GptCatalog catalog;
  final client = ResponsesClient(
    endpoint: Uri.parse('http://127.0.0.1:${server.port}${path ?? '/backend-api/codex/responses'}').replace(query: query),
    credentials: ({bool refresh = false}) async => credentials == null
      ? {'access_token': 'fixture-access', 'account_id': 'fixture-account'} : await credentials(),
    onModelsEtag: (etag, cancellation) => catalog.refreshIfNewEtag(etag, cancellation),
  );
  GptCatalog create() => GptCatalog(client, directory: root.path, lifetime: lifetime);
  catalog = create();
  server.listen((request) async {
    try { await handler(request); }
    on HttpException { /* A cancelled refresh can close the socket first. */ }
    on SocketException { /* A cancelled refresh can close the socket first. */ }
  });
  addTearDown(() async {
    lifetime.cancel();
    client.close();
    await server.close(force: true);
    await root.delete(recursive: true);
  });
  return (catalog: catalog, cache: File('${root.path}/models_cache.json'), client: client, lifetime: lifetime, restart: create);
}
