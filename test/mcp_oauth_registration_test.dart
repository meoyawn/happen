// Modified ports of Codex 5112ce6edeb9 rmcp-client/src/
// oauth_client_registration_tests.rs. Happen owns native loopback redirects
// and uses DCR or its configured client ID, not Codex's ChatGPT-hosted CIMD
// identity. Custom external callback URLs and explicit CIMD mode are absent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:mcp/src/oauth.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late _Registration peer;
  setUp(() async { peer = await _Registration.start(); });
  tearDown(() => peer.close());

  // All native DCR selection vectors. Happen does not gain a new registration
  // selector or configurable redirect merely to imitate Codex's absent surface.
  for (final (name, overrides) in <(String, Json)>[
    ('CIMD unsupported', {'client_id_metadata_document_supported': false}),
    ('auth methods omitted', {'token_endpoint_auth_methods_supported': null}),
    ('private-key auth advertised', {'token_endpoint_auth_methods_supported': ['private_key_jwt']}),
    ('issuer-bound callback', {'authorization_response_iss_parameter_supported': true}),
    ('CIMD advertised still uses Happen DCR', {}),
  ]) {
    test('Codex ordinary DCR selection preserves the exact native redirect: $name', () async {
      peer.overrides.addAll(overrides);
      final url = await peer.login();
      final query = url.queryParameters, redirect = Uri.parse(query['redirect_uri']!);
      expect(query['client_id'], 'dcr-client'); expect(query['scope'], 'read offline_access');
      expect(redirect.scheme, 'http'); expect(redirect.host, '127.0.0.1'); expect(redirect.port, isPositive);
      expect(redirect.path, name == 'issuer-bound callback' ? '/callback' : startsWith('/callback/'));
      expect(peer.registrations, hasLength(1)); expect(peer.tokens, hasLength(1));
      expect(peer.registrations.single['body']['redirect_uris'], [query['redirect_uri']]);
      final form = jsonObject(peer.tokens.single['form']);
      expect(form['redirect_uri'], query['redirect_uri']); expect(form['client_id'], 'dcr-client');
      expect(form['grant_type'], 'authorization_code'); expect(form['resource'], peer.url);
      expect(form['client_secret'], null); expect(peer.tokens.single['authorization'], null);
      expect(base64Url.encode(sha256.convert(ascii.encode(form['code_verifier'] as String)).bytes).replaceAll('=', ''), query['code_challenge']);
      expect(query['code_challenge_method'], 'S256');
      expect(peer.metadataRequests, hasLength(1));
    });
  }

  // Exact upstream exception matrix, including HTTPS, full issuer path, origin
  // and suffix-spoofing negatives. Only sockets are routed to an owned local
  // TLS peer; the real client still sees and validates every original URI.
  for (final (issuer, authorization, token, accepted) in [
    ('https://mcp.mercadopago.com/mcp', 'https://auth.mercadopago.com/mcp/authorization', 'https://mcp.mercadopago.com/oauth/token', true),
    ('https://agent.robinhood.com/mcp/trading', 'https://robinhood.com/oauth', 'https://api.robinhood.com/oauth2/token/', true),
    ('https://mcp.mercadopago.com.attacker.example/mcp', 'https://auth.mercadopago.com/mcp/authorization', 'https://mcp.mercadopago.com.attacker.example/oauth/token', false),
    ('https://mcp.mercadopago.com/mcp', 'https://auth.mercadopago.com/mcp/authorization', 'https://attacker.example/token', false),
    ('http://mcp.mercadopago.com/mcp', 'https://auth.mercadopago.com/mcp/authorization', 'http://mcp.mercadopago.com/oauth/token', false),
    ('https://agent.robinhood.com/mcp/attacker', 'https://robinhood.com/oauth', 'https://api.robinhood.com/oauth2/token/', false),
    ('https://agent.robinhood.com/mcp/trading', 'https://robinhood.com.attacker.example/oauth', 'https://api.robinhood.com/oauth2/token/', false),
  ]) {
    test('Codex ordinary OAuth provider exception is exact: $issuer -> $authorization -> $token', () async {
      await peer.routeProvider(issuer, authorization, token);
      if (accepted) {
        final url = await peer.login();
        expect(url.origin, Uri.parse(authorization).origin);
        expect(peer.tokens, hasLength(1)); expect(peer.tokens.single['host'], Uri.parse(token).host);
        expect(peer.tokens.single['form']['resource'], issuer);
      } else {
        await expectLater(peer.login(), throwsA(isA<McpFailure>()));
        expect(peer.registrations, isEmpty); expect(peer.tokens, isEmpty);
        expect(peer.opened, null);
      }
      if (issuer.startsWith('https:')) {
        expect(peer.metadataRequests, hasLength(1), reason: 'The real metadata trust gate must be reached, not an unrelated DNS/TLS failure.');
      } else {
        expect(peer.requests, isEmpty, reason: 'Happen rejects non-loopback plaintext before any contact, which is stricter than the upstream web-scheme guard.');
      }
    });
  }

  test('Codex verified OAuth issuer delegates authorization, token and registration to one origin', () async {
    peer.overrides.addAll({'authorization_endpoint': '${peer.delegateOrigin}/authorize', 'token_endpoint': '${peer.delegateOrigin}/token',
      'registration_endpoint': '${peer.delegateOrigin}/register'});
    final url = await peer.login();
    expect(url.origin, peer.delegateOrigin); expect(url.queryParameters['client_id'], 'dcr-client');
    expect(peer.metadataRequests, hasLength(1));
    expect(peer.registrations.single['side'], 'delegate'); expect(peer.tokens.single['side'], 'delegate');
    expect(peer.tokens.single['form']['code_verifier'], isNotEmpty);
    expect(peer.requests.where((r) => r['side'] != 'resource').map((r) => r['authorization']), everyElement(null));
    expect(peer.requests.where((r) => r['side'] != 'resource').map((r) => r['api_key']), everyElement(null));
  });

  // Upstream's Basic vector plus the distinct DCR-secret Post negotiation path.
  // Configured-secret refresh tests cannot catch a DCR reply omitting its method.
  for (final method in ['client_secret_basic', 'client_secret_post']) {
    test('Codex DCR same-origin redirect preserves resource headers and SDK $method wins', () async {
      peer.headers.addAll({'Authorization': 'Bearer resource-only-secret', 'X-Api-Key': 'resource-api-key-secret'});
      peer.overrides.addAll({'token_endpoint': '${peer.resourceOrigin}/token', 'registration_endpoint': '${peer.resourceOrigin}/register',
        'token_endpoint_auth_methods_supported': [method]});
      peer.registrationReply['client_secret'] = 'dummy-test-client-secret'; peer.redirect = true;
      final url = await peer.login();
      expect(peer.registrations.map((r) => r['path']), ['/register', '/register/']);
      for (final registration in peer.registrations) {
        expect(registration['authorization'], 'Bearer resource-only-secret');
        expect(registration['api_key'], 'resource-api-key-secret');
        expect(registration['content_type'], startsWith('application/json'));
        expect(registration['body']['redirect_uris'], [url.queryParameters['redirect_uri']]);
      }
      final exchange = peer.tokens.single, form = jsonObject(exchange['form']);
      expect(exchange['api_key'], 'resource-api-key-secret');
      expect(form['redirect_uri'], url.queryParameters['redirect_uri']);
      if (method == 'client_secret_basic') {
        expect(exchange['authorization'], 'Basic ${base64.encode(utf8.encode('dcr-client:dummy-test-client-secret'))}');
        expect(form['client_secret'], null); expect(form['client_id'], null);
      } else {
        // Post authentication owns the form, not the Authorization header:
        // a resource-origin gateway credential remains on its own origin.
        expect(exchange['authorization'], 'Bearer resource-only-secret');
        expect(form['client_id'], 'dcr-client'); expect(form['client_secret'], 'dummy-test-client-secret');
      }
      expect(peer.metadataRequests.single['authorization'], null); expect(peer.metadataRequests.single['api_key'], null);
      expect(peer.metadataRequests.single['user_agent'], 'happen-mcp-client/0.1.0');
    });
  }

  for (final (name, overrides, diagnostic) in <(String, Json, String)>[
    ('issuer-bound without issuer', {'authorization_response_iss_parameter_supported': true, 'issuer': null}, 'issuer'),
    ('DCR without registration endpoint', {'registration_endpoint': null}, 'client'),
  ]) {
    test('Codex ordinary OAuth rejects invalid $name before registration or code exchange', () async {
      peer.overrides.addAll(overrides);
      await expectLater(peer.login(), throwsA(isA<McpFailure>().having((e) => e.message.toLowerCase(), 'redacted registration guard', contains(diagnostic))));
      expect(peer.metadataRequests, hasLength(1)); expect(peer.registrations, isEmpty); expect(peer.tokens, isEmpty);
      expect(peer.opened, null);
    });
  }
}

