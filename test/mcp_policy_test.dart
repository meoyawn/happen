// Codex rmcp-client/tests/mcp_2026_discovery{,/tool_call_session_meta_tests}.rs
// and streamable_http_recovery/telemetry_tests.rs. Real manager/HTTP/file owners;
// the host metadata provider is production policy, not a private serialization seam.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late HttpServer peer;
  late McpManager manager;
  late CancellationToken lifetime;
  final requests = <Json>[];
  var initial = false, recovered = false, modern = false, handshakes = 0, expire = false;
  String getUrl() => 'http://127.0.0.1:${peer.port}/mcp';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcp-policy-'); lifetime = TimeoutCancellationToken(const Duration(seconds: 20));
    requests.clear(); handshakes = 0; expire = false; initial = false; recovered = false; modern = false;
    peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    peer.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requests.add({...body, 'session': request.headers.value('mcp-session-id'), 'authorization': request.headers.value('authorization')});
      Json response;
      if (body['method'] == 'server/discover' && !modern) { response = {'error': {'code': -32601, 'message': 'Method not found'}}; }
      else {
        Json result;
        switch (body['method']) {
          case 'server/discover':
          case 'initialize':
            final policy = handshakes++ == 0 ? initial : recovered;
            request.response.headers.set('mcp-session-id', handshakes == 1 ? 'initial' : 'recovered-$handshakes');
            result = {if (modern) 'supportedVersions': ['2026-07-28'] else 'protocolVersion': '2025-06-18',
              'capabilities': {'tools': <String, Object?>{}, if (policy) 'experimental': {'codex/network-policy-meta': <String, Object?>{}}}};
          case 'notifications/initialized': request.response.statusCode = 202; await request.response.close(); return;
          case 'tools/list': result = {'tools': [{'name': 'echo', 'inputSchema': {'type': 'object'}}]};
          case 'tools/call':
            if (expire) { expire = false; request.response.statusCode = 404; await request.response.close(); return; }
            result = {'content': [{'type': 'text', 'text': 'done'}]};
          default: throw StateError('Unexpected policy request');
        }
        response = {'result': result};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], ...response})); await request.response.close();
    });
  });
  tearDown(() async { lifetime.cancel(); await manager.close(); manager.http.close(force: true); await peer.close(force: true); await root.delete(recursive: true); });
  Future<void> start({McpRequestMetadata? metadata, bool oauth = false}) async {
    manager = McpManager(http: HttpClient(), directory: root.path, onEvent: (_, _) {}, requestMetadata: metadata);
    await manager.configure({'peer': {'url': getUrl(), if (!oauth) 'oauth': false}}, lifetime);
  }
  Future<Json> call(String phase, {bool readOnly = true}) => manager.callTool('mcp__peer__echo', {'phase': phase}, lifetime,
    readOnly: readOnly, meta: {'callId': phase, 'openai/readOnly': false, 'codex/network-policy-meta': {'enabled': true, 'forged': true}});

  for (final (before, after, fail) in [(false, true, false), (true, false, false), (true, true, false), (false, false, false), (false, true, true)]) {
    test('recovery rebuilds host metadata from current capabilities: $before/$after/fail=$fail', () async {
      initial = before; recovered = after;
      await start(metadata: (caps) {
        if (caps['experimental']?['codex/network-policy-meta'] == null) return {};
        if (fail) throw StateError('policy source unavailable');
        return {'codex/network-policy-meta': {'enabled': false}};
      });
      await call('warmup'); expire = true;
      if (fail) {
        await expectLater(call('recovery'), throwsA(isA<StateError>().having((e) => e.message, 'host failure', 'policy source unavailable')));
        await expectLater(call('later'), throwsA(isA<StateError>()));
      } else { await call('recovery'); await call('later'); }
      final calls = requests.where((r) => r['method'] == 'tools/call').toList();
      expect(calls.map((r) => {'session': r['session'], 'callId': r['params']['_meta']['callId'],
        'policy': r['params']['_meta']['codex/network-policy-meta'], 'readOnly': r['params']['_meta']['openai/readOnly']}), [
        for (final phase in ['warmup', 'recovery']) {'session': 'initial', 'callId': phase, 'policy': before ? {'enabled': false} : null, 'readOnly': true},
        if (!fail) for (final phase in ['recovery', 'later']) {'session': 'recovered-2', 'callId': phase, 'policy': after ? {'enabled': false} : null, 'readOnly': true},
      ]);
      expect(handshakes, 2);
    });
  }

  for (final wire in [false, true]) {
    for (final readOnly in [false, true]) {
      test('host read-only metadata wins without losing cursor or caller data: modern=$wire/$readOnly', () async {
        modern = wire; await start();
        await manager.request('peer', 'tools/list', {}, lifetime, readOnly: readOnly);
        await manager.request('peer', 'tools/list', {'cursor': 'next', '_meta': {'callId': 'page', 'openai/readOnly': false}}, lifetime, readOnly: readOnly);
        await call('tool', readOnly: readOnly);
        final calls = requests.where((r) => r['method'] == 'tools/list' || r['method'] == 'tools/call').skip(1).toList();
        expect(calls.map((r) => r['params']['_meta']?['openai/readOnly']), [readOnly ? true : null, readOnly, readOnly]);
        expect(calls[1]['params']['cursor'], 'next'); expect(calls[1]['params']['_meta']['callId'], 'page');
        expect(calls.last['params']['arguments'], {'phase': 'tool'}); expect(calls.last['params']['_meta']['callId'], 'tool');
      });
    }
  }

  test('anonymous session recovery discovers newly saved credentials without losing call attribution', () async {
    await start(oauth: true); await call('warmup');
    final sink = ReceivePort(), traces = <Json>[];
    final listener = sink.listen((event) { traces.add(jsonObject(event)); });
    try {
      for (var recovery = 0; recovery < 3; recovery++) {
        if (recovery == 1) {
          final file = File('${root.path}/mcp-auth/${sha256.convert(utf8.encode('peer\u0000${getUrl()}'))}.json');
          await file.parent.create(recursive: true); await file.writeAsString(jsonEncode({'server_name': 'peer', 'server_url': getUrl(),
            'client_id': 'client', 'issuer': getUrl(), 'access_token': 'newly-saved'}));
        }
        expire = true;
        final trace = TraceContext(sink: sink.sendPort, service: 'network', session: 'thread-$recovery');
        await withTrace(trace, () => call('recovery-$recovery'));
        await Future<void>.delayed(Duration.zero);
        expect(traces.where((e) => e['trace'] == trace.trace).map((e) => e['session']).toSet(), {'thread-$recovery'});
      }
      final calls = requests.where((r) => r['method'] == 'tools/call').toList();
      expect(calls.map((r) => r['authorization']), [null, null, null, null, 'Bearer newly-saved', 'Bearer newly-saved', 'Bearer newly-saved']);
      expect(handshakes, 4);
      expect(jsonEncode(traces), isNot(contains('newly-saved')));
    } finally { await listener.cancel(); sink.close(); }
  });
}
