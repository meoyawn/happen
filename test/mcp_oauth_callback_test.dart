// Modified ports of Codex 5112ce6edeb9 rmcp-client/src/
// oauth_callback{,_input}_tests.rs at the real login/HTTP boundary. Happen
// always creates its own loopback redirect: configured external redirects and
// their fixed query parameters are not part of Happen's configuration schema.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:mcp/src/oauth.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late _Callback peer;
  setUp(() async { peer = await _Callback.start(); });
  tearDown(() => peer.close());

  for (final issuerBound in [false, true]) {
    test('Codex pasted callback trims whitespace, decodes the code and binds its redirect: issuerBound=$issuerBound', () async {
      peer.issuerBound = issuerBound;
      final login = await peer.begin(), url = login.url;
      final callback = peer.callback(url);
      expect(callback.path, issuerBound ? '/callback' : startsWith('/callback/'));
      peer.auth.completeLogin(' \n${callback.toString()}\t ');
      await login.done;
      expect(peer.forms, hasLength(1));
      expect(peer.forms.single['code'], 'a+b');
      expect(peer.forms.single['redirect_uri'], url.queryParameters['redirect_uri']);
      expect(peer.forms.single['resource'], '${peer.origin}/mcp');
      expect(base64Url.encode(sha256.convert(ascii.encode(peer.forms.single['code_verifier']!)).bytes).replaceAll('=', ''),
        url.queryParameters['code_challenge']);
      expect(await peer.auth.authorization(peer.lifetime), 'accepted-token');
      expect(() => peer.auth.completeLogin(callback.toString()), throwsA(isA<McpFailure>()));
      expect(peer.forms, hasLength(1), reason: 'A consumed callback cannot exchange the code twice.');
    });
  }

  // Complete applicable malformed-address/ambiguity vectors; the fixed-query
  // cases are unavailable without adding a new redirect configuration surface.
  for (final scenario in ['path', 'missing-id', 'wrong-id', 'port', 'duplicate-extra', 'encoded-code', 'duplicate-state', 'duplicate-issuer',
    'userinfo', 'fragment', 'empty-state', 'code-and-error', 'oversized', 'missing-code', 'empty-code', 'wrong-state']) {
    for (final delivery in ['paste', if (!['port', 'userinfo', 'fragment', 'oversized'].contains(scenario)) 'loopback']) {
      test('Codex $delivery callback rejects $scenario without consuming login or exposing values', () async {
        final login = await peer.begin(), valid = peer.callback(login.url);
        final bad = switch (scenario) {
          'path' => valid.replace(path: '/other').toString(),
          'missing-id' => valid.replace(path: '/callback').toString(),
          'wrong-id' => valid.replace(path: '/callback/wrong-id').toString(),
          'port' => valid.replace(port: valid.port == 65535 ? valid.port - 1 : valid.port + 1).toString(),
          'duplicate-extra' => '${valid.toString()}&tenant=a&tenant=b',
          'encoded-code' => '${valid.toString()}&%63ode=second-secret',
          'duplicate-state' => '${valid.toString()}&state=second-secret',
          'duplicate-issuer' => '${valid.toString()}&iss=a&iss=second-secret',
          'userinfo' => valid.replace(userInfo: 'callback-secret').toString(),
          'fragment' => valid.replace(fragment: 'callback-secret').toString(),
          'empty-state' => valid.replace(queryParameters: {...valid.queryParameters, 'state': ''}).toString(),
          'wrong-state' => valid.replace(queryParameters: {...valid.queryParameters, 'state': 'callback-secret'}).toString(),
          'code-and-error' => '${valid.toString()}&error=denied&error_description=callback-secret',
          'oversized' => '${valid.toString()}&ignored=${'x' * 65537}',
          'missing-code' => valid.replace(queryParameters: {...valid.queryParameters}..remove('code')).toString(),
          'empty-code' => valid.replace(queryParameters: {...valid.queryParameters, 'code': ''}).toString(),
          _ => throw StateError(scenario),
        };
        Object? rejected;
        if (delivery == 'paste') {
          try { peer.auth.completeLogin(bad); } catch (error) { rejected = error; }
          expect(rejected, isA<McpFailure>());
          expect(rejected.toString(), isNot(anyOf(contains('callback-secret'), contains('second-secret'), contains('a+b'))));
        } else {
          final response = await peer.visit(Uri.parse(bad));
          expect(response.status, ['path', 'missing-id', 'wrong-id'].contains(scenario) ? 404 : 400);
          expect(response.body, isNot(anyOf(contains('callback-secret'), contains('second-secret'), contains('a+b'))));
        }
        expect(peer.forms, isEmpty);
        peer.auth.completeLogin(valid.toString());
        await login.done;
        expect(peer.forms, hasLength(1), reason: 'The rejected input must leave the intended login available.');
      });
    }
  }

  for (final state in ['matching', 'wrong', 'empty']) {
    test('Codex provider error callback requires $state state and redacts provider descriptions', () async {
      final login = await peer.begin();
      final callback = peer.callback(login.url);
      final error = callback.replace(queryParameters: {
        'error': 'access_denied', 'error_description': 'callback-secret',
        'state': state == 'matching' ? callback.queryParameters['state']! : state == 'wrong' ? 'unrelated' : '',
      });
      if (state == 'matching') {
        peer.auth.completeLogin(error.toString());
        await expectLater(login.done, throwsA(isA<McpFailure>().having((e) => e.message, 'redacted decline',
          allOf(contains('declined'), isNot(contains('callback-secret'))))));
      } else {
        expect(() => peer.auth.completeLogin(error.toString()), throwsA(isA<McpFailure>()));
        expect(peer.forms, isEmpty);
        peer.auth.completeLogin(callback.toString()); await login.done;
      }
      expect(peer.forms, hasLength(state == 'matching' ? 0 : 1));
    });
  }

  test('Codex callback-specific identity binds the complete MCP URL, including its tenant query', () async {
    final owners = [for (final tenant in ['one', 'two']) McpOAuth(peer.root.path, tenant, {
      'url': '${peer.origin}/mcp?tenant=$tenant', 'oauth': {'client_id': 'registered'},
    }, peer.http)];
    try {
      final first = await peer.begin(owners[0]), second = await peer.begin(owners[1]);
      final firstCallback = peer.callback(first.url), secondCallback = peer.callback(second.url);
      expect(firstCallback.path, isNot(secondCallback.path));
      // Match the active listener port and state, so only the wrong server ID
      // can reject the callback; a different-state denial would be a false proof.
      final misbound = firstCallback.replace(port: secondCallback.port, queryParameters: secondCallback.queryParameters);
      expect(() => owners[1].completeLogin(misbound.toString()), throwsA(isA<McpFailure>()));
      expect(peer.forms, isEmpty);
      owners[0].completeLogin(firstCallback.toString()); owners[1].completeLogin(secondCallback.toString());
      await Future.wait([first.done, second.done]);
      expect(peer.forms, hasLength(2));
    } finally { await Future.wait(owners.map((owner) => owner.close())); }
  });
}