class _Registration {
  _Registration(this.root, this.resource, this.issuerPeer, this.delegate) {
    for (final (side, server) in [('resource', resource), ('issuer', issuerPeer), ('delegate', delegate)]) {
      server.listen((request) => serve(side, request));
    }
  }
  final Directory root;
  final HttpServer resource, issuerPeer, delegate;
  final http = HttpClient();
  final lifetime = TimeoutCancellationToken(const Duration(seconds: 15));
  final requests = <Json>[], owners = <McpOAuth>[], extra = <HttpServer>[];
  final overrides = <String, dynamic>{}, registrationReply = <String, dynamic>{};
  final headers = <String, String>{};
  bool redirect = false;
  Uri? opened;
  String? providerIssuer, providerAuthorization, providerToken;
  String get resourceOrigin => providerIssuer == null ? 'http://127.0.0.1:${resource.port}' : Uri.parse(providerIssuer!).origin;
  String get issuerOrigin => providerIssuer == null ? 'http://127.0.0.1:${issuerPeer.port}' : Uri.parse(providerIssuer!).origin;
  String get delegateOrigin => 'http://127.0.0.1:${delegate.port}';
  String get url => providerIssuer ?? '$resourceOrigin/mcp';
  String get issuer => providerIssuer ?? '$issuerOrigin/mcp';
  List<Json> get registrations => [for (final r in requests) if (r['method'] == 'POST' && ['/register', '/register/'].contains(r['path'])) r];
  List<Json> get tokens => [for (final r in requests) if (r['method'] == 'POST' && r['path'] == Uri.parse(providerToken ?? '$issuerOrigin/token').path) r];
  List<Json> get metadataRequests => [for (final r in requests) if ((r['path'] as String).startsWith('/.well-known/oauth-authorization-server')) r];
  static Future<_Registration> start() async => _Registration(await Directory.systemTemp.createTemp('codex-oauth-registration-'),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0), await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> routeProvider(String issuer, String authorization, String token) async {
    providerIssuer = issuer; providerAuthorization = authorization; providerToken = token;
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, SecurityContext()
      ..useCertificateChain('test/fixtures/tls/cert.pem.txt')..usePrivateKey('test/fixtures/tls/key.pem.txt'));
    extra.add(server); server.listen((request) => serve('provider', request));
    // No DNS or external provider contact. This test-only socket route keeps
    // URI origins intact; trust is restricted to the checked-in fixture cert.
    final certificate = (await File('test/fixtures/tls/cert.pem.txt').readAsString()).trim();
    http.findProxy = (_) => 'DIRECT';
    http.connectionFactory = (uri, _, _) => uri.scheme == 'https'
      ? SecureSocket.startConnect(InternetAddress.loopbackIPv4, server.port, onBadCertificate: (cert) => cert.pem.trim() == certificate)
      : Socket.startConnect(InternetAddress.loopbackIPv4, resource.port);
  }
  Future<Uri> login() async {
    final auth = McpOAuth(root.path, 'registration', {'url': url, 'headers': headers, 'oauth': {'scopes': ['read']}}, http);
    owners.add(auth);
    await auth.login(lifetime, (value) {
      opened = Uri.parse(value);
      final callback = Uri.parse(opened!.queryParameters['redirect_uri']!).replace(queryParameters: {
        'code': 'valid-code', 'state': opened!.queryParameters['state']!,
        if (overrides['authorization_response_iss_parameter_supported'] == true) 'iss': issuer,
      });
      auth.completeLogin(callback.toString());
    });
    return opened!;
  }
  Future<void> serve(String side, HttpRequest request) async {
    final path = request.uri.path;
    final record = <String, dynamic>{'side': side, 'host': request.headers.value('host')?.split(':').first,
      'method': request.method, 'path': path, 'authorization': request.headers.value('authorization'),
      'api_key': request.headers.value('x-api-key'), 'user_agent': request.headers.value('user-agent'), 'content_type': request.headers.value('content-type')};
    requests.add(record);
    Json body = {};
    if (request.method == 'GET' && path == Uri.parse(url).path && (side == 'resource' || side == 'provider')) {
      request.response.statusCode = 401; request.response.headers.set('www-authenticate', 'Bearer resource_metadata="$resourceOrigin/resource-metadata"');
    } else if (path == '/resource-metadata') {
      body = {'resource': url, 'authorization_servers': [issuer]};
    } else if (path.startsWith('/.well-known/oauth-authorization-server')) {
      body = {'issuer': issuer, 'authorization_endpoint': providerAuthorization ?? '$issuerOrigin/authorize',
        'token_endpoint': providerToken ?? '$issuerOrigin/token', 'registration_endpoint': '$issuerOrigin/register',
        'client_id_metadata_document_supported': true, 'token_endpoint_auth_methods_supported': ['none'],
        'code_challenge_methods_supported': ['S256'], 'scopes_supported': ['read', 'offline_access'], ...overrides};
    } else if (request.method == 'POST' && ['/register', '/register/'].contains(path)) {
      final registration = jsonObject(jsonDecode(await utf8.decoder.bind(request).join())); record['body'] = registration;
      if (path == '/register' && redirect) {
        request.response.statusCode = 307; request.response.headers.set('location', '/register/');
      } else {
        request.response.statusCode = 201;
        body = {'client_id': 'dcr-client', 'redirect_uris': registration['redirect_uris'], ...registrationReply};
      }
    } else if (request.method == 'POST' && path == Uri.parse(providerToken ?? '$issuerOrigin/token').path) {
      record['form'] = Uri.splitQueryString(await utf8.decoder.bind(request).join());
      body = {'access_token': 'accepted-token', 'refresh_token': 'rotating-token', 'token_type': 'Bearer', 'expires_in': 3600};
    } else { request.response.statusCode = 404; }
    request.response.headers.contentType = ContentType.json; request.response.write(jsonEncode(body)); await request.response.close();
  }
  Future<void> close() async {
    lifetime.cancel(); await Future.wait(owners.map((owner) => owner.close())); http.close(force: true);
    await Future.wait([resource.close(force: true), issuerPeer.close(force: true), delegate.close(force: true), for (final server in extra) server.close(force: true)]);
    await root.delete(recursive: true);
  }
}
