// Modified ports of opencode 9ff07c0d3a9e packages/core/test/mcp-oauth.test.ts.
// Real HTTP/callback/disk boundaries; no SDK mocks or credential-store seams.
// Happen selects one credential per server+URL, not OpenCode's account rows.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/src/oauth.dart';
import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late _Peer peer;
  setUp(() async { peer = await _Peer.start(); });
  tearDown(() => peer.close());

  test('OpenCode: loopback callback waits for exchange and rejects a duplicate', () async {
    final auth = peer.auth(), login = await peer.login(auth);
    final callback = peer.callback(login.url);
    peer.tokenGate = Completer<void>();
    final exchanging = peer.exchanges.stream.first;
    var responded = false;
    final response = peer.visit(callback).then((value) { responded = true; return value; });
    await exchanging;
    expect(responded, false, reason: 'The browser must not report success before token admission.');
    expect((await peer.visit(callback)).$1, 409);
    peer.tokenGate!.complete();
    expect((await response).$1, 200);
    await login.done;
    expect(peer.tokenRequests.single['code'], 'accepted');
    expect(peer.tokenRequests.single['code_verifier'], isNotEmpty);
    expect(peer.tokenRequests.single['resource'], peer.url);
    expect(await auth.authorization(peer.lifetime), 'access');
  });

  test('OpenCode: preflights and parameterless callbacks keep waiting', () async {
    final login = await peer.login(peer.auth());
    final callback = Uri.parse(login.url.queryParameters['redirect_uri']!);
    expect(callback.path, '/callback');
    for (final method in ['OPTIONS', 'GET']) {
      expect((await peer.visit(callback, method: method)).$1, 400);
    }
    expect((await peer.visit(peer.callback(login.url))).$1, 200);
    await login.done;
  });

  test('OpenCode: wrong pasted URL keeps waiting and whitespace is accepted', () async {
    final auth = peer.auth(), login = await peer.login(auth), callback = peer.callback(login.url);
    expect(() => auth.completeLogin('accepted'), throwsA(isA<McpFailure>()));
    expect(() => auth.completeLogin(callback.replace(queryParameters: {...callback.queryParameters, 'state': 'another-sign-in'}).toString()), throwsA(isA<McpFailure>()));
    auth.completeLogin(' $callback\n');
    await login.done;
    expect(peer.tokenRequests.single['code'], 'accepted');
  });

  test('OpenCode: rejected token exchange produces a failed callback page', () async {
    peer.tokenError = true;
    final login = await peer.login(peer.auth());
    final failed = expectLater(login.done, throwsA(isA<McpFailure>()));
    final response = await peer.visit(peer.callback(login.url));
    expect(response.$1, 400);
    expect(response.$2, contains('Authorization failed'));
    expect(response.$2, isNot(contains('private-token-error')));
    await failed;
    expect(await Directory('${peer.root.path}/mcp-auth').exists(), false);
  });

  for (final metadata in [true, false]) {
    test('OpenCode: persisted refresh uses configured resource without resource metadata: metadata=$metadata', () async {
      peer.metadata = metadata;
      peer.advertisePkce = false;
      final auth = peer.auth(options: {'client_id': 'client'}), login = await peer.login(auth);
      expect((await peer.visit(peer.callback(login.url))).$1, 200);
      await login.done;
      await peer.expire();
      peer.tokenResponse = {'access_token': 'next', 'token_type': 'Bearer'};
      final next = peer.auth(options: {'client_id': 'client'});
      expect(await next.authorization(peer.lifetime), 'next');
      expect(peer.tokenRequests.last['grant_type'], 'refresh_token');
      expect(peer.tokenRequests.last['refresh_token'], 'refresh');
      expect(peer.tokenRequests.last['resource'], peer.url);
      expect((await peer.saved())['refresh_token'], 'refresh');
      expect((await peer.saved())['issuer'], peer.origin);
      expect(await next.authorization(peer.lifetime), 'next', reason: 'No expiry means non-expiring, not immediately expired.');
      expect(peer.tokenRequests, hasLength(2));
    });
  }

  test('OpenCode: a connection made anonymously does not adopt a later login', () async {
    final anonymous = peer.auth();
    expect(await anonymous.authorization(peer.lifetime), null);
    final login = await peer.login(peer.auth());
    await peer.visit(peer.callback(login.url)); await login.done;
    expect(await anonymous.authorization(peer.lifetime), null);
    expect(await anonymous.credentialsChanged(), true, reason: 'The manager must select a new connection generation.');
  });

  test('OpenCode: refreshing a selected credential never adopts or overwrites a later sign-in', () async {
    final selected = peer.auth(), first = await peer.login(selected);
    await peer.visit(peer.callback(first.url)); await first.done;
    expect(await selected.authorization(peer.lifetime), 'access');
    peer.tokenResponse = {'access_token': 'other', 'refresh_token': 'other-refresh', 'token_type': 'Bearer', 'expires_in': 3600};
    final later = await peer.login(peer.auth());
    await peer.visit(peer.callback(later.url)); await later.done;
    selected.challenge(401, [], sentToken: true);
    await expectLater(selected.authorization(peer.lifetime), throwsA(isA<McpFailure>()));
    expect((await peer.saved())['access_token'], 'other');
    expect(peer.tokenRequests, hasLength(2), reason: 'A retired generation may not refresh another sign-in.');
  });

  for (final rotated in [false, true]) {
    test('OpenCode: invalidated credentials are removed only while still holding the presented token: rotated=$rotated', () async {
      final auth = peer.auth(), login = await peer.login(auth);
      await peer.visit(peer.callback(login.url)); await login.done;
      await peer.expire();
      final next = peer.auth();
      peer.tokenError = true; peer.tokenGate = Completer<void>();
      final exchanging = peer.exchanges.stream.first;
      final failed = expectLater(next.authorization(peer.lifetime), throwsA(isA<McpFailure>()));
      await exchanging;
      if (rotated) {
        await peer.writeSaved({...await peer.saved(), 'access_token': 'rotated', 'refresh_token': 'rotated-refresh'});
      }
      peer.tokenGate!.complete(); await failed;
      expect(await peer.credentialFile().then((file) => file.exists()), rotated);
      if (rotated) expect((await peer.saved())['access_token'], 'rotated');
    });
  }

  test('OpenCode: concurrent owners share refreshes of the same rotating token', () async {
    final login = await peer.login(peer.auth());
    await peer.visit(peer.callback(login.url)); await login.done;
    await peer.expire();
    peer.tokenGate = Completer<void>();
    final exchanging = peer.exchanges.stream.first;
    final a = peer.auth(), b = peer.auth();
    final first = a.authorization(peer.lifetime), second = b.authorization(peer.lifetime);
    await exchanging;
    // A third owner's disk read observes both existing attempts without any
    // scheduler/timing assertion. The token gate keeps the refresh in flight.
    expect(await peer.auth().credentialsChanged(), false);
    peer.tokenResponse = {'access_token': 'next', 'refresh_token': 'next-refresh', 'token_type': 'Bearer'};
    peer.tokenGate!.complete();
    expect(await Future.wait([first, second]), ['next', 'next']);
    expect(peer.tokenRequests.where((form) => form['grant_type'] == 'refresh_token'), hasLength(1));
  });

  test('OpenCode: configured redirect path and fixed port reach the listener', () async {
    final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), port = reservation.port;
    await reservation.close();
    final redirect = 'http://127.0.0.1:$port/fixed-callback';
    final login = await peer.login(peer.auth(options: {'redirect_uri': redirect}));
    expect(login.url.queryParameters['redirect_uri'], redirect);
    expect((await peer.visit(peer.callback(login.url))).$1, 200);
    await login.done;
  });

  for (final redirect in ['not a URL', 'file:///callback', 'https://remote.example/callback']) {
    test('OpenCode: rejects an invalid loopback redirect: $redirect', () async {
      await expectLater(peer.auth(options: {'redirect_uri': redirect}).login(peer.lifetime, (_) {}), throwsA(isA<McpFailure>()));
      expect(peer.registrations, isEmpty);
    });
  }

  test('OpenCode: rejects non-HTTP authorization endpoints before opening the browser', () async {
    peer.authorizationEndpoint = 'file:///authorize';
    await expectLater(peer.auth().login(peer.lifetime, (_) => fail('Must not open an unsafe authorization URL')), throwsA(isA<McpFailure>()));
  });

  for (final echoedQuery in [false, true]) {
    test('OpenCode: resource metadata discovery and identity exclude transport query: echo=$echoedQuery', () async {
      peer.resourceMetadata = true; peer.echoedQuery = echoedQuery;
      final auth = peer.auth(url: '${peer.url}?codemode=false'), login = await peer.login(auth);
      await peer.visit(peer.callback(login.url)); await login.done;
      expect(peer.paths.where((path) => path.startsWith('/.well-known/oauth-protected-resource')), everyElement(isNot(contains('codemode'))));
      expect(peer.tokenRequests.single['resource'], peer.url);
    });
  }

  test('OpenCode: a 401 challenge locates non-well-known resource metadata', () async {
    peer.resourceMetadata = true; peer.customMetadata = true;
    final login = await peer.login(peer.auth());
    expect(login.url.path, '/authorize');
    expect(peer.paths, contains('/custom/metadata'));
    await peer.visit(peer.callback(login.url)); await login.done;
  });

  test('OpenCode: explicit authorization metadata works when the resource publishes none', () async {
    final auth = peer.auth(url: '${peer.origin}/unpublished', options: {'client_id': 'client',
      'auth_server_metadata_url': '${peer.origin}/configured-metadata'});
    final login = await peer.login(auth);
    expect(login.url.path, '/authorize');
    expect(login.url.queryParameters['resource'], '${peer.origin}/unpublished');
    await peer.visit(peer.callback(login.url)); await login.done;
    await peer.expire();
    expect(await peer.auth(url: '${peer.origin}/unpublished', options: {'client_id': 'client',
      'auth_server_metadata_url': '${peer.origin}/configured-metadata'}).authorization(peer.lifetime), 'access');
    expect(peer.paths, contains('/configured-metadata'));
  });

  test('OpenCode: requests offline_access without forcing a consent prompt', () async {
    final login = await peer.login(peer.auth(options: {'client_id': 'client', 'scopes': ['read']}));
    expect(login.url.queryParameters['scope']!.split(' '), ['read', 'offline_access']);
    expect(login.url.queryParameters.containsKey('prompt'), false);
    await peer.visit(peer.callback(login.url)); await login.done;
  });

  for (final registration in ['public_metadata', 'confidential', 'custom_redirect', 'static']) {
    test('OpenCode: client registration selection: $registration', () async {
      peer.cimd = true; peer.publicClient = registration != 'confidential';
      final metadataUrl = '${peer.origin}/happen-client.json';
      final options = <String, dynamic>{'client_metadata_url': metadataUrl,
        if (registration == 'static') 'client_id': 'static-client',
        if (registration == 'custom_redirect') 'redirect_uri': 'http://127.0.0.1:0/custom'};
      final login = await peer.login(peer.auth(options: options));
      final expected = registration == 'public_metadata' ? metadataUrl : registration == 'static' ? 'static-client' : 'registered';
      expect(login.url.queryParameters['client_id'], expected);
      expect(peer.registrations, hasLength(['confidential', 'custom_redirect'].contains(registration) ? 1 : 0));
      await peer.visit(peer.callback(login.url)); await login.done;
      expect(peer.tokenRequests.single['client_id'], expected);
      if (peer.registrations.isNotEmpty) expect(peer.registrations.single['client_name'], 'Happen');
    });
  }

  test('OpenCode: later login reuses the client registered by an earlier login', () async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final login = await peer.login(peer.auth());
      expect(login.url.queryParameters['client_id'], 'registered');
      await peer.visit(peer.callback(login.url)); await login.done;
    }
    expect(peer.registrations, hasLength(1));
    expect(peer.tokenRequests, hasLength(2));
  });
}

