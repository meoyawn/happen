// Codex 5112ce6edeb9 rmcp-client/tests/mcp_2026_discovery.rs,
// mcp_2026_sse_discovery.rs and streamable_http_recovery.rs, modified for
// Happen's modern-first client and config-owned connections (no plugins).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart' show McpManager;
import 'package:mcp/src/transport.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late _Wire wire;
  setUp(() async { wire = await _Wire.start(); });
  tearDown(() => wire.close());
  const modern = {'supportedVersions': ['2026-07-28'], 'capabilities': {'tools': <String, Object?>{}}};

  for (final sse in [false, true]) {
    for (final identity in [false, true]) {
      test('Codex discovery self-contained metadata, SSE=$sse, namespaced identity=$identity', () async {
        wire.discovery = _Reply(result: {...modern, if (identity) '_meta': {
          'io.modelcontextprotocol/serverInfo': {'name': 'modern-test', 'version': '1.0.0'},
        }}, sse: sse);
        await wire.connection.connect(wire.token);
        expect(wire.connection.modern, true);
        expect(await wire.connection.request('tools/list', {}, cancellation: wire.token), {'tools': <Object?>[]});
        expect(wire.requests.map((r) => r['method']), ['server/discover', 'tools/list']);
        for (final request in wire.requests) {
          expect(request['params']['_meta']['io.modelcontextprotocol/protocolVersion'], '2026-07-28');
          expect(request['params']['_meta']['io.modelcontextprotocol/clientInfo']['name'], 'happen');
          expect(request['_headers']['mcp-method'], request['method']);
          expect(request['_headers']['mcp-protocol-version'], '2026-07-28');
        }
        expect(wire.connection.discovery['_meta'], identity ? {
          'io.modelcontextprotocol/serverInfo': {'name': 'modern-test', 'version': '1.0.0'},
        } : null);
      });
    }
  }

  test('Codex discovery retries an advertised modern unsupported-version error using a new ID', () async {
    wire.discovery = const _Reply(error: {'code': -32022, 'message': 'unsupported protocol version', 'data': {'supported': ['2025-06-18', '2026-07-28']}});
    wire.discoverFailures = 1;
    await wire.connection.connect(wire.token);
    expect(wire.requests.map((r) => r['method']), ['server/discover', 'server/discover']);
    expect(wire.requests.first['id'], isNot(wire.requests.last['id']));
  });

  final fallback = <String, _Reply>{
    'method-not-found': const _Reply(error: {'code': -32601, 'message': 'method not found'}),
    'method-not-found-sse': const _Reply(sse: true, error: {'code': -32601, 'message': 'method not found'}),
    'legacy-only-result': const _Reply(result: {'supportedVersions': ['2025-11-25']}),
    'legacy-only-error': const _Reply(status: 400, error: {'code': -32022, 'message': 'only legacy MCP protocols are supported', 'data': {'supported': ['2025-06-18', '2025-11-25']}}),
    for (final code in [-32022, -32600, -32602]) 'explicit-version-$code': _Reply(status: 400, error: {'code': code, 'message': 'Unsupported protocol version: 2026-07-28'}),
    for (final status in [404, 405]) 'plain-$status': _Reply(status: status, text: 'legacy MCP endpoint'),
    for (final (index, message, mime) in [
      (0, 'Bad Request: Unsupported protocol version: 2026-07-28 (supported versions: 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07)', 'application/json'),
      (1, 'Bad Request: Unsupported protocol version (supported versions: 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07)', 'application/json'),
      (2, 'Bad Request: Unsupported protocol version (supported versions: 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07)', 'text/plain'),
      (3, 'Bad Request: Unsupported protocol version (supported versions: 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07)', 'application/octet-stream'),
      (4, 'Bad Request: No valid session ID provided', 'application/json'),
    ]) 'prevalidation-$index': _Reply(status: 400, correlated: false, mime: mime, error: {'code': -32000, 'message': message}),
    for (final (index, version, mime, explicit) in [
      (0, '2025-11-25', 'application/json', true), (1, '2025-11-25', 'application/json', false),
      (2, '2025-11-25', 'text/plain', false), (3, '2025-03-26', 'application/json', false), (4, '2024-11-05', 'application/json', false),
    ]) 'negotiated-$index': _Reply(status: 400, correlated: false, mime: mime, legacyVersion: version,
      error: {'code': -32000, 'message': 'Bad Request: Unsupported protocol version${explicit ? ': 2026-07-28' : ''} (supported versions: $version)'}),
  };
  for (final entry in fallback.entries) {
    test('Codex proven legacy discovery fallback: ${entry.key}', () async {
      wire.discovery = entry.value; wire.legacyVersion = entry.value.legacyVersion;
      await wire.connection.connect(wire.token);
      expect(wire.connection.version, entry.value.legacyVersion);
      expect(wire.requests.map((r) => r['method']), ['server/discover', 'initialize', 'notifications/initialized']);
      expect(wire.requests[1]['params']['protocolVersion'], '2025-06-18');
      expect(wire.requests.last['_headers']['mcp-protocol-version'], entry.value.legacyVersion);
      expect(wire.requests.last['params']['_meta'], null);
    });
  }

  final rejected = <String, _Reply>{
    for (final (name, supported) in [
      ('missing', null), ('empty', <Object?>[]), ('unknown', <Object?>['2025-06-18', '1999-01-01']), ('invalid', <Object?>['2025-06-18', 42]),
    ]) 'unproven-versions-$name': _Reply(status: 400, error: {'code': -32022, 'message': 'unsupported protocol version', 'data': {if (supported != null) 'supported': supported}}),
    for (final (status, code) in [(400, -32602), (403, -32021), (200, -32020)])
      'modern-rejection-$status-$code': _Reply(status: status, error: {'code': code, 'message': 'modern discovery rejected'}),
    for (final sse in [false, true]) for (final id in [null, 'unrelated-request'])
      'uncorrelated-method-$sse-$id': _Reply(sse: sse, correlated: false, responseId: id, error: const {'code': -32601, 'message': 'method not found'}),
    'uncorrelated-version': const _Reply(status: 400, correlated: false, responseId: 'unrelated-request', error: {'code': -32602, 'message': 'Unsupported protocol version: 2026-07-28'}),
    for (final (status, code, id, mime) in [
      (400, -32022, null, 'application/json'), (400, -32021, null, 'application/json'), (400, -32020, null, 'application/json'),
      (400, -32601, null, 'application/json'), (400, -32602, null, 'application/json'), (400, -32020, null, 'text/plain'),
      (400, -32000, 'unrelated-request', 'application/json'), (401, -32000, null, 'application/json'),
      (403, -32000, null, 'application/json'), (200, -32000, null, 'application/json'),
    ]) 'non-legacy-$status-$code-$id-$mime': _Reply(status: status, correlated: false, responseId: id, mime: mime, error: {'code': code, 'message': 'discovery rejected'}),
    for (final (index, status, message, mime) in [
      (0, 400, 'Bad Request: malformed request', 'application/json'), (1, 400, 'Bad Request: malformed request', 'text/plain'),
      (2, 400, 'Bad Request: Unsupported protocol version: 2026-07-28 (supported versions: 2025-06-18, 2099-01-01)', 'application/json'),
      (3, 400, 'Bad Request: Unsupported protocol version (supported versions: 2025-06-18, 2099-01-01)', 'application/json'),
      (4, 400, 'Bad Request: Unsupported protocol version (supported versions: 2025-06-18, 2099-01-01)', 'text/plain'),
      (5, 400, 'Bad Request: Unsupported protocol version (supported versions: 2024-10-07)', 'application/json'),
      (6, 200, 'Bad Request: No valid session ID provided', 'application/json'),
    ]) 'unrecognized-null-$index': _Reply(status: status, correlated: false, mime: mime, error: {'code': -32000, 'message': message}),
  };
  for (final entry in rejected.entries) {
    test('Codex discovery must not downgrade: ${entry.key}', () async {
      wire.discovery = entry.value;
      await expectLater(wire.connection.connect(wire.token), throwsA(isA<McpFailure>()));
      expect(wire.requests.map((r) => r['method']), ['server/discover'], reason: 'An unproven rejection must never authorize initialize.');
    });
  }

  test('Codex transient legacy handshake retries rediscover before a fresh initialize', () async {
    wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
    wire.initializeFailures = 1;
    await wire.connection.connect(wire.token);
    expect(wire.requests.map((r) => r['method']), ['server/discover', 'initialize', 'server/discover', 'initialize', 'notifications/initialized']);
  });

  for (final status in [404, 500, 401, 403]) {
    test('Codex URL calls recover only legacy session expiry, never auth or unrelated failures: $status', () async {
      wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
      await wire.connection.connect(wire.token); wire.callFailure = status;
      if (status == 404) {
        expect((await wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token))['content'][0]['text'], 'echo');
        expect(wire.requests.where((r) => r['method'] == 'initialize'), hasLength(2));
        expect(wire.requests.where((r) => r['method'] == 'tools/call'), hasLength(2));
        final sessions = wire.requests.where((r) => r['method'] == 'tools/call').map((r) => r['_headers']['mcp-session-id']).toList();
        expect(sessions, ['session-1', 'session-2']);
      } else {
        await expectLater(wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token), throwsA(isA<McpFailure>().having((e) => e.status, 'HTTP status', status)));
        expect(wire.requests.where((r) => r['method'] == 'tools/call'), hasLength(1));
        expect(wire.requests.where((r) => r['method'] == 'initialize'), hasLength(1));
      }
    });
  }

  test('Codex a modern 404 is not legacy session expiry', () async {
    await wire.connection.connect(wire.token); wire.callFailure = 404;
    await expectLater(wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token), throwsA(isA<McpFailure>().having((e) => e.status, 'HTTP status', 404)));
    expect(wire.requests.map((r) => r['method']), ['server/discover', 'tools/call']);
  });

  test('Codex legacy session expiry retries only once, then a later user call still works', () async {
    wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
    await wire.connection.connect(wire.token); wire.callFailure = 404; wire.callFailures = 2;
    await expectLater(wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token), throwsA(isA<McpFailure>().having((e) => e.status, 'HTTP status', 404)));
    expect(wire.requests.where((r) => r['method'] == 'tools/call'), hasLength(2));
    expect(wire.requests.where((r) => r['method'] == 'initialize'), hasLength(2));
    expect((await wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token))['content'][0]['text'], 'echo');
  });

  test('Codex session recovery retries a transient initialize failure', () async {
    wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
    await wire.connection.connect(wire.token); wire.callFailure = 404; wire.initializeFailures = 1;
    expect((await wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token))['content'][0]['text'], 'echo');
    expect(wire.requests.where((r) => r['method'] == 'initialize'), hasLength(3));
    expect(wire.requests.where((r) => r['method'] == 'tools/call'), hasLength(2));
  });

  // Happen's shared URL owner must coalesce recovery without giving the first
  // request authority to cancel the other caller's handshake.
  for (final cancelFirst in [false, true]) {
    test('shared URL session recovery is coalesced and caller-local: cancel=$cancelFirst', () async {
      wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
      await wire.connection.connect(wire.token);
      wire.callFailure = 404; wire.callFailures = 2; wire.rejections = Completer<void>();
      wire.initializeGate = Completer<void>();
      final initialized = wire.initialized.stream.first;
      final cancellation = CancellationToken(); addTearDown(cancellation.cancel);
      final firstCall = wire.connection.request('tools/call', {'name': 'echo'}, cancellation: cancellation);
      final first = cancelFirst ? expectLater(firstCall, throwsA(isA<CancelledException>())) : firstCall.then<void>((value) { expect(value['content'][0]['text'], 'echo'); });
      final second = wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token);
      await initialized;
      if (cancelFirst) { cancellation.cancel(); await first; }
      wire.initializeGate!.complete();
      expect((await second)['content'][0]['text'], 'echo'); await first;
      expect(wire.requests.where((r) => r['method'] == 'initialize'), hasLength(2));
      expect(wire.requests.where((r) => r['method'] == 'tools/call'), hasLength(cancelFirst ? 3 : 4));
    });
  }

  // Complete HTTP payload matrix from mcp_2026_message_limits.rs, plus its
  // legacy compatibility control. Model output truncation is not a wire bound.
  for (final oversized in ['discovery-json', 'tools-json', 'tools-error', 'tools-sse']) {
    test('Codex modern 8388608 byte message bound: $oversized', () async {
      final padding = 'x' * (8 * 1024 * 1024 + 1);
      if (oversized == 'discovery-json') {
        wire.discovery = _Reply(result: {...modern, 'instructions': padding});
      } else {
        wire.overrides['tools/list'] = oversized == 'tools-error'
          ? _Reply(status: 500, error: {'code': -32603, 'message': padding})
          : _Reply(sse: oversized == 'tools-sse', result: {'tools': [{'name': 'oversized', 'description': padding, 'inputSchema': {'type': 'object'}}]});
        await wire.connection.connect(wire.token);
      }
      await expectLater(oversized == 'discovery-json' ? wire.connection.connect(wire.token)
        : wire.connection.request('tools/list', {}, cancellation: wire.token),
        throwsA(predicate<Object>((error) => error.toString().contains('8388608'), 'the modern 8 MiB wire bound')));
    });
  }
  test('Codex legacy HTTP preserves JSON responses above the modern limit', () async {
    wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
    final padding = 'x' * (8 * 1024 * 1024 + 1);
    wire.overrides['tools/list'] = _Reply(result: {'tools': [{'name': 'legacy-large', 'description': padding, 'inputSchema': {'type': 'object'}}]});
    await wire.connection.connect(wire.token);
    expect((await wire.connection.request('tools/list', {}, cancellation: wire.token))['tools'][0]['description'], padding);
  });

  // All POST redirect transformations applicable to the MCP HTTP transport.
  for (final (status, method) in [(301, 'GET'), (302, 'GET'), (303, 'GET'), (307, 'POST'), (308, 'POST')]) {
    test('Codex legacy same-origin $status redirect preserves credentials and transforms the body correctly', () async {
      wire.config['headers'] = {'X-Api-Key': 'sensitive-key', 'Proxy-Authorization': 'proxy-secret', 'Referer': 'https://stale.example/', 'Content-Encoding': 'identity'};
      wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
      wire.redirectMethods.addAll(['initialize', 'notifications/initialized', 'tools/call']); wire.redirectStatus = status;
      await wire.connection.connect(wire.token);
      expect((await wire.connection.request('tools/call', {'name': 'echo', 'arguments': {'query': 'sensitive-query'}}, cancellation: wire.token))['content'][0]['text'], 'echo');
      final redirected = wire.requests.where((request) => request['_path'] == '/forwarded').toList();
      expect(redirected.map((request) => request['method']), ['initialize', 'notifications/initialized', 'tools/call']);
      for (final request in redirected) {
        expect(request['_verb'], method); expect(request['_headers']['x-api-key'], 'sensitive-key');
        expect(request['_headers']['proxy-authorization'], null);
        expect(request['_headers']['referer'], wire.config['url']);
        expect(request['_body'].isEmpty, method == 'GET');
        expect(request['_headers']['content-type'], method == 'POST' ? contains('application/json') : null);
        expect(request['_headers']['content-encoding'], method == 'POST' ? 'identity' : null);
        expect(request['_headers']['content-length'], method == 'POST'
          ? '${utf8.encode(request['_body'] as String).length}' : null);
      }
    });
  }
  for (final status in [307, 308]) {
    test('Codex legacy rejects a cross-origin redirect after a same-origin hop: $status', () async {
      final attacker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final contacts = <String>[]; attacker.listen((request) async { contacts.add(request.uri.path); await request.response.close(); });
      addTearDown(() => attacker.close(force: true));
      wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
      await wire.connection.connect(wire.token);
      wire.redirectMethods.add('tools/call'); wire.redirectStatus = status;
      wire.onward = 'http://127.0.0.1:${attacker.port}/private';
      await expectLater(wire.connection.request('tools/call', {'name': 'echo', 'arguments': {'query': 'secret'}}, cancellation: wire.token),
        throwsA(isA<McpFailure>().having((error) => error.message, 'origin guard', contains('different origin'))));
      expect(wire.requests.where((request) => request['_path'] == '/forwarded'), hasLength(1));
      expect(contacts, isEmpty);
    });
  }
  test('Codex legacy redirect cycles stop at the redirect limit', () async {
    wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
    await wire.connection.connect(wire.token);
    wire.redirectMethods.add('tools/call'); wire.redirectTarget = '/mcp';
    await expectLater(wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token),
      throwsA(isA<McpFailure>().having((error) => error.message, 'bounded redirects', contains('redirect limit'))));
    expect(wire.requests.where((request) => request['method'] == 'tools/call'), hasLength(11));
  });
  test('Codex modern discovery reports a redirect status without forwarding sensitive headers', () async {
    wire.config['headers'] = {'X-Api-Key': 'sensitive-key'};
    wire.redirectMethods.add('server/discover');
    await expectLater(wire.connection.connect(wire.token), throwsA(isA<McpFailure>().having((error) => error.status, 'redirect status', 307)));
    expect(wire.requests.map((request) => request['_path']), ['/mcp']);
  });

  for (final (method, response) in [
    ('server/discover', const _Reply(status: 503, text: 'service unavailable')),
    ('initialize', const _Reply(status: 502, text: 'bad gateway')),
    ('initialize', const _Reply(status: 502, error: {'code': -32603, 'message': 'bad gateway'})),
    ('initialize', const _Reply(drop: true)),
    ('notifications/initialized', const _Reply(status: 502, error: {'code': -32603, 'message': 'bad gateway'})),
    ('tools/list', const _Reply(status: 502, text: 'bad gateway')),
    ('tools/list', const _Reply(status: 502, error: {'code': -32603, 'message': 'bad gateway'})),
  ]) {
    test('Codex transient HTTP failure retries the owning operation: $method ${response.status} json=${response.error != null} drop=${response.drop}', () async {
      if (method != 'server/discover') wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
      wire.faults[method] = [response];
      await wire.connection.connect(wire.token);
      if (method == 'tools/list') expect(await wire.connection.request(method, {}, cancellation: wire.token), {'tools': <Object?>[]});
      expect(wire.requests.where((request) => request['method'] == method), hasLength(2));
      if (method == 'server/discover') expect(wire.requests.where((request) => request['method'] == 'initialize'), isEmpty);
    });
  }
  test('Codex legacy fallback retains initialize authentication failure without replay', () async {
    wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
    wire.faults['initialize'] = [const _Reply(status: 401, headers: {'www-authenticate': ['Bearer error="invalid_token"']})];
    await expectLater(wire.connection.connect(wire.token), throwsA(isA<McpFailure>().having((error) => error.status, 'authentication status', 401)));
    expect(wire.requests.map((request) => request['method']), ['server/discover', 'initialize']);
  });

  for (final userAgent in [null, 'configured-user-agent']) {
  test('Codex standard headers, schema rejection, and user agent use the actual HTTP owner: $userAgent', () async {
    if (userAgent != null) wire.config['headers'] = {'User-Agent': userAgent};
    wire.overrides['tools/list'] = const _Reply(result: {'tools': [
      {'name': 'echo', 'inputSchema': {'type': 'object', 'properties': {'tenant': {'type': 'string', 'x-mcp-header': 'Tenant'}}}},
      {'name': 'invalid', 'inputSchema': {'type': 'object', 'properties': {'tenant': {'type': 'string', 'x-mcp-header': true}}}},
    ]});
    final manager = McpManager(http: wire.http, onEvent: (_, _) {}); addTearDown(manager.close);
    await manager.configure({'peer': wire.config}, wire.token);
    expect(((await manager.catalog(wire.token))['tools'] as List).map((tool) => tool['name']), ['mcp__peer__echo']);
    expect((await manager.callTool('mcp__peer__echo', {'tenant': 'acme'}, wire.token))['content'][0]['text'], 'echo');
    expect(wire.requests.map((request) => request['method']), ['server/discover', 'tools/list', 'tools/call']);
    for (final request in wire.requests) {
      expect(request['_headers']['user-agent'], userAgent ?? 'happen-mcp-client/0.1.0');
      expect(request['_headers']['mcp-protocol-version'], '2026-07-28');
      expect(request['_headers']['mcp-method'], request['method']);
    }
    expect(wire.requests.last['_headers']['mcp-name'], 'echo');
    expect(wire.requests.last['_headers']['mcp-param-tenant'], 'acme');
  });
  }

  for (final sse in [false, true]) {
    test('Codex resources preserve metadata, payloads, and each missing-resource error: SSE=$sse', () async {
      const resource = {'name': 'example-note', 'title': 'Example Note', 'uri': 'memo://codex/example-note', 'description': 'A sample MCP resource.', 'mimeType': 'text/plain'};
      const template = {'name': 'codex-memo', 'title': 'Codex Memo', 'uriTemplate': 'memo://codex/{slug}', 'description': 'Memo resources.', 'mimeType': 'text/plain'};
      const contents = {'uri': 'memo://codex/example-note', 'mimeType': 'text/plain', 'text': 'This is a sample MCP resource.'};
      wire.overrides['resources/list'] = _Reply(sse: sse, result: {'resources': [resource]});
      wire.overrides['resources/templates/list'] = _Reply(sse: sse, result: {'resourceTemplates': [template]});
      wire.overrides['resources/read'] = _Reply(sse: sse, result: {'contents': [contents]});
      await wire.connection.connect(wire.token);
      expect(await wire.connection.request('resources/list', {}, cancellation: wire.token), {'resources': [resource]});
      expect(await wire.connection.request('resources/templates/list', {}, cancellation: wire.token), {'resourceTemplates': [template]});
      expect(await wire.connection.request('resources/read', {'uri': resource['uri']}, cancellation: wire.token), {'contents': [contents]});
      for (final uri in ['memo://codex/missing-first', 'memo://codex/missing-second']) {
        wire.overrides['resources/read'] = _Reply(sse: sse, error: {'code': -32002, 'message': 'resource_not_found', 'data': {'uri': uri}});
        await expectLater(wire.connection.request('resources/read', {'uri': uri}, cancellation: wire.token),
          throwsA(isA<McpFailure>().having((error) => error.code, 'resource error code', -32002)
            .having((error) => error.message, 'resource error message', 'resource_not_found').having((error) => error.data, 'resource error data', {'uri': uri})));
      }
    });
  }

  // streamable_http_recovery.rs retains both invalid-token challenge vectors.
  for (final proxy in [false, true]) {
    test('Codex 401 Bearer challenge is a tool error, not an automatic replay: proxy=$proxy', () async {
      const challenge = 'Bearer error="invalid_token", resource_metadata="https://example.com/.well-known/oauth-protected-resource"';
      final challenges = [if (proxy) 'Basic realm="proxy, login"', challenge];
      await wire.connection.connect(wire.token);
      wire.faults['tools/call'] = [_Reply(status: 401, headers: {'www-authenticate': challenges})];
      expect(await wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token), {
        'isError': true, 'content': [{'type': 'text', 'text': 'Authentication required'}],
        '_meta': {'mcp/www_authenticate': [challenges.join(', ')]},
      });
      expect(wire.requests.where((request) => request['method'] == 'tools/call'), hasLength(1));
      expect((await wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token))['content'][0]['text'], 'echo');
    });
  }
  // Full www_authenticate_tests.rs scope parser matrix at the HTTP boundary.
  final scopeChallenges = <(String, String?)>[
    ('Bearer error="insufficient_scope", scope="files:read files:write"', 'files:read files:write'),
    ('Bearer error="insufficient_scope", ScOpE = "files:read"', 'files:read'),
    ('Bearer scope="read:data", error="insufficient_scope"', 'read:data'),
    ('Bearer error="insufficient_scope", scope=read', 'read'),
    (r'Bearer error="insufficient_scope", scope="files:read\ files:write"', 'files:read files:write'),
    (r'Bearer error="insufficient_scope", error_description="request scope=admin, not \"root\"", scope="files:read"', 'files:read'),
    ('Basic realm="example", Bearer error="insufficient_scope", scope="files:read"', 'files:read'),
    ('Newauth scope="wrong", Bearer error="insufficient_scope", scope="files:read"', 'files:read'),
    for (final header in [
      'Bearer error="insufficient_scope", scope=', r'Bearer error="insufficient_scope", scope="read\"write"',
      r'Bearer error="insufficient_scope", scope="read\\write"', 'Bearer error="insufficient_scope", scope="read  write"',
      'Bearer error="insufficient_scope", scope=read:data', 'Bearer error="insufficient_scope", scope=files:read files:write',
      'Bearer error="insufficient_scope", scope=read=value', 'Bearer error="insufficient_scope", scope="read", scope="write"',
    ]) (header, null),
  ];
  for (final (index, scenario) in scopeChallenges.indexed) {
    test('Codex insufficient-scope challenge keeps only an unambiguous valid scope: $index', () async {
      await wire.connection.connect(wire.token);
      wire.faults['tools/call'] = [_Reply(status: 403, headers: {'www-authenticate': [scenario.$1]})];
      await expectLater(wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token),
        throwsA(isA<McpFailure>().having((error) => error.message, 'scope classification', contains('Insufficient scope'))
          .having((error) => error.data?['required_scope'], 'validated scope', scenario.$2)));
      expect(wire.requests.where((request) => request['method'] == 'tools/call'), hasLength(1));
    });
  }
  for (final header in [
    'Bearer error="invalid_token", scope="files:read"', 'Bearer error_description="request scope=admin"',
    'Bearer resource_scope="admin"', 'Bearer "scope=admin"', 'Bearer error_description="unterminated scope=admin',
  ]) {
    test('Codex unrelated or malformed challenge cannot acquire insufficient-scope meaning: $header', () async {
      await wire.connection.connect(wire.token);
      wire.faults['tools/call'] = [_Reply(status: 403, headers: {'www-authenticate': [header]})];
      await expectLater(wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token),
        throwsA(isA<McpFailure>().having((error) => error.status, 'HTTP rejection', 403)
          .having((error) => error.message.contains('Insufficient scope'), 'not insufficient scope', false)));
    });
  }
  test('Codex insufficient-scope challenge is found after another header field', () async {
    await wire.connection.connect(wire.token);
    wire.faults['tools/call'] = [const _Reply(status: 403, headers: {'www-authenticate': ['Basic realm="example"', 'Bearer error="insufficient_scope", scope="files:read"']})];
    await expectLater(wire.connection.request('tools/call', {'name': 'echo'}, cancellation: wire.token),
      throwsA(isA<McpFailure>().having((error) => error.message, 'scope classification', contains('Insufficient scope'))
        .having((error) => error.data?['required_scope'], 'validated scope', 'files:read')));
  });

  for (final legacy in [false, true]) {
    test('caller metadata survives without gaining protocol-selection authority: legacy=$legacy', () async {
      if (legacy) wire.discovery = const _Reply(error: {'code': -32601, 'message': 'method not found'});
      await wire.connection.connect(wire.token);
      const metadata = {'callId': 'preserved', 'openai/readOnly': false,
        'io.modelcontextprotocol/protocolVersion': '2026-07-28'};
      await wire.connection.request('tools/list', {'cursor': 'next', '_meta': metadata}, cancellation: wire.token);
      await wire.connection.request('tools/call', {'name': 'echo', 'arguments': {'message': 'hello'}, '_meta': metadata}, cancellation: wire.token);
      final calls = wire.requests.where((request) => ['tools/list', 'tools/call'].contains(request['method'])).toList();
      expect(calls.map((request) => request['params']['_meta']['callId']), everyElement('preserved'));
      expect(calls.map((request) => request['params']['_meta']['openai/readOnly']), everyElement(false));
      expect(calls.first['params']['cursor'], 'next'); expect(calls.last['params']['arguments'], {'message': 'hello'});
      expect(calls.map((request) => request['_headers']['mcp-protocol-version']), everyElement(legacy ? '2025-06-18' : '2026-07-28'));
    });
  }
  test('Codex configured HTTP header values preserve their UTF-8 bytes', () async {
    wire.config['headers'] = {'X-Fixture-Name': 'café'};
    await wire.connection.connect(wire.token);
    expect(latin1.encode(wire.requests.single['_headers']['x-fixture-name'] as String), utf8.encode('café'));
  }, skip: 'User excluded cases requiring changes to Dart HTTP encoding (2026-11-05).');
}

