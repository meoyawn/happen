// Modified Dart ports of Codex 5112ce6edeb9 rmcp-client/tests/
// mcp_2026_oauth_discovery.rs. Only ordinary MCP OAuth; AgentPluginV1,
// ChatGPT connectors and enterprise-managed authorization are not ported.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart';
import 'package:mcp/src/oauth.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late _Discovery peer;
  setUp(() async { peer = await _Discovery.start(); });
  tearDown(() => peer.close());

  for (final redirect in [false, true]) {
    for (final issuer in ['matching', 'missing', 'mismatched']) {
      test('Codex OAuth discovery GET-first, issuer=$issuer, metadata redirects=$redirect', () async {
        peer.redirect = redirect; peer.issuer = issuer;
        final auth = peer.auth();
        if (issuer == 'mismatched') {
          await expectLater(auth.login(peer.lifetime, (_) => fail('An untrusted issuer may not open authorization')), throwsA(isA<McpFailure>().having((e) => e.message, 'issuer guard', contains('issuer'))));
        } else {
          final login = await peer.login(auth), url = login.url;
          expect(url.origin, peer.authorizationOrigin);
          expect(url.queryParameters['scope'], 'mcp:read');
          expect(Uri.parse(url.queryParameters['redirect_uri']!).path, startsWith('/callback/'));
          auth.completeLogin(peer.callback(url).toString()); await login.done;
          expect(peer.forms.single['grant_type'], 'authorization_code');
          expect(peer.forms.single['resource'], peer.resourceUrl);
        }
        expect(peer.requests.first['method'], 'GET');
        expect(peer.requests.where((r) => r['side'] == 'resource' && r['path'] == '/mcp').map((r) => r['method']), everyElement('GET'),
          reason: 'OAuth discovery must not initialize a legacy MCP session.');
        final resource = peer.requests.where((r) => r['side'] == 'resource' && (r['path'] as String).contains('resource-metadata')).toList();
        expect(resource, isNotEmpty);
        for (final request in resource) {
          expect(request['authorization'], 'Bearer resource-only-secret');
          expect(request['api_key'], 'resource-api-key');
          expect(request['user_agent'], 'resource-user-agent');
        }
        final authorization = peer.requests.where((r) => r['side'] == 'authorization').toList();
        expect(authorization, isNotEmpty);
        for (final request in authorization) {
          expect(request['authorization'], null); expect(request['api_key'], null);
          expect(request['user_agent'], 'happen-mcp-client/0.1.0');
        }
      });
    }
  }

  for (final side in ['resource', 'authorization']) {
    test('Codex OAuth discovery rejects cross-origin $side metadata redirects without contacting their destination', () async {
      peer.crossOrigin = side;
      await expectLater(peer.auth().login(peer.lifetime, (_) => fail('Must reject the redirect before authorization')), throwsA(isA<McpFailure>().having((e) => e.message, 'redirect guard', contains('redirect'))));
      expect(peer.requests.where((r) => r['side'] == side && (r['path'] as String).contains('metadata') ||
        side == 'authorization' && r['path'] == '/.well-known/oauth-authorization-server'), isNotEmpty);
      expect(peer.requests.where((r) => r['side'] == 'attacker'), isEmpty);
      expect(peer.forms, isEmpty);
    });
  }

  test('Codex OAuth discovery bounds authorization metadata redirect cycles', () async {
    peer.cycle = true;
    await expectLater(peer.auth().login(peer.lifetime, (_) => fail('A cycle cannot authorize')), throwsA(isA<McpFailure>().having((e) => e.message, 'bounded redirects', contains('redirect'))));
    final attempts = peer.requests.where((r) => r['side'] == 'authorization').length;
    expect(attempts, inInclusiveRange(2, 100)); expect(peer.forms, isEmpty);
  });

  test('Codex OAuth does not invent support for an unauthenticated legacy server', () async {
    peer.noOAuth = true;
    var opened = false;
    await expectLater(peer.auth().login(peer.lifetime, (_) { opened = true; }), throwsA(isA<McpFailure>()));
    expect(opened, false); expect(peer.forms, isEmpty);
    expect(peer.requests.where((r) => r['path'] == '/mcp').map((r) => r['method']), everyElement('GET'));
  });

  // Full ordinary-login matrix from interactive_oauth_rejects_untrusted_authorization_metadata.
  // Each case exercises both DCR and a pre-registered client, not a plugin.
  for (final scenario in [
    ('missing', '/.well-known/untrusted-provider', false, 'token endpoint'),
    ('mismatched', '/.well-known/untrusted-provider', true, 'issuer'),
    ('mismatched', '/metadata.json', false, 'issuer'),
    ('mismatched', '/metadata.json', true, 'issuer'),
    ('mismatched', '/.well-known/oauth-authorization-server', false, 'issuer'),
    ('mismatched', '/.well-known/oauth-authorization-server', true, 'issuer'),
    ('mismatched', '/.well-known/openid-configuration', true, 'issuer'),
    ('matching', '/.well-known/untrusted-provider', false, 'authorization endpoint'),
  ]) {
    for (final registered in [false, true]) {
      test('Codex OAuth untrusted metadata: $scenario, registered=$registered', () async {
        peer.untrusted = true; peer.issuer = scenario.$1; peer.metadataPath = scenario.$2; peer.issuerBound = scenario.$3;
        var opened = false;
        await expectLater(peer.auth(registered: registered).login(peer.lifetime, (_) { opened = true; }),
          throwsA(isA<McpFailure>().having((e) => e.message, 'metadata trust guard', contains(scenario.$4))));
        expect(peer.requests.where((r) => r['side'] == 'resource' && r['path'] == scenario.$2), isNotEmpty,
          reason: 'The advertised authorization document must reach the actual metadata guard.');
        expect(opened, false); expect(peer.forms, isEmpty);
        expect(peer.requests.where((r) => r['side'] == 'attacker'), isEmpty);
        expect(peer.requests.where((r) => r['method'] == 'POST'), isEmpty, reason: 'No registration, code or verifier may escape discovery.');
      });
    }
  }
}

