// Modified Codex 5112ce6edeb9 rmcp-client/src/oauth_http_client_security_tests.rs
// ports at real OAuth login/HTTP boundaries, not an injected HTTP adapter.
// AgentPluginV1 is excluded. Happen has a fixed 20-second HTTP timeout rather
// than Codex's scoped test duration; deadline vectors retain that real boundary.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart';
import 'package:mcp/src/oauth.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late _Security peer;
  setUp(() async { peer = await _Security.start(); });
  tearDown(() => peer.close());

  for (final (path, first) in [('', 'none'), ('/adfs', '404'), ('/adfs', '405'), ('/adfs', '503'), ('/adfs', 'malformed')]) {
    test('Codex OAuth metadata 503 falls back to OIDC: issuer=$path first=$first', () async {
      peer.issuerPath = path; peer.fallback = first;
      final url = await peer.login();
      expect(url.origin, peer.authorizationOrigin);
      expect(peer.authorizationPaths, ['/.well-known/oauth-authorization-server$path',
        if (path.isNotEmpty) '/.well-known/openid-configuration$path', '$path/.well-known/openid-configuration', '/token']);
      expect(peer.requests.where((r) => r['side'] == 'authorization').map((r) => r['api_key']), everyElement(null));
      expect(peer.tokens, hasLength(1));
    });
  }

  for (final (fallback, status, count) in [('404', 503, 3), ('wrong-issuer', null, 2), ('redirect', 503, 2),
    ('408', 408, 2), ('425', 425, 2), ('429', 429, 2), ('500', 500, 2)]) {
    test('Codex OAuth metadata fallback preserves terminal failure: $fallback', () async {
      peer.fallback = fallback; peer.finalMissing = true;
      await expectLater(peer.login(), throwsA(isA<McpFailure>().having(
        (e) => status == null ? e.message.contains('issuer') : e.status == status, 'terminal failure identity', true)));
      expect(peer.authorizationPaths, hasLength(count));
      expect(peer.requests.where((r) => r['side'] == 'other'), isEmpty);
      expect(peer.tokens, isEmpty);
    });
  }

  for (final scenario in ['registration-post', 'protected-resource', 'other-path', 'status-500']) {
    test('Codex OAuth metadata fallback does not replay unrelated requests or statuses: $scenario', () async {
      peer.noFallback = scenario;
      await expectLater(peer.login(registered: scenario != 'registration-post'), throwsA(isA<McpFailure>()));
      final relevant = peer.requests.where((r) => r['path'] == peer.failedPath &&
        r['method'] == (scenario == 'registration-post' ? 'POST' : 'GET')).toList();
      expect(relevant, hasLength(1));
      expect(relevant.single['method'], scenario == 'registration-post' ? 'POST' : 'GET');
      expect(peer.authorizationPaths.where((p) => p.contains('openid-configuration')), isEmpty);
      expect(peer.tokens, isEmpty);
    });
  }

  test('Codex OAuth metadata fallback shares the original timeout across candidates', () async {
    peer.slowMetadata = true;
    await expectLater(peer.login(), throwsA(isA<McpFailure>().having((e) => e.message, 'shared deadline failure', contains('timed out'))));
    expect(peer.authorizationPaths, ['/.well-known/oauth-authorization-server/adfs', '/.well-known/openid-configuration/adfs']);
    expect(peer.tokens, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 40)));

  for (final headers in [true, false]) {
    test('Codex ordinary registration redirects never forward resource-only headers: configured=$headers', () async {
      peer.registration = true; peer.registrationRedirect = 'cross-origin'; peer.resourceHeaders = headers;
      if (headers) {
        await expectLater(peer.login(registered: false), throwsA(isA<McpFailure>()));
        expect(peer.requests.where((r) => r['side'] == 'other'), isEmpty);
      } else {
        await peer.login(registered: false);
        final redirected = peer.requests.where((r) => r['side'] == 'other').single;
        expect(redirected['path'], '/redirected-register'); expect(redirected['api_key'], null);
        expect(redirected['user_agent'], 'happen-mcp-client/0.1.0');
        expect(redirected['content_type'], startsWith('application/json'));
        expect(redirected['body'], {'client_name': 'Happen', 'redirect_uris': peer.registrations.first['redirect_uris'],
          'grant_types': ['authorization_code', 'refresh_token'], 'response_types': ['code'], 'token_endpoint_auth_method': 'none'});
      }
      final initial = peer.requests.singleWhere((r) => r['path'] == '/register');
      expect(initial['content_type'], startsWith('application/json'));
      expect(initial['user_agent'], headers ? 'resource-only-user-agent' : 'happen-mcp-client/0.1.0');
    });
  }

  for (final oversized in [false, true]) {
    test('Codex same-origin registration redirects preserve ${oversized ? 'response body limits' : 'the original timeout'}', () async {
      peer.registration = true; peer.registrationRedirect = oversized ? 'oversized' : 'slow';
      await expectLater(peer.login(registered: false), throwsA(oversized
        ? isA<McpFailure>().having((e) => e.message, 'bounded redirect body', contains('exceeds'))
        : isA<McpFailure>().having((e) => e.message, 'shared redirect deadline', contains('timed out'))));
      expect(peer.requests.where((r) => r['path'] == '/register/'), hasLength(oversized ? 0 : 1));
      expect(peer.tokens, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 40)));
  }
}