class _Callback {
  _Callback(this.root, this.server) {
    auth = McpOAuth(root.path, 'callback', {'url': '$origin/mcp', 'oauth': {'client_id': 'registered'}}, http);
    server.listen(serve);
  }
  final Directory root;
  final HttpServer server;
  final http = HttpClient();
  final lifetime = TimeoutCancellationToken(const Duration(seconds: 10));
  final forms = <Map<String, String>>[];
  late final McpOAuth auth;
  bool issuerBound = false;
  String get origin => 'http://127.0.0.1:${server.port}';
  static Future<_Callback> start() async => _Callback(await Directory.systemTemp.createTemp('codex-oauth-callback-'),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<({Uri url, Future<void> done})> begin([McpOAuth? owner]) async {
    final url = Completer<Uri>();
    final done = (owner ?? auth).login(lifetime, (value) => url.complete(Uri.parse(value)));
    unawaited(done.then<void>((_) {}, onError: (Object error, StackTrace stack) { if (!url.isCompleted) url.completeError(error, stack); }));
    return (url: await url.future, done: done);
  }
  Uri callback(Uri url) => Uri.parse(url.queryParameters['redirect_uri']!).replace(queryParameters: {
    'code': 'a+b', 'state': url.queryParameters['state']!, if (issuerBound) 'iss': origin,
  });
  Future<({int status, String body})> visit(Uri uri) async {
    final request = await http.getUrl(uri).asCancellable(lifetime);
    final response = await request.close().asCancellable(lifetime);
    return (status: response.statusCode, body: await utf8.decoder.bind(response).join().asCancellable(lifetime));
  }
  Future<void> serve(HttpRequest request) async {
    final body = switch (request.uri.path) {
      '/resource-metadata' => {'resource': '$origin/mcp', 'authorization_servers': [origin]},
      '/.well-known/oauth-authorization-server' => {'issuer': origin, 'authorization_endpoint': '$origin/authorize',
        'token_endpoint': '$origin/token', 'code_challenge_methods_supported': ['S256'],
        'authorization_response_iss_parameter_supported': issuerBound},
      '/token' => {'access_token': 'accepted-token', 'token_type': 'Bearer', 'expires_in': 3600},
      _ => <String, Object?>{},
    };
    if (request.uri.path == '/mcp') {
      request.response.statusCode = 401;
      request.response.headers.set('www-authenticate', 'Bearer resource_metadata="$origin/resource-metadata"');
    } else if (request.uri.path == '/token') {
      forms.add(Uri.splitQueryString(await utf8.decoder.bind(request).join()));
    }
    request.response.headers.contentType = ContentType.json; request.response.write(jsonEncode(body));
    await request.response.close();
  }
  Future<void> close() async {
    lifetime.cancel(); await auth.close(); http.close(force: true); await server.close(force: true); await root.delete(recursive: true);
  }
}