class _Peer {
  _Peer(this.root, this.server);
  final Directory root;
  final HttpServer server;
  final http = HttpClient();
  final lifetime = CancellationToken();
  final owners = <McpOAuth>[];
  final registrations = <Json>[], tokenRequests = <Map<String, String>>[], paths = <String>[];
  final exchanges = StreamController<void>.broadcast();
  bool metadata = true, advertisePkce = true, resourceMetadata = false, customMetadata = false,
    echoedQuery = false, tokenError = false, cimd = false, publicClient = true;
  String? authorizationEndpoint;
  Completer<void>? tokenGate;
  Json tokenResponse = {'access_token': 'access', 'refresh_token': 'refresh', 'token_type': 'Bearer', 'expires_in': 3600};
  String get origin => 'http://127.0.0.1:${server.port}';
  String get url => '$origin/mcp';
  static Future<_Peer> start() async {
    final peer = _Peer(await Directory.systemTemp.createTemp('opencode-mcp-oauth-'), await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    peer.server.listen(peer.serve); return peer;
  }
  McpOAuth auth({String? url, Json options = const {}}) {
    final owner = McpOAuth(root.path, 'test', {'url': url ?? this.url, 'oauth': options}, http);
    owners.add(owner); return owner;
  }
  Future<({Uri url, Future<void> done})> login(McpOAuth auth) async {
    final url = Completer<Uri>();
    final done = auth.login(lifetime, (value) => url.complete(Uri.parse(value)));
    unawaited(done.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      if (!url.isCompleted) url.completeError(error, stack);
    }));
    return (url: await url.future, done: done);
  }
  Uri callback(Uri authorization) => Uri.parse(authorization.queryParameters['redirect_uri']!).replace(queryParameters: {
    'state': authorization.queryParameters['state']!, 'code': 'accepted',
  });
  Future<(int, String)> visit(Uri uri, {String method = 'GET'}) async {
    final response = await (await http.openUrl(method, uri)).close();
    return (response.statusCode, await utf8.decoder.bind(response).join());
  }
  Future<File> credentialFile() async => File('${root.path}/mcp-auth/${shaKey('test', url)}.json');
  Future<Json> saved() async => jsonObject(jsonDecode(await (await credentialFile()).readAsString()));
  Future<void> writeSaved(Json value) async => (await credentialFile()).writeAsString(jsonEncode(value)).then((_) {});
  Future<void> expire() async => writeSaved({...await saved(), 'expires_at': 1});
  Future<void> serve(HttpRequest request) async {
    paths.add(request.uri.toString());
    Json? result;
    final path = request.uri.path;
    if (path == '/mcp') {
      request.response.statusCode = 401;
      if (resourceMetadata && customMetadata) request.response.headers.set('WWW-Authenticate', 'Bearer resource_metadata="$origin/custom/metadata"');
    } else if ((path == '/.well-known/oauth-protected-resource/mcp' && !customMetadata || path == '/custom/metadata') && resourceMetadata) {
      result = {'resource': '$url${echoedQuery ? '?codemode=false' : ''}', 'authorization_servers': [origin]};
    } else if (path == '/configured-metadata' || path == '/.well-known/oauth-authorization-server' && metadata) {
      result = {'issuer': origin, 'authorization_endpoint': authorizationEndpoint ?? '$origin/authorize', 'token_endpoint': '$origin/token',
        'registration_endpoint': '$origin/register', 'response_types_supported': ['code'],
        'scopes_supported': ['read', 'offline_access'], if (advertisePkce) 'code_challenge_methods_supported': ['S256'],
        if (cimd) 'client_id_metadata_document_supported': true,
        'token_endpoint_auth_methods_supported': [publicClient ? 'none' : 'client_secret_post']};
    } else if (path == '/register') {
      registrations.add(jsonObject(jsonDecode(await utf8.decoder.bind(request).join())));
      result = {'client_id': 'registered', 'token_endpoint_auth_method': 'none'};
    } else if (path == '/token') {
      tokenRequests.add(Uri.splitQueryString(await utf8.decoder.bind(request).join())); exchanges.add(null);
      await tokenGate?.future;
      if (tokenError) { request.response.statusCode = 400; result = {'error': 'invalid_grant', 'error_description': 'private-token-error'}; }
      else { result = tokenResponse; }
    } else { request.response.statusCode = 404; }
    if (result != null) { request.response.headers.contentType = ContentType.json; request.response.write(jsonEncode(result)); }
    await request.response.close();
  }
  Future<void> close() async {
    lifetime.cancel(); if (tokenGate?.isCompleted == false) tokenGate!.complete();
    await Future.wait(owners.map((owner) => owner.close()));
    http.close(force: true); await server.close(force: true); await exchanges.close(); await root.delete(recursive: true);
  }
}
