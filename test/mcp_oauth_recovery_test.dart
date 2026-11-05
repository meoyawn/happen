// Modified ports of Codex 5112ce6edeb9 rmcp-client/tests/
// streamable_http_oauth_tool_call.rs (all 10 runtime + 3 startup vectors) and
// streamable_http_oauth_startup.rs. Happen is modern-first, has one coordinated
// private file store, and never replays a rejected tools/call. Alternate Codex
// refresh backends, dynamic gateway helpers and plugin credentials are absent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late _OAuth peer;
  setUp(() async { peer = await _OAuth.start(); });
  tearDown(() => peer.close());

  for (final scenario in ['no-refresh', 'rejected', 'malformed', 'transient', 'early-malformed',
    'early-transient', 'refreshable', 'unexpired', 'unknown-expiry', 'revoked',
    'startup-malformed', 'startup-transient', 'startup-refreshable']) {
    test('Codex ordinary OAuth recovery: $scenario', () async {
      final startup = scenario.startsWith('startup-'), revoked = scenario == 'revoked';
      final expires = switch (scenario) {
        'unexpired' || 'startup-refreshable' => 3600,
        'early-malformed' || 'early-transient' => 30,
        'unknown-expiry' => null,
        _ => 0,
      };
      peer.rejectTools = revoked;
      peer.tokenReply = (_) => switch (scenario) {
        'startup-malformed' => const _Token(text: '{'),
        'startup-transient' => const _Token(status: 503, body: {'error': 'temporarily_unavailable'}),
        _ => _Token(body: {'access_token': 'initial-token', 'token_type': 'Bearer', 'refresh_token': 'refresh-token', 'expires_in': expires}),
      };
      await peer.save(refresh: !revoked, expires: revoked ? DateTime.now().millisecondsSinceEpoch + 3600000 : 0);
      final original = await peer.file.readAsString();
      await peer.configure();
      if (startup) {
        expect((await peer.inventory())['state'], scenario == 'startup-refreshable' ? 'ready' : 'authentication_required');
        expect(peer.tokens, hasLength(1));
        if (scenario == 'startup-refreshable') {
          expect(peer.rpc.map((r) => r['method']), ['server/discover', 'tools/list']);
          expect(peer.rpc.map((r) => r['authorization']), everyElement('Bearer initial-token'));
        } else {
          expect(peer.rpc, isEmpty); expect(await peer.file.readAsString(), original);
        }
        return;
      }
      expect((await peer.inventory())['state'], 'ready');
      expect(peer.tokens, hasLength(revoked ? 0 : 1), reason: 'One startup refresh serves discovery and catalog initialization, even with zero expiry.');
      if (scenario == 'no-refresh') {
        final saved = jsonObject(jsonDecode(await peer.file.readAsString()))..remove('refresh_token');
        await peer.file.writeAsString(jsonEncode(saved));
      }
      final before = await peer.file.readAsString();
      final previousTokens = peer.tokens.length;
      peer.tokenReply = (_) => switch (scenario) {
        'refreshable' => const _Token(body: {'access_token': 'renewed-token', 'token_type': 'Bearer', 'expires_in': 3600}),
        'malformed' || 'early-malformed' => const _Token(text: '{'),
        'transient' || 'early-transient' => const _Token(status: 503, body: {'error': 'temporarily_unavailable'}),
        _ => const _Token(status: 400, body: {'error': 'invalid_grant', 'error_description': 'private provider details'}),
      };
      final outcome = await _outcome(() => peer.call());
      switch (scenario) {
        case 'no-refresh': case 'rejected': case 'malformed': case 'transient':
          expect(outcome.error, null);
          expect(outcome.result, {'isError': true, 'content': [{'type': 'text',
            'text': 'MCP authentication required. Reconnect to continue using this server.'}],
            '_meta': {'mcp/www_authenticate': 'Bearer error="invalid_token"'}});
        case 'revoked':
          expect(outcome.error, null);
          expect(outcome.result, {'isError': true, 'content': [{'type': 'text', 'text': 'Authentication required'}],
            '_meta': {'mcp/www_authenticate': ['Bearer error="invalid_token"']}});
        case 'early-malformed': case 'early-transient':
          expect(outcome.error, isA<McpFailure>().having((e) => e.status == 401 || e.status == 403, 'not authentication-required', false));
        case 'refreshable': case 'unexpired': case 'unknown-expiry':
          expect(outcome.error, null); expect(outcome.result, {'content': [{'type': 'text', 'text': 'tool ran'}]});
      }
      expect(peer.rpc.where((r) => r['method'] == 'tools/call'), hasLength(
        ['refreshable', 'unexpired', 'unknown-expiry', 'revoked'].contains(scenario) ? 1 : 0));
      expect(peer.tokens.length - previousTokens, ['no-refresh', 'unexpired', 'unknown-expiry', 'revoked'].contains(scenario) ? 0 : 1);
      final after = await peer.file.readAsString();
      if (scenario == 'refreshable') {
        final saved = jsonObject(jsonDecode(after));
        expect(saved['access_token'], 'renewed-token'); expect(saved['refresh_token'], 'refresh-token');
        expect(saved['scope'], 'read'); expect(saved['issuer'], peer.issuer); expect(saved['resource'], peer.resource);
      } else { expect(after, before, reason: 'Failure, expiry and revocation must not delete or rewrite durable credentials.'); }
      expect(jsonEncode(outcome.result ?? outcome.error.toString()), isNot(contains('private provider details')));
    });
  }

  // The legacy/coordinated Rust branches are one coordinated Happen path, not
  // duplicate invocations of an identical fixture. Literal/env isolation still
  // crosses the real resource and authorization origins in every vector.
  for (final scenario in ['direct', 'oidc', 'resource-audience', 'client_secret_basic', 'client_secret_post']) {
    test('Codex OAuth startup refresh before any MCP request: $scenario', () async {
      peer.protected = scenario == 'resource-audience'; peer.oidc = scenario == 'oidc'; peer.pkce = false;
      if (peer.protected) peer.suffix = '/?oauth=initialize';
      final confidential = scenario.startsWith('client_secret_');
      if (confidential) peer.authMethod = scenario;
      peer.config['headers'] = {'User-Agent': 'resource-only-user-agent'};
      peer.config['header_env'] = {'X-Api-Key': 'MCP_TEST_RESOURCE_KEY'};
      await peer.save();
      await peer.externalStartup();
      expect(peer.tokens, hasLength(1));
      expect(peer.rpc.map((r) => r['method']), ['server/discover', 'tools/list']);
      expect(peer.rpc.map((r) => r['authorization']), everyElement('Bearer renewed-token'));
      expect(peer.rpc.map((r) => r['api_key']), everyElement('resource-private'));
      expect(peer.rpc.map((r) => r['user_agent']), everyElement('resource-only-user-agent'));
      expect(peer.tokens.single['form']['resource'], peer.resource);
      for (final r in peer.requests.where((r) => r['side'] == 'authorization')) {
        expect(r['api_key'], null); expect(r['user_agent'], 'happen-mcp-client/0.1.0');
      }
      if (confidential) {
        final token = peer.tokens.single;
        if (scenario == 'client_secret_basic') {
          expect(token['authorization'], 'Basic ${base64.encode(utf8.encode('test-client:configured-client-secret'))}');
          expect(token['form']['client_secret'], null);
        } else {
          expect(token['authorization'], null); expect(token['form']['client_id'], 'test-client');
          expect(token['form']['client_secret'], 'configured-client-secret');
        }
        final saved = await peer.file.readAsString();
        expect(saved, isNot(contains('configured-client-secret'))); expect(saved, isNot(contains('client_secret')));
      }
      if (peer.oidc) {
        expect(peer.requests.where((r) => r['method'] == 'GET' && (r['path'] as String).contains('well-known') && r['side'] == 'resource')
          .map((r) => r['path']), containsAllInOrder(['/.well-known/oauth-authorization-server/mcp',
            '/.well-known/openid-configuration/mcp', '/mcp/.well-known/openid-configuration']));
      }
    });
  }

  test('Codex OAuth startup rejects configured client-ID mismatch without provider contact', () async {
    await peer.save(); final before = await peer.file.readAsString();
    peer.config['oauth'] = {'client_id': 'different-client'};
    await peer.configure();
    expect((await peer.inventory())['state'], 'authentication_required');
    expect(peer.requests, isEmpty); expect(await peer.file.readAsString(), before);
  });
  for (final expired in [false, true]) {
    test('Codex OAuth issuer changes reject refresh without sending the stored secret: expired=$expired', () async {
      await peer.save(issuer: peer.otherOrigin, expires: expired ? 0 : DateTime.now().millisecondsSinceEpoch + 3600000);
      peer.rejectAccess = 'old-token';
      final before = await peer.file.readAsString(); await peer.configure();
      expect((await peer.inventory())['state'], 'authentication_required');
      expect(peer.tokens, isEmpty); expect(peer.rpc, hasLength(expired ? 0 : 1));
      expect(peer.metadataReads, 1);
      expect(peer.requests.where((r) => r['side'] == 'authorization' && r['path'] == '/.well-known/oauth-authorization-server'), hasLength(1));
      expect(peer.requests.where((r) => r['side'] == 'other'), isEmpty);
      expect(await peer.file.readAsString(), before);
    });
  }
  test('Codex OAuth rejected refresh does not rediscover and post secrets to replacement metadata', () async {
    await peer.save(expires: DateTime.now().millisecondsSinceEpoch + 3600000);
    peer.swapMetadata = true; peer.rejectAccess = 'old-token';
    peer.tokenReply = (_) => const _Token(status: 400, body: {'error': 'invalid_grant'});
    final before = await peer.file.readAsString(); await peer.configure();
    expect((await peer.inventory())['state'], 'authentication_required');
    expect(peer.rpc, hasLength(1)); expect(peer.tokens, hasLength(1));
    expect(peer.metadataReads, 1); expect(peer.requests.where((r) => r['side'] == 'other'), isEmpty);
    expect(await peer.file.readAsString(), before);
  });
  for (final credentials in ['none', 'issuerless-expired', 'issuerless-unexpired', 'refreshable', 'expired-unrefreshable']) {
    test('Codex persisted OAuth status and expired-unrefreshable startup: $credentials', () async {
      if (credentials != 'none') await peer.save(issuer: credentials.startsWith('issuerless') || credentials == 'expired-unrefreshable' ? '' : null,
        expires: credentials == 'issuerless-unexpired' ? DateTime.now().millisecondsSinceEpoch + 60000 : 0,
        refresh: !['issuerless-unexpired', 'expired-unrefreshable'].contains(credentials));
      if (credentials == 'none') peer.rejectAccess = null;
      peer.requireBearer = true;
      final before = await peer.file.exists() ? await peer.file.readAsString() : null;
      await peer.configure(); final row = await peer.inventory();
      final usable = ['issuerless-unexpired', 'refreshable'].contains(credentials);
      expect(row['state'], usable ? 'ready' : 'authentication_required');
      expect(row['auth_status'], usable ? 'oauth' : 'not_authenticated');
      expect(row['oauth_supported'], true);
      expect(peer.tokens, hasLength(credentials == 'refreshable' ? 1 : 0));
      if (credentials != 'refreshable') expect(await peer.file.exists() ? await peer.file.readAsString() : null, before);
    });
  }
  for (final succeeds in [false, true]) {
    test('Codex startup challenge recovery repairs credentials but never replays a rejected tool: refresh succeeds=$succeeds', () async {
      await peer.save(expires: DateTime.now().millisecondsSinceEpoch + 7200000);
      await peer.configure(); expect((await peer.inventory())['state'], 'ready');
      peer.rejectAccess = 'old-token';
      peer.tokenReply = (_) => succeeds ? const _Token(body: {'access_token': 'renewed-token', 'token_type': 'Bearer', 'expires_in': 7200})
        : const _Token(status: 400, body: {'error': 'invalid_grant'});
      final before = await peer.file.readAsString();
      expect((await peer.call())['_meta'], {'mcp/www_authenticate': ['Bearer error="invalid_token"']});
      await peer.until(() async => (await peer.inventory())['state'] == (succeeds ? 'ready' : 'authentication_required') && peer.tokens.length == 1);
      expect(peer.rpc.where((r) => r['method'] == 'tools/call'), hasLength(1));
      if (succeeds) {
        expect(await peer.call(), {'content': [{'type': 'text', 'text': 'tool ran'}]});
        expect(peer.rpc.where((r) => r['method'] == 'tools/call'), hasLength(2));
      } else { expect(await peer.file.readAsString(), before); }
    });
  }
}