class _Discovery {
  _Discovery(this.root, this.resource, this.authorization, this.attacker);
  final Directory root;
  final HttpServer resource, authorization, attacker;
  final http = HttpClient();
  final lifetime = TimeoutCancellationToken(const Duration(seconds: 10));
  final owners = <McpOAuth>[];
  final requests = <Json>[], forms = <Map<String, String>>[];
  String issuer = 'matching', metadataPath = '/.well-known/untrusted-provider';
  String? crossOrigin;
  bool redirect = false, cycle = false, noOAuth = false, untrusted = false, issuerBound = false;
  String get resourceOrigin => 'http://127.0.0.1:${resource.port}';
  String get resourceUrl => '$resourceOrigin/mcp';
  String get authorizationOrigin => 'http://127.0.0.1:${authorization.port}';
  String get attackerOrigin => 'http://127.0.0.1:${attacker.port}';
  static Future<_Discovery> start() async {
    final peer = _Discovery(await Directory.systemTemp.createTemp('codex-mcp-oauth-'),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0), await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    peer.resource.listen((r) => peer.serve('resource', r));
    peer.authorization.listen((r) => peer.serve('authorization', r));
    peer.attacker.listen((r) => peer.serve('attacker', r)); return peer;
  }
  McpOAuth auth({bool registered = true}) {
    final auth = McpOAuth(root.path, 'test', {'url': resourceUrl,
      'headers': {'Authorization': 'Bearer resource-only-secret', 'X-Api-Key': 'resource-api-key', 'User-Agent': 'resource-user-agent'},
      'oauth': {if (registered) 'client_id': 'preregistered-client'}}, http);
    owners.add(auth); return auth;
  }
  Future<({Uri url, Future<void> done})> login(McpOAuth auth) async {
    final url = Completer<Uri>();
    final done = auth.login(lifetime, (value) => url.complete(Uri.parse(value)));
    unawaited(done.then<void>((_) {}, onError: (Object error, StackTrace stack) { if (!url.isCompleted) url.completeError(error, stack); }));
    return (url: await url.future, done: done);
  }
  Uri callback(Uri url) => Uri.parse(url.queryParameters['redirect_uri']!).replace(queryParameters: {'code': 'accepted', 'state': url.queryParameters['state']!});
  Future<void> serve(String side, HttpRequest request) async {
    final path = request.uri.path;
    requests.add({'side': side, 'method': request.method, 'path': path,
      'authorization': request.headers.value('authorization'), 'api_key': request.headers.value('x-api-key'), 'user_agent': request.headers.value('user-agent')});
    Json? body;
    void move(String location) { request.response.statusCode = 302; request.response.headers.set('Location', location); }
    if (noOAuth) { request.response.statusCode = 404; }
    else if (side == 'resource' && path == '/mcp') {
      request.response.statusCode = 401;
      request.response.headers.set('WWW-Authenticate', 'Bearer resource_metadata="$resourceOrigin/resource-metadata"');
    } else if (side == 'resource' && path == '/resource-metadata' && crossOrigin == 'resource') { move('$attackerOrigin/resource'); }
    else if (side == 'resource' && path == '/resource-metadata' && redirect) { move('/redirected-resource-metadata'); }
    else if (side == 'resource' && ['/resource-metadata', '/redirected-resource-metadata'].contains(path)) {
      body = {'resource': resourceUrl, 'authorization_servers': [untrusted ? '$resourceOrigin/.well-known/untrusted-provider' : authorizationOrigin], 'scopes_supported': ['mcp:read']};
    } else if (side == 'authorization' && path == '/.well-known/oauth-authorization-server' && crossOrigin == 'authorization') { move('$attackerOrigin/authorization'); }
    else if (side == 'authorization' && path == '/.well-known/oauth-authorization-server' && cycle) { move('/.well-known/oauth-authorization-server'); }
    else if (side == 'authorization' && path == '/.well-known/oauth-authorization-server' && redirect) { move('/redirected-authorization-metadata'); }
    else if (untrusted && side == 'resource' && path == '/.well-known/untrusted-provider' && path != metadataPath) { move(metadataPath); }
    else if (untrusted && side == 'resource' && path == metadataPath ||
        !untrusted && side == 'authorization' && ['/.well-known/oauth-authorization-server', '/redirected-authorization-metadata'].contains(path)) {
      body = {'authorization_endpoint': '$authorizationOrigin/authorize', 'token_endpoint': '${untrusted ? attackerOrigin : authorizationOrigin}/token',
        'registration_endpoint': '$authorizationOrigin/register', 'code_challenge_methods_supported': ['S256'],
        'authorization_response_iss_parameter_supported': issuerBound,
        if (issuer != 'missing') 'issuer': untrusted ? issuer == 'matching' ? resourceOrigin : authorizationOrigin
          : issuer == 'matching' ? authorizationOrigin : 'https://unexpected-issuer.example'};
    } else if (side == 'authorization' && path == '/token') {
      forms.add(Uri.splitQueryString(await utf8.decoder.bind(request).join()));
      body = {'access_token': 'access', 'token_type': 'Bearer', 'expires_in': 3600};
    } else { request.response.statusCode = 404; }
    if (body != null) { request.response.headers.contentType = ContentType.json; request.response.write(jsonEncode(body)); }
    await request.response.close();
  }
  Future<void> close() async {
    lifetime.cancel(); await Future.wait(owners.map((auth) => auth.close())); http.close(force: true);
    await resource.close(force: true); await authorization.close(force: true); await attacker.close(force: true); await root.delete(recursive: true);
  }
}
