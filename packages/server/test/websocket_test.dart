// Ported connection contracts from Codex app-server/tests/suite/v2/
// connection_handling_websocket.rs and connection_handling_websocket_unix.rs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

Future<Json> receive(StreamIterator<dynamic> input) async {
  if (!await input.moveNext().timeout(const Duration(seconds: 10))) throw StateError('Connection closed');
  return jsonObject(jsonDecode(input.current as String));
}
void send(WebSocket socket, Object id, String method, [Json params = const {}]) =>
  socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
const initialization = {'clientInfo': {'name': 'contract', 'version': '1'}, 'capabilities': {'experimentalApi': true}};

void main() {
  late Directory root;
  late AgentServer server;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-websocket-');
    server = await AgentServer.start(directory: root.path, port: 0, configPath: '${root.path}/config.yaml');
  });
  tearDown(() async { await server.close(); await root.delete(recursive: true); });

  test('per-connection initialization and equal request IDs route independently', () async {
    final one = await WebSocket.connect(server.uri.toString()), two = await WebSocket.connect(server.uri.toString());
    final first = StreamIterator(one), second = StreamIterator(two);
    try {
      send(one, 1, 'initialize', initialization);
      expect((await receive(first))['id'], 1);
      send(two, 2, 'thread/loaded/list');
      expect((await receive(second))['error']['message'], 'Not initialized');
      send(two, 3, 'initialize', initialization);
      expect((await receive(second))['id'], 3);
      for (final socket in [one, two]) { send(socket, 77, 'thread/loaded/list'); }
      for (final input in [first, second]) {
        final reply = await receive(input);
        expect(reply, containsPair('id', 77)); expect(reply['result']['data'], isEmpty);
      }
      send(one, 'duplicate-init', 'initialize', initialization);
      expect((await receive(first))['error']['message'], 'Already initialized');
    } finally { await one.close(); await two.close(); await first.cancel(); await second.cancel(); }
  });

  test('health endpoints share the listener and reject browser Origin on all paths', () async {
    final http = HttpClient();
    try {
      for (final path in ['/readyz', '/healthz']) {
        final url = server.uri.replace(scheme: 'http', path: path);
        final response = await (await http.getUrl(url)).close();
        expect(response.statusCode, 200); await response.drain<void>();
        final browser = await http.getUrl(url)..headers.set('Origin', 'https://evil.example');
        final rejected = await browser.close();
        expect(rejected.statusCode, 403); await rejected.drain<void>();
      }
      await expectLater(WebSocket.connect(server.uri.toString(), headers: {'Origin': 'https://evil.example'}), throwsA(isA<WebSocketException>()));
    } finally { http.close(force: true); }
  });

  test('missing or invalid bearer tokens are rejected; authorized clients initialize', () async {
    await server.close();
    server = await AgentServer.start(directory: root.path, port: 0, token: 'secret', configPath: '${root.path}/config.yaml');
    for (final headers in [<String, String>{}, {'Authorization': 'Bearer wrong'}]) {
      await expectLater(WebSocket.connect(server.uri.toString(), headers: headers), throwsA(isA<WebSocketException>()));
    }
    final socket = await WebSocket.connect(server.uri.toString(), headers: {'Authorization': 'Bearer secret'});
    final input = StreamIterator(socket);
    try { send(socket, 1, 'initialize', initialization); expect((await receive(input))['result']['serverInfo']['name'], 'happen'); }
    finally { await socket.close(); await input.cancel(); }
  });

  test('unauthenticated non-loopback listeners are refused at startup', () async {
    await expectLater(AgentServer.start(directory: root.path, host: '0.0.0.0', port: 0), throwsArgumentError);
  });

  test('invalid JSON is request-scoped and does not poison the next request', () async {
    final socket = await WebSocket.connect(server.uri.toString());
    final input = StreamIterator(socket);
    try {
      socket.add('{');
      expect((await receive(input))['error']['code'], -32700);
      send(socket, 1, 'initialize', initialization); await receive(input);
      send(socket, 2, 'thread/loaded/list');
      expect((await receive(input))['result']['data'], isEmpty);
    } finally { await socket.close(); await input.cancel(); }
  });

  test('Unix socket uses the same handshake without requiring a separate TCP server', () async {
    await server.close();
    server = await AgentServer.startEmbedded(directory: root.path, configPath: '${root.path}/config.yaml');
    final client = await AgentClient.connect(server.uri);
    try { expect((await client.request('thread/loaded/list') as Map)['data'], isEmpty); }
    finally { await client.close(); }
  });

  test('server shutdown drains the outbound writer before closing an attached socket', () async {
    final socket = await WebSocket.connect(server.uri.toString());
    final input = StreamIterator(socket);
    try {
      send(socket, 1, 'initialize', initialization); await receive(input);
      for (var id = 2; id < 18; id++) { send(socket, id, 'thread/loaded/list'); }
      await server.close().timeout(const Duration(seconds: 10));
      while (await input.moveNext().timeout(const Duration(seconds: 10))) {
        final message = jsonObject(jsonDecode(input.current as String));
        expect(message['id'], isA<int>());
      }
    } finally { await input.cancel(); await socket.close(); }
  });
}