class _Security {
  _Security(this.root, this.resource, this.authorization, this.other) {
    for (final (side, server) in [('resource', resource), ('authorization', authorization), ('other', other)]) {
      server.listen((r) async {
        try { await serve(side, r); } on CancelledException { if (!lifetime.isCancelled) rethrow; }
      });
    }
  }
  final Directory root;
  final HttpServer resource, authorization, other;
  final http = HttpClient();
  final lifetime = TimeoutCancellationToken(const Duration(seconds: 35));
  final requests = <Json>[], registrations = <Json>[], tokens = <Map<String, String>>[], owners = <McpOAuth>[];
  String issuerPath = '/adfs', fallback = '404';
  String? noFallback, registrationRedirect;
  bool finalMissing = false, slowMetadata = false, registration = false, resourceHeaders = true;
  String get resourceOrigin => 'http://127.0.0.1:${resource.port}';
  String get authorizationOrigin => 'http://127.0.0.1:${authorization.port}';
  String get otherOrigin => 'http://127.0.0.1:${other.port}';
  String get issuer => '$authorizationOrigin$issuerPath';
  String get failedPath => switch (noFallback) {
    'registration-post' || 'status-500' => '/.well-known/oauth-authorization-server/adfs',
    'protected-resource' => '/resource-metadata',
    'other-path' => '/.well-known/oauth-authorization-server-other',
    _ => throw StateError('No selected failure'),
  };
  List<String> get authorizationPaths => [for (final r in requests) if (r['side'] == 'authorization') r['path'] as String];
  static Future<_Security> start() async => _Security(await Directory.systemTemp.createTemp('codex-oauth-http-'),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0), await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<Uri> login({bool registered = true}) async {
    final auth = McpOAuth(root.path, 'security', {'url': '$resourceOrigin/mcp',
      'headers': resourceHeaders ? {'X-Api-Key': 'resource-private', 'User-Agent': 'resource-only-user-agent'}
        : {'Content-Type': 'resource-only-content-type'}, 'oauth': {if (registered) 'client_id': 'registered'}}, http);
    owners.add(auth);
    Uri? opened;
    await auth.login(lifetime, (value) {
      opened = Uri.parse(value);
      final callback = Uri.parse(opened!.queryParameters['redirect_uri']!).replace(queryParameters: {
        'code': 'accepted', 'state': opened!.queryParameters['state']!,
      });
      auth.completeLogin(callback.toString());
    });
    return opened!;
  }
  Json get metadata => {'issuer': issuer, 'authorization_endpoint': '$authorizationOrigin/authorize',
    'token_endpoint': '$authorizationOrigin/token', 'code_challenge_methods_supported': ['S256'],
    if (registration) 'registration_endpoint': '$resourceOrigin/register',
    if (noFallback == 'registration-post') 'registration_endpoint': '$authorizationOrigin$failedPath'};
  Future<void> reply(HttpRequest request, Json body, {int status = 200, String? text, String? location}) async {
    request.response.statusCode = status; request.response.headers.contentType = ContentType.json;
    if (location != null) request.response.headers.set('location', location);
    try { request.response.write(text ?? jsonEncode(body)); await request.response.close(); }
    on HttpException { /* Deadline/caller closed this test's response. */ }
    on SocketException { /* Deadline/caller closed this test's response. */ }
  }
  Future<void> serve(String side, HttpRequest request) async {
    final path = request.uri.path, record = <String, dynamic>{'side': side, 'method': request.method, 'path': request.uri.path,
      'api_key': request.headers.value('x-api-key'), 'user_agent': request.headers.value('user-agent'), 'content_type': request.headers.value('content-type')};
    requests.add(record);
    if (request.method == 'POST' && path != '/token') {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join())); record['body'] = body;
      registrations.add(body);
      if (noFallback == 'registration-post') { await reply(request, {}, status: 503); return; }
      if (path == '/register') {
        if (registrationRedirect == 'slow') await cancellableDelay(const Duration(seconds: 12), lifetime);
        await reply(request, {}, status: 307,
          text: registrationRedirect == 'oversized' ? 'x' * (1024 * 1024 + 1) : null,
          location: registrationRedirect == 'cross-origin' ? '$otherOrigin/redirected-register' : '/register/'); return;
      }
      if (path == '/register/' && registrationRedirect == 'slow') await cancellableDelay(const Duration(seconds: 12), lifetime);
      await reply(request, {'client_id': 'dynamic-client', 'redirect_uris': body['redirect_uris']}, status: 201); return;
    }
    if (side == 'resource' && path == '/mcp') {
      request.response.statusCode = 401;
      request.response.headers.set('www-authenticate', 'Bearer resource_metadata="$resourceOrigin/resource-metadata"');
      await request.response.close(); return;
    }
    if (path == '/resource-metadata') {
      await reply(request, {'resource': '$resourceOrigin/mcp', 'authorization_servers': [
        noFallback == 'other-path' ? '$authorizationOrigin$failedPath' : issuer,
      ]}, status: noFallback == 'protected-resource' ? 503 : 200); return;
    }
    if (path == '/token') {
      tokens.add(Uri.splitQueryString(await utf8.decoder.bind(request).join()));
      await reply(request, {'access_token': 'accepted-token', 'token_type': 'Bearer', 'expires_in': 3600}); return;
    }
    if (side == 'authorization' && (path == '/.well-known/oauth-authorization-server$issuerPath' ||
        noFallback == 'other-path' && path == failedPath)) {
      if (noFallback == 'registration-post' || registration) { await reply(request, metadata); return; }
      if (slowMetadata) await cancellableDelay(const Duration(seconds: 12), lifetime);
      await reply(request, {}, status: noFallback == 'status-500' ? 500 : 503); return;
    }
    if (side == 'authorization' && issuerPath.isNotEmpty && path == '/.well-known/openid-configuration$issuerPath') {
      if (slowMetadata) await cancellableDelay(const Duration(seconds: 12), lifetime);
      if (fallback == 'wrong-issuer') await reply(request, {...metadata, 'issuer': '$authorizationOrigin/other-tenant'});
      else if (fallback == 'malformed') await reply(request, {}, text: 'not metadata');
      else if (fallback == 'redirect') await reply(request, {}, status: 307, location: '$otherOrigin/redirected-metadata');
      else await reply(request, {}, status: int.parse(fallback));
      return;
    }
    if (side == 'authorization' && path == '$issuerPath/.well-known/openid-configuration' && !finalMissing) {
      await reply(request, metadata); return;
    }
    await reply(request, {}, status: 404);
  }
  Future<void> close() async {
    lifetime.cancel(); await Future.wait(owners.map((v) => v.close())); http.close(force: true);
    await Future.wait([resource.close(force: true), authorization.close(force: true), other.close(force: true)]);
    await root.delete(recursive: true);
  }
}