class _Reply {
  const _Reply({this.result, this.error, this.status = 200, this.correlated = true, this.responseId, this.sse = false,
    this.text, this.mime = 'application/json', this.legacyVersion = '2025-06-18', this.location, this.headers = const {}, this.drop = false});
  final Json? result, error;
  final int status;
  final bool correlated, sse;
  final String? responseId, text;
  final String mime, legacyVersion;
  final String? location;
  final Map<String, List<String>> headers;
  final bool drop;
  Future<void> send(HttpRequest request, Json body) async {
    if (drop) { (await request.response.detachSocket(writeHeaders: false)).destroy(); return; }
    request.response.statusCode = status;
    for (final header in headers.entries) { for (final value in header.value) { request.response.headers.add(header.key, value); } }
    if (location != null) { request.response.headers.set('location', location!); await request.response.close(); return; }
    request.response.headers.contentType = sse ? ContentType('text', 'event-stream') : ContentType.parse(mime);
    final value = text ?? jsonEncode({'jsonrpc': '2.0', 'id': correlated ? body['id'] : responseId, if (error != null) 'error': error else 'result': result ?? <String, Object?>{}});
    request.response.write(sse ? ': keepalive\n\nevent: message\ndata: $value\n\n' : value); await request.response.close();
  }
}

