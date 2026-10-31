import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  final fixture = File('test/fixtures/mcp_stdio.dart').absolute.path;
  test('client inventory includes disabled servers, pages resources, and keeps credentials private', () async {
    final root = await Directory.systemTemp.createTemp('mcp-inventory-');
    final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Json>[];
    peer.listen((request) async {
      if (request.uri.path == '/denied') {
        request.response.statusCode = 401;
        request.response.write('private-denial-body');
        await request.response.close();
        return;
      }
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requests.add(body);
      final method = body['method'];
      final cursor = body['params']['cursor'];
      final result = switch (method) {
        'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {'tools': {}, 'resources': {}}},
        'tools/list' => {'tools': [{'name': 'remote_echo', 'inputSchema': {'type': 'object'}}]},
        'resources/list' => {
          'resources': [{'name': cursor == null ? 'first' : 'second', 'uri': cursor == null ? 'resource://one' : 'resource://two', '_meta': {'private': 'private-resource-metadata'}}],
          if (cursor == null) 'nextCursor': 'next',
        },
        _ => null,
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'],
        if (result != null) 'result': result else 'error': {'code': -32603, 'message': 'private-upstream-error'},
      }));
      await request.response.close();
    });
    final config = File('${root.path}/config.yaml');
    await config.writeAsString(jsonEncode({'mcp_servers': {
      'remote': {'url': 'http://127.0.0.1:${peer.port}/mcp?token=private-url-token', 'headers': {'Authorization': 'Bearer private-header-token'}, 'legacy_fallback': false},
      'local': {'command': Platform.resolvedExecutable, 'args': [fixture], 'env': {'TEST_TOKEN': 'private-env-token'}, 'legacy_fallback': false},
      'disabled': {'command': '/not-an-executable', 'enabled': false},
      'denied': {'url': 'http://127.0.0.1:${peer.port}/denied', 'legacy_fallback': false},
    }}));
    final server = await AgentServer.startEmbedded(directory: '${root.path}/data', configPath: config.path);
    final client = await AgentClient.connect(server.uri);
    final token = CancellationToken();
    try {
      final summary = await client.mcpInventory(cancellation: token);
      final rows = (summary['servers'] as List).map(jsonObject).toList();
      expect(rows.map((row) => row['name']), ['denied', 'disabled', 'local', 'remote']);
      expect(rows.first['state'], 'authentication_required');
      expect(rows.first['auth_status'], 'not_authenticated');
      expect(rows[1]['enabled'], false);
      expect(rows[1]['state'], 'disabled');
      expect(rows[2]['tool_count'], 1);
      expect(rows[3]['auth_status'], 'configured_headers');
      expect(requests.where((request) => (request['method'] as String).startsWith('resources/')), isEmpty);
      final before = (await client.request('mcp.status') as List).map(jsonObject).singleWhere((row) => row['name'] == 'local')['pid'];
      final full = await client.mcpInventory(verbose: true, cancellation: token);
      final local = (full['servers'] as List).map(jsonObject).singleWhere((row) => row['name'] == 'local');
      expect(local['tools'], ['probe']);
      expect(local['resources'], [{'name': 'readme', 'title': 'Readme', 'uri': 'file:///readme'}]);
      expect(local['resource_templates'], [{'name': 'document', 'uriTemplate': 'file:///docs/{id}'}]);
      final remote = (full['servers'] as List).map(jsonObject).singleWhere((row) => row['name'] == 'remote');
      expect(remote['tools'], ['remote_echo']);
      expect((remote['resources'] as List).map((row) => row['uri']), ['resource://one', 'resource://two']);
      expect(remote['resource_templates_error'], 'Unable to load resource templates');
      expect(jsonEncode(full), isNot(contains('private-')));
      expect(jsonEncode(summary), isNot(contains('private-')));
      await config.writeAsString('mcp_servers: {invalid: {command: dart, args: [42]}}');
      final retained = await client.mcpInventory(cancellation: token);
      expect(retained['config_error'], contains('/mcp_servers/invalid/args/0'));
      expect((retained['servers'] as List).map((row) => row['name']), rows.map((row) => row['name']));
      expect((await client.request('mcp.status') as List).map(jsonObject).singleWhere((row) => row['name'] == 'local')['pid'], before);
      final disabled = await client.mcpInventory(server: 'disabled', verbose: true, cancellation: token);
      expect(disabled['servers'], hasLength(1));
      expect(disabled['servers'][0]['tools'], isEmpty);
      expect(jsonObject(await client.request('ping'))['version'], '0.1.0');
    } finally {
      token.cancel();
      await client.close();
      await server.close();
      await peer.close(force: true);
      await root.delete(recursive: true);
    }
  });

  test('closing client inventory cancels discovery without stopping the shared MCP process', () async {
    final root = await Directory.systemTemp.createTemp('mcp-inventory-cancel-');
    final config = File('${root.path}/config.yaml');
    await config.writeAsString(jsonEncode({'mcp_servers': {
      'local': {'command': Platform.resolvedExecutable, 'args': [fixture], 'env': {'MCP_RESOURCES_WAIT': 'true'}, 'legacy_fallback': false},
    }}));
    final server = await AgentServer.startEmbedded(directory: '${root.path}/data', configPath: config.path);
    final client = await AgentClient.connect(server.uri);
    final token = CancellationToken(), probeToken = CancellationToken();
    try {
      Future<Json> probe() async {
        final result = jsonObject(await callIsolate(server.network.port, 'mcp.call', {
          'name': 'mcp__local__probe', 'arguments': {'action': 'status'},
        }, cancellation: probeToken));
        return jsonObject(jsonDecode(result['content'][0]['text'] as String));
      }
      Future<Json> until(int waiting) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (true) {
          final value = await probe();
          if (value['waiting'] == waiting) return value;
          if (DateTime.now().isAfter(deadline)) fail('Inventory did not release its resource discovery');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      await client.mcpInventory(cancellation: probeToken);
      final before = await probe();
      final cancelled = expectLater(client.mcpInventory(verbose: true, cancellation: token), throwsA(isA<CancelledException>()));
      expect((await until(1))['pid'], before['pid']);
      // Other requests on this same WebSocket must still complete.
      expect((await client.mcpInventory(cancellation: probeToken))['servers'][0]['state'], 'ready');
      token.cancel();
      await cancelled;
      expect((await until(0))['pid'], before['pid']);
    } finally {
      token.cancel();
      probeToken.cancel();
      await client.close();
      await server.close();
      await root.delete(recursive: true);
    }
  });
}