Future<({Json? result, Object? error})> _outcome(Future<Json> Function() run) async {
  try { return (result: await run(), error: null); } catch (error) { return (result: null, error: error); }
}

class _Token {
  const _Token({this.status = 200, this.body = const {'access_token': 'renewed-token', 'token_type': 'Bearer', 'expires_in': 7200}, this.text});
  final int status;
  final Json body;
  final String? text;
}

class _OAuth {
  _OAuth(this.root, this.resourcePeer, this.authorizationPeer, this.other) {
    manager = McpManager(http: http, directory: root.path, onEvent: (_, _) {});
    resourcePeer.listen((request) => serve('resource', request));
    authorizationPeer.listen((request) => serve('authorization', request));
    other.listen((request) => serve('other', request));
  }
  final Directory root;
  final HttpServer resourcePeer, authorizationPeer, other;
  final http = HttpClient();
  final lifetime = TimeoutCancellationToken(const Duration(seconds: 20));
  late final McpManager manager;
  final requests = <Json>[], rpc = <Json>[], tokens = <Json>[];
  Json? _config;
  bool protected = true, oidc = false, pkce = true, rejectTools = false, requireBearer = false, swapMetadata = false;
  String suffix = '';
  String? rejectAccess, authMethod;
  int metadataReads = 0;
  _Token Function(int) tokenReply = (_) => const _Token();
  String get resourceOrigin => 'http://127.0.0.1:${resourcePeer.port}';
  String get authorizationOrigin => 'http://127.0.0.1:${authorizationPeer.port}';
  String get otherOrigin => 'http://127.0.0.1:${other.port}';
  String get url => '$resourceOrigin/mcp$suffix';
  String get resource => '$resourceOrigin/mcp';
  String get issuer => protected ? authorizationOrigin : resource;
  File get file => File('${root.path}/mcp-auth/${sha256.convert(utf8.encode('test\u0000$url'))}.json');
  Json get config => _config ??= {'url': url, 'headers': {'X-Api-Key': 'resource-private', 'User-Agent': 'resource-only-user-agent'},
    if (authMethod != null) 'oauth': {'client_id': 'test-client', 'client_secret_env': 'MCP_TEST_CLIENT_SECRET'}};
  static Future<_OAuth> start() async => _OAuth(await Directory.systemTemp.createTemp('codex-oauth-recovery-'),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0), await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> save({bool refresh = true, int? expires = 0, String? issuer}) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'server_name': 'test', 'server_url': url, 'client_id': 'test-client',
      'access_token': 'old-token', if (refresh) 'refresh_token': 'refresh-token', 'expires_at': expires,
      if (issuer != '') 'issuer': issuer ?? this.issuer, 'resource': resource, 'scope': 'read'}));
  }
  Future<void> configure() async {
    await manager.configure({'test': config}, lifetime);
    await until(() async => ['ready', 'failed'].contains(manager.status().single['state']));
  }
  Future<Json> inventory() async => jsonObject(((await manager.inventory(lifetime))['servers'] as List).single);
  Future<Json> call() => manager.request('test', 'tools/call', {'name': 'echo', 'arguments': <String, Object?>{}}, lifetime);
  Future<void> until(Future<bool> Function() done) async {
    while (!await done()) { await cancellableDelay(const Duration(milliseconds: 10), lifetime); }
  }
  Future<void> externalStartup() async {
    final process = await Process.start(Platform.resolvedExecutable, ['--disable-dart-dev',
      '--packages=${File('.dart_tool/package_config.json').absolute.path}', File('test/fixtures/mcp_oauth_startup.dart').absolute.path,
      root.path, jsonEncode(config)], environment: {'MCP_TEST_CLIENT_SECRET': 'configured-client-secret', 'MCP_TEST_RESOURCE_KEY': 'resource-private'});
    final output = utf8.decoder.bind(process.stdout).join(), errors = utf8.decoder.bind(process.stderr).join();
    final hook = CancellationHook(lifetime, () => process.kill(ProcessSignal.sigkill));
    try {
      expect(await process.exitCode.asCancellable(lifetime), 0, reason: await errors);
      expect(jsonObject(jsonDecode(await output))['state'], 'ready');
    } finally { hook.dispose(); process.kill(ProcessSignal.sigkill); }
  }
  Future<void> reply(HttpRequest request, Json body, {int status = 200, String? text}) async {
    request.response.statusCode = status; request.response.headers.contentType = ContentType.json;
    request.response.write(text ?? jsonEncode(body)); await request.response.close();
  }
  Future<void> serve(String side, HttpRequest request) async {
    final entry = <String, dynamic>{'side': side, 'path': request.uri.path, 'method': request.method,
      'authorization': request.headers.value('authorization'), 'api_key': request.headers.value('x-api-key'), 'user_agent': request.headers.value('user-agent')};
    requests.add(entry);
    final path = request.uri.path;
    if (request.method == 'POST' && (path == '/mcp' || path == '/mcp/')) {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join())); rpc.add({...entry, ...body});
      if (rejectTools && body['method'] == 'tools/call' || rejectAccess != null && entry['authorization'] == 'Bearer $rejectAccess' ||
          requireBearer && entry['authorization'] == null) {
        request.response.statusCode = 401; request.response.headers.set('www-authenticate', 'Bearer error="invalid_token"');
        await request.response.close(); return;
      }
      final result = switch (body['method']) {
        'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {'tools': <String, Object?>{}}},
        'tools/list' => {'tools': <Object?>[]},
        'tools/call' => {'content': [{'type': 'text', 'text': 'tool ran'}]},
        _ => throw StateError('Unexpected RPC ${body['method']}'),
      };
      await reply(request, {'jsonrpc': '2.0', 'id': body['id'], 'result': result}); return;
    }
    if (request.method == 'GET' && (path == '/mcp' || path == '/mcp/') && protected) {
      request.response.statusCode = 401; request.response.headers.set('www-authenticate', 'Bearer resource_metadata="$resourceOrigin/resource-metadata"');
      await request.response.close(); return;
    }
    if (path == '/resource-metadata' && protected) {
      final issuer = swapMetadata && metadataReads++ > 0 ? otherOrigin : authorizationOrigin;
      if (!swapMetadata) metadataReads++;
      await reply(request, {'resource': resource, 'authorization_servers': [issuer]}); return;
    }
    final metadataPath = protected ? '/.well-known/oauth-authorization-server' : oidc ? '/mcp/.well-known/openid-configuration' : '/.well-known/oauth-authorization-server/mcp';
    if (path == metadataPath) {
      await reply(request, {'issuer': side == 'other' ? otherOrigin : issuer, 'authorization_endpoint': '$authorizationOrigin/authorize',
        'token_endpoint': '${side == 'other' ? otherOrigin : authorizationOrigin}/token',
        if (pkce) 'code_challenge_methods_supported': ['S256'], if (authMethod != null) 'token_endpoint_auth_methods_supported': [authMethod]}); return;
    }
    if (oidc && path == '/.well-known/oauth-authorization-server/mcp') { await reply(request, {}, status: 503); return; }
    if (path == '/token') {
      final form = Uri.splitQueryString(await utf8.decoder.bind(request).join()); tokens.add({...entry, 'form': form});
      expect(form['grant_type'], 'refresh_token'); expect(form['refresh_token'], 'refresh-token');
      final response = tokenReply(tokens.length); await reply(request, response.body, status: response.status, text: response.text); return;
    }
    await reply(request, {}, status: 404);
  }
  Future<void> close() async {
    lifetime.cancel(); await manager.close(); http.close(force: true);
    await Future.wait([resourcePeer.close(force: true), authorizationPeer.close(force: true), other.close(force: true)]);
    await root.delete(recursive: true);
  }
}
