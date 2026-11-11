import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('MCP OAuth receives callbacks at the client, persists privately, refreshes, and signs out across owners', () async {
    // The configured callback port belongs to the remote host. Reserving it
    // here proves browser sign-in does not try to bind that port on the server.
    final remoteCallback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => remoteCallback.close(force: true));
    final fixture = await _OAuthFixture.start(callbackPort: remoteCallback.port);
    addTearDown(fixture.close);
    var server = await fixture.happen();
    var client = await AgentClient.connect(server.uri);
    final observer = await AgentClient.connect(server.uri);
    final observed = <Json>[];
    final events = observer.events.stream.listen(observed.add);
    final token = CancellationToken();
    try {
      final before = await client.mcpInventory(cancellation: token);
      expect(before['servers'][0]['state'], 'authentication_required');
      expect(before['servers'][0]['oauth_supported'], true);
      final url = Completer<Uri>();
      final privateEvents = client.events.stream.listen((event) {
        if (event['type'] == 'mcp.auth.login') url.complete(Uri.parse(event['url'] as String));
      });
      final login = client.mcpLogin('strength', 'first', cancellation: token);
      final authorization = await Future.any([url.future, login.then<Uri>((_) => throw StateError('Missing browser URL'))])
        .timeout(const Duration(seconds: 10));
      expect(Uri.parse(authorization.queryParameters['redirect_uri']!).port, isNot(remoteCallback.port));
      expect(authorization.queryParameters['scope']!.split(' '), containsAll(['training', 'offline_access']));
      expect(authorization.queryParameters['resource'], fixture.resource);
      expect((await client.mcpInventory(cancellation: token))['servers'][0]['auth_status'], 'signing_in');
      // A second client cannot complete another client's login.
      final callback = fixture.callback(authorization);
      await expectLater(observer.request('mcp.auth.callback', {
        'server': 'strength', 'login_id': 'first', 'callback_url': callback.toString(),
      }), throwsA(isA<StateError>()));
      final wrongState = callback.replace(queryParameters: {...callback.queryParameters, 'state': 'unrelated'});
      expect(await fixture.visit(wrongState), 400);
      expect(await fixture.visit(callback), 200);
      expect((await login)['state'], 'ready');
      await privateEvents.cancel();
      final ready = await client.mcpInventory(verbose: true, cancellation: token);
      expect(ready['servers'][0]['auth_status'], 'oauth');
      expect(ready['servers'][0]['tools'], ['workout_history']);
      expect(jsonEncode(ready), isNot(contains('opaque-')));
      expect(observed.where((event) => event['type'] == 'mcp.auth.login'), isEmpty);
      expect(fixture.registrationCount, 1);
      expect(fixture.exchangeCount, 1);
      expect(fixture.leakedHeaders, isEmpty);
      final result = jsonObject(await callIsolate(server.network.port, 'mcp.call', {
        'name': 'mcp__strength__workout_history', 'arguments': <String, Object?>{},
      }, cancellation: token));
      expect(result['structuredContent'], {'workouts': 3});
      fixture.access = 'opaque-revoked';
      final rejected = jsonObject(await callIsolate(server.network.port, 'mcp.call', {
        'name': 'mcp__strength__workout_history', 'arguments': <String, Object?>{},
      }, cancellation: token));
      expect(rejected, {'isError': true, 'content': [{'type': 'text', 'text': 'Authentication required'}],
        '_meta': {'mcp/www_authenticate': ['Basic realm="ignored", Bearer resource_metadata="${fixture.issuer}/resource", scope="training"']}});
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((await client.mcpInventory(cancellation: token))['servers'][0]['tool_count'] != 1) {
        if (DateTime.now().isAfter(deadline)) fail('A rejected access token did not refresh');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(fixture.refreshCount, 1);
      expect(fixture.toolCalls, 2, reason: 'An interrupted tool call must never be replayed after refresh');
      final credentials = (await Directory('${fixture.root.path}/data/mcp-auth').list().toList()).whereType<File>().single;
      if (!Platform.isWindows) expect((await credentials.stat()).mode & 0x3f, 0);
      // Another live MCP owner starts with the same credentials. This also
      // represents the desktop observing a later CLI login/logout on disk.
      final otherHttp = HttpClient();
      final other = McpManager(http: otherHttp, directory: '${fixture.root.path}/data', onEvent: (_, _) {});
      addTearDown(() async { await other.close(); otherHttp.close(force: true); });
      await other.configure({'strength': {'url': fixture.resource}}, token);
      expect((await other.inventory(token))['servers'][0]['tool_count'], 1);
      await client.close();
      await server.close();
      final saved = jsonObject(jsonDecode(await credentials.readAsString()));
      saved['expires_at'] = 0;
      await credentials.writeAsString(jsonEncode(saved));
      server = await fixture.happen();
      client = await AgentClient.connect(server.uri);
      expect((await client.mcpInventory(cancellation: token))['servers'][0]['tool_count'], 1);
      expect(fixture.refreshCount, 2);
      expect(fixture.registrationCount, 1, reason: 'Restart reuses the saved OAuth client');
      await client.mcpLogout('strength', cancellation: token);
      expect((await other.inventory(token))['servers'][0]['state'], 'authentication_required');
      expect(await credentials.exists(), false);
    } finally {
      token.cancel();
      await events.cancel();
      await observer.close();
      await client.close();
      await server.close();
    }
  });

  for (final issuer in ['missing', 'wrong']) {
    test('MCP OAuth rejects $issuer callback issuer before exchanging a code', () async {
      final fixture = await _OAuthFixture.start();
      addTearDown(fixture.close);
      final server = await fixture.happen();
      final client = await AgentClient.connect(server.uri);
      final token = CancellationToken();
      final url = Completer<Uri>();
      final subscription = client.events.stream.listen((event) {
        if (event['type'] == 'mcp.auth.login') url.complete(Uri.parse(event['url'] as String));
      });
      try {
        final failed = expectLater(client.mcpLogin('strength', 'issuer', cancellation: token), throwsA(isA<StateError>()));
        final authorization = await url.future.timeout(const Duration(seconds: 10));
        final callback = fixture.callback(authorization);
        final query = {...callback.queryParameters};
        if (issuer == 'missing') { query.remove('iss'); } else { query['iss'] = 'https://unrelated.example'; }
        expect(await fixture.visit(callback.replace(queryParameters: query)), 400);
        await failed;
        expect(fixture.exchangeCount, 0);
        expect(await Directory('${fixture.root.path}/data/mcp-auth').exists(), false);
      } finally {
        token.cancel();
        await subscription.cancel();
        await client.close();
        await server.close();
      }
    });
  }

  test('cancelling MCP login closes its listener and allows a new callback-specific login', () async {
    final fixture = await _OAuthFixture.start(issuerResponses: false);
    addTearDown(fixture.close);
    final server = await fixture.happen();
    final client = await AgentClient.connect(server.uri);
    final urls = StreamController<Uri>();
    final subscription = client.events.stream.listen((event) {
      if (event['type'] == 'mcp.auth.login') urls.add(Uri.parse(event['url'] as String));
    });
    final reader = StreamIterator(urls.stream);
    var token = CancellationToken();
    try {
      final cancelled = expectLater(client.mcpLogin('strength', 'cancel', cancellation: token), throwsA(isA<CancelledException>()));
      expect(await reader.moveNext(), true);
      final first = fixture.callback(reader.current);
      expect(first.path, startsWith('/callback/'));
      token.cancel();
      await cancelled;
      // The next request on the same WebSocket is ordered after cancellation.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((await client.mcpInventory(cancellation: CancellationToken()))['servers'][0]['auth_status'] == 'signing_in') {
        if (DateTime.now().isAfter(deadline)) fail('Cancelled sign-in still owns its listener');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await expectLater(fixture.visit(first), throwsA(isA<SocketException>()));
      token = CancellationToken();
      final login = client.mcpLogin('strength', 'retry', cancellation: token);
      expect(await reader.moveNext(), true);
      final callback = fixture.callback(reader.current);
      await client.request('mcp.auth.callback', {'server': 'strength', 'login_id': 'retry', 'callback_url': callback.toString()});
      expect((await login)['tool_count'], 1);
      expect(fixture.exchangeCount, 1);
    } finally {
      token.cancel();
      await subscription.cancel();
      await reader.cancel();
      await urls.close();
      await client.close();
      await server.close();
    }
  });

  test('local CLI MCP login accepts a hidden callback and list/logout share credentials', () async {
    final fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final server = await fixture.happen();
    final client = await AgentClient.connect(server.uri);
    Process? process;
    try {
      final command = ['run', 'packages/cli/bin/happen.dart', '--data-dir', fixture.root.path,
        '--config', '${fixture.root.path}/config.yaml', 'mcp'];
      process = await Process.start(Platform.resolvedExecutable, [...command, 'login', 'strength', '--no-browser']);
      final output = <String>[];
      final errors = process.stderr.drain<void>();
      final subscription = utf8.decoder.bind(process.stdout).transform(const LineSplitter()).listen((line) {
        output.add(line);
        if (line.startsWith('${fixture.issuer}/authorize?')) {
          process!.stdin.writeln(fixture.callback(Uri.parse(line)));
        }
      });
      expect(await process.exitCode.timeout(const Duration(seconds: 45)), 0);
      await errors;
      await subscription.cancel();
      expect(output.join('\n'), contains('Connected to strength (1 tools)'));
      expect(output.join('\n'), isNot(contains('opaque-')));
      final listing = await Process.run(Platform.resolvedExecutable, [...command, 'list', '--json']);
      expect(listing.exitCode, 0);
      expect(jsonObject(jsonDecode((listing.stdout as String).substring((listing.stdout as String).indexOf('{'))))['servers'][0]['auth_status'], 'oauth');
      final logout = await Process.run(Platform.resolvedExecutable, [...command, 'logout', 'strength']);
      expect(logout.exitCode, 0);
      expect((await client.mcpInventory(cancellation: CancellationToken()))['servers'][0]['tool_count'], 0);
    } finally {
      process?.kill();
      await client.close();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

class _OAuthFixture {
  _OAuthFixture(this.root, this.peer, this.authorization, this.issuerResponses);
  final Directory root;
  final HttpServer peer, authorization;
  final bool issuerResponses;
  final leakedHeaders = <String>[];
  int registrationCount = 0, exchangeCount = 0, refreshCount = 0, toolCalls = 0;
  String access = 'opaque-access', refresh = 'opaque-refresh';
  Json registered = {};
  Uri? requested;
  String get resource => 'http://127.0.0.1:${peer.port}/mcp';
  String get issuer => 'http://127.0.0.1:${authorization.port}';

  static Future<_OAuthFixture> start({bool issuerResponses = true, int? callbackPort}) async {
    final fixture = _OAuthFixture(await Directory.systemTemp.createTemp('happen-mcp-oauth-'),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0), issuerResponses);
    fixture.peer.listen(fixture._resource);
    fixture.authorization.listen(fixture._authorization);
    await File('${fixture.root.path}/config.yaml').writeAsString(jsonEncode({'mcp_servers': {
      'strength': {'url': fixture.resource, 'headers': {'X-Resource-Private': 'private-resource-header'},
        if (callbackPort != null) 'oauth': {'callback_port': callbackPort}},
    }}));
    return fixture;
  }

  Future<AgentServer> happen() => AgentServer.startEmbedded(directory: '${root.path}/data', configPath: '${root.path}/config.yaml');

  Uri callback(Uri url) {
    requested = url;
    return Uri.parse(url.queryParameters['redirect_uri']!).replace(queryParameters: {
      'code': 'opaque-code', 'state': url.queryParameters['state']!, if (issuerResponses) 'iss': issuer,
    });
  }

  Future<int> visit(Uri uri) async {
    final http = HttpClient();
    try {
      final response = await (await http.getUrl(uri)).close();
      await response.drain<void>();
      return response.statusCode;
    } finally { http.close(force: true); }
  }

  Future<void> _resource(HttpRequest request) async {
    if (request.method == 'GET') {
      request.response.statusCode = 401;
      request.response.headers.set('WWW-Authenticate', 'Bearer resource_metadata="$issuer/resource", scope="training"');
      await request.response.close(); return;
    }
    final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
    if (body['method'] == 'tools/call') toolCalls++;
    if (request.headers.value('authorization') != 'Bearer $access') {
      request.response.statusCode = 401;
      request.response.headers.set('WWW-Authenticate', 'Basic realm="ignored", Bearer resource_metadata="$issuer/resource", scope="training"');
      await request.response.close();
      return;
    }
    final result = switch (body['method']) {
      'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {'tools': <String, Object?>{}}},
      'tools/list' => {'tools': [{'name': 'workout_history', 'description': 'Read workout history', 'inputSchema': {'type': 'object'}}]},
      _ => {'structuredContent': {'workouts': 3}, 'content': <Object?>[]},
    };
    await _reply(request, {'jsonrpc': '2.0', 'id': body['id'], 'result': result});
  }

  Future<void> _authorization(HttpRequest request) async {
    if (request.headers.value('X-Resource-Private') != null || request.headers.value('Authorization') != null) leakedHeaders.add(request.uri.path);
    switch (request.uri.path) {
      case '/resource':
        await _reply(request, {'resource': resource, 'authorization_servers': [issuer], 'scopes_supported': ['training']});
      case '/.well-known/oauth-authorization-server':
        await _reply(request, {'issuer': issuer, 'authorization_endpoint': '$issuer/authorize', 'token_endpoint': '$issuer/token',
          'registration_endpoint': '$issuer/register', 'code_challenge_methods_supported': ['S256'],
          'authorization_response_iss_parameter_supported': issuerResponses, 'scopes_supported': ['training', 'offline_access']});
      case '/register':
        registrationCount++;
        registered = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        expect(registered['client_name'], 'Happen');
        expect(registered['token_endpoint_auth_method'], 'none');
        expect(registered['grant_types'], contains('refresh_token'));
        await _reply(request, {'client_id': 'happen-fixture', 'token_endpoint_auth_method': 'none'});
      case '/token':
        final form = Uri.splitQueryString(await utf8.decoder.bind(request).join());
        expect(form['client_id'], 'happen-fixture');
        expect(form['resource'], resource);
        if (form['grant_type'] == 'authorization_code') {
          exchangeCount++;
          expect(form['redirect_uri'], requested!.queryParameters['redirect_uri']);
          expect(registered['redirect_uris'], [form['redirect_uri']]);
          expect(base64Url.encode(sha256.convert(ascii.encode(form['code_verifier']!)).bytes).replaceAll('=', ''), requested!.queryParameters['code_challenge']);
        } else {
          refreshCount++;
          expect(form['refresh_token'] == refresh, true, reason: 'Refresh must use the current rotating credential');
          refresh = 'opaque-refresh-$refreshCount';
          access = 'opaque-access-$refreshCount';
        }
        await _reply(request, {'access_token': access, 'refresh_token': refresh, 'token_type': 'Bearer', 'expires_in': 3600});
      default:
        request.response.statusCode = 404;
        await request.response.close();
    }
  }

  Future<void> _reply(HttpRequest request, Json body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() async {
    await peer.close(force: true);
    await authorization.close(force: true);
    await root.delete(recursive: true);
  }
}
