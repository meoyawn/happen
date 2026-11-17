import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/web_gateway.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late HttpServer backend;
  late WebGateway gateway;
  late HttpClient http;
  late Uri url;
  late String key;
  var connections = 0;
  const origin = 'https://happen.example';
  const otherClient = 'https://client.example';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('happen-web-');
    key = '${newId()}${newId()}';
    await File('${root.path}/owner').writeAsString(key);
    await Process.run('chmod', ['600', '${root.path}/owner']);
    backend = await HttpServer.bind(InternetAddress('${root.path}/backend', type: InternetAddressType.unix), 0);
    connections = 0;
    backend.listen((request) async {
      connections++;
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(socket.add);
    });
    gateway = await WebGateway.start(socketPath: '${root.path}/backend',
      publicUrl: origin, ownerKeyFile: '${root.path}/owner', allowedOrigins: {otherClient}, port: 0);
    url = Uri.parse('http://127.0.0.1:${gateway.http.port}');
    http = HttpClient();
  });
  tearDown(() async {
    http.close(force: true);
    await gateway.close();
    await backend.close(force: true);
    await root.delete(recursive: true);
  });

  Future<({int status, Json body, HttpHeaders headers, List<Cookie> cookies})> auth(String path, {String requestOrigin = origin,
    Json? body, String method = 'POST'}) async {
    final request = await http.openUrl(method, url.resolve(path));
    request.headers.set('Origin', requestOrigin);
    request.headers.contentType = ContentType.json;
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return (status: response.statusCode, body: text.isEmpty ? <String, dynamic>{} : jsonObject(jsonDecode(text)),
      headers: response.headers, cookies: response.cookies);
  }

  test('owner sign-in is origin restricted, rate limited, and issues a private session', () async {
    final foreign = await auth('/auth/login', requestOrigin: 'https://evil.example', body: {'key': key});
    expect(foreign.status, 403);
    expect(foreign.headers.value('access-control-allow-origin'), isNull);
    final preflight = await auth('/auth/login', requestOrigin: otherClient, method: 'OPTIONS');
    expect(preflight.status, 204);
    expect(preflight.headers.value('access-control-allow-origin'), otherClient);
    final signedIn = await auth('/auth/login', body: {'key': key});
    expect(signedIn.status, 200);
    expect(signedIn.body['token'], isA<String>());
    expect(signedIn.cookies.single.httpOnly, isTrue);
    expect(signedIn.cookies.single.secure, isTrue);
    expect(signedIn.cookies.single.sameSite, SameSite.none);
    expect(signedIn.headers.value('set-cookie'), contains('; Partitioned'));
    expect(signedIn.cookies.single.maxAge, const Duration(days: 365).inSeconds);
    expect(connections, 0);
    for (var attempt = 0; attempt < 10; attempt++) {
      expect((await auth('/auth/login', body: {'key': 'incorrect'})).status, 401);
    }
    expect((await auth('/auth/login', body: {'key': key})).status, 429);
  });

  test('only an authenticated origin-bound WebSocket reaches UDS; logout revokes the token', () async {
    final signedIn = await auth('/auth/login', body: {'key': key});
    final token = signedIn.body['token'] as String;
    final ws = url.replace(scheme: 'ws', path: '/ws').toString();
    for (final credentials in [('invalid', origin), (token, otherClient)]) {
      final socket = await WebSocket.connect(ws, headers: {'Origin': credentials.$2});
      final messages = StreamIterator<dynamic>(socket);
      socket.add(jsonEncode({'type': 'authenticate', 'token': credentials.$1}));
      expect(await messages.moveNext().timeout(const Duration(seconds: 5)), isFalse);
      expect(socket.closeCode, 1008);
      await messages.cancel();
      expect(connections, 0);
    }
    final socket = await WebSocket.connect(ws, headers: {'Origin': origin});
    final messages = StreamIterator<dynamic>(socket);
    try {
      socket.add(jsonEncode({'type': 'authenticate', 'token': token}));
      expect(await messages.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      expect(jsonDecode(messages.current as String), {'type': 'authenticated'});
      const request = '{"id":7,"method":"ping"}';
      socket.add(request);
      expect(await messages.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      expect(messages.current, request);
      expect(connections, 1);
      expect((await auth('/auth/logout', body: {'token': token})).status, 204);
    } finally { await socket.close(); await messages.cancel(); }
    final revoked = await WebSocket.connect(ws, headers: {'Origin': origin});
    final after = StreamIterator<dynamic>(revoked);
    revoked.add(jsonEncode({'type': 'authenticate', 'token': token}));
    expect(await after.moveNext().timeout(const Duration(seconds: 5)), isFalse);
    await after.cancel();
    expect(connections, 1);
  });

  test('gateway restart retains owner sessions and revocations; key rotation invalidates sessions', () async {
    final signedIn = await auth('/auth/login', body: {'key': key});
    final token = signedIn.body['token'] as String;
    Future<void> restart() async {
      await gateway.close();
      gateway = await WebGateway.start(socketPath: '${root.path}/backend',
        publicUrl: origin, ownerKeyFile: '${root.path}/owner', allowedOrigins: {otherClient}, port: 0);
      url = Uri.parse('http://127.0.0.1:${gateway.http.port}');
    }
    Future<int> restore() async {
      final request = await http.getUrl(url.resolve('/auth/session'));
      request.headers.set('Origin', origin);
      request.cookies.add(Cookie(signedIn.cookies.single.name, token));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }
    await restart();
    expect(await restore(), 200, reason: 'An ordinary gateway deploy must not sign out its owner');
    expect((await auth('/auth/logout', body: {'token': token})).status, 204);
    await restart();
    expect(await restore(), 401, reason: 'Restart must not undo logout');
    final another = await auth('/auth/login', body: {'key': key});
    await File('${root.path}/owner').writeAsString('${newId()}${newId()}');
    await restart();
    final socket = await WebSocket.connect(url.replace(scheme: 'ws', path: '/ws').toString(), headers: {'Origin': origin});
    final frames = StreamIterator<dynamic>(socket);
    socket.add(jsonEncode({'type': 'authenticate', 'token': another.body['token']}));
    expect(await frames.moveNext().timeout(const Duration(seconds: 5)), isFalse);
    expect(socket.closeCode, 1008);
    await frames.cancel();
    expect(connections, 0);
  });

}