class _Wire {
  _Wire(this.server) {
    config['url'] = 'http://127.0.0.1:${server.port}/mcp';
    connection = McpConnection(config, http, (_) {});
    server.listen(serve);
  }
  final HttpServer server;
  final http = HttpClient();
  final token = TimeoutCancellationToken(const Duration(seconds: 10));
  late final McpConnection connection;
  final requests = <Json>[];
  final config = <String, dynamic>{}, overrides = <String, _Reply>{}, faults = <String, List<_Reply>>{};
  final redirectMethods = <String>{};
  var redirectStatus = 307;
  String redirectTarget = '/forwarded';
  String? onward;
  Json? _redirectBody;
  _Reply discovery = const _Reply(result: {'supportedVersions': ['2026-07-28'], 'capabilities': {'tools': <String, Object?>{}}});
  int discoverFailures = -1, initializeFailures = 0, session = 0;
  int callFailures = 1;
  int? callFailure;
  Completer<void>? rejections, initializeGate;
  final initialized = StreamController<void>.broadcast();
  String legacyVersion = '2025-06-18';
  static Future<_Wire> start() async => _Wire(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> serve(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    final body = text.isEmpty ? _redirectBody! : jsonObject(jsonDecode(text));
    final headers = <String, Object?>{}; request.headers.forEach((key, values) => headers[key] = values.join(', '));
    requests.add({...body, '_headers': headers, '_verb': request.method, '_path': request.uri.path, '_body': text});
    final method = body['method'] as String;
    if (request.uri.path == '/mcp' && redirectMethods.contains(method)) {
      _redirectBody = body; await _Reply(status: redirectStatus, location: redirectTarget).send(request, body); return;
    }
    if (request.uri.path == '/forwarded' && onward != null) { await _Reply(status: redirectStatus, location: onward).send(request, body); return; }
    if (faults[method]?.isNotEmpty == true) { await faults[method]!.removeAt(0).send(request, body); return; }
    if (overrides[method] case final _Reply reply) { await reply.send(request, body); return; }
    switch (body['method']) {
      case 'server/discover':
        await (discoverFailures == 0 ? const _Reply(result: {'supportedVersions': ['2026-07-28'], 'capabilities': {'tools': <String, Object?>{}}}) : discovery).send(request, body);
        if (discoverFailures > 0) discoverFailures--;
      case 'initialize':
        initialized.add(null); await initializeGate?.future;
        if (initializeFailures > 0) { initializeFailures--; await const _Reply(status: 503, text: 'service unavailable').send(request, body); return; }
        request.response.headers.set('Mcp-Session-Id', 'session-${++session}');
        await _Reply(result: {'protocolVersion': legacyVersion, 'capabilities': {'tools': <String, Object?>{}}}).send(request, body);
      case 'notifications/initialized': request.response.statusCode = 202; await request.response.close();
      case 'tools/list': await const _Reply(result: {'tools': <Object?>[]}).send(request, body);
      case 'tools/call':
        final failure = callFailure;
        if (failure != null) {
          if (--callFailures == 0) { callFailure = null; if (rejections?.isCompleted == false) rejections!.complete(); }
          await rejections?.future;
        }
        await (failure == null ? const _Reply(result: {'content': [{'type': 'text', 'text': 'echo'}]})
          : _Reply(status: failure, error: const {'code': -32603, 'message': 'upstream failure'})).send(request, body);
      default: throw StateError('Unexpected MCP operation');
    }
  }
  Future<void> close() async {
    token.cancel(); if (initializeGate?.isCompleted == false) initializeGate!.complete(); if (rejections?.isCompleted == false) rejections!.complete();
    await connection.close(); http.close(force: true); await server.close(force: true); await initialized.close();
  }
}
