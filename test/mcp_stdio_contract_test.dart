// Modified local-transport ports of Codex 5112ce6edeb9 rmcp-client/tests/
// mcp_2026_message_limits.rs and mcp_2026_stdio_discovery.rs. The remote-exec
// transport is not substituted by a second invocation of the local launcher.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/src/transport.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late HttpClient http;
  late CancellationToken lifetime;
  final connections = <McpConnection>[];
  final fixture = File('test/fixtures/mcp_stdio.dart').absolute.path;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-stdio-contract-');
    http = HttpClient(); lifetime = TimeoutCancellationToken(const Duration(seconds: 20));
  });
  tearDown(() async {
    lifetime.cancel(); await Future.wait(connections.map((connection) => connection.close()));
    connections.clear(); http.close(force: true); await root.delete(recursive: true);
  });
  McpConnection connect(Json env) {
    final connection = McpConnection({'command': Platform.resolvedExecutable, 'args': [fixture], 'env': env}, http, (_) {});
    connections.add(connection); return connection;
  }

  for (final legacy in [false, true]) {
    test('Codex local stdio modern bound and legacy large-line compatibility: legacy=$legacy', () async {
      const size = 8 * 1024 * 1024 + 1;
      final connection = connect({'MCP_LEGACY': '$legacy', 'MCP_TOOL_DESCRIPTION_BYTES': '$size'});
      await connection.connect(lifetime);
      final result = connection.request('tools/list', {}, cancellation: lifetime);
      if (legacy) {
        expect((await result)['tools'][0]['description'], hasLength(size));
      } else {
        await expectLater(result, throwsA(isA<McpFailure>().having((error) => error.message, 'modern message bound', contains('8388608'))));
      }
    });
  }

  test('a caller deadline during discovery never authorizes legacy initialization on the same stdio process', () async {
    final log = File('${root.path}/requests');
    final connection = connect({'MCP_DISCOVERY_DELAY_MS': '11000', 'MCP_REQUESTS_FILE': log.path});
    final caller = CancellationToken();
    final result = expectLater(connection.connect(lifetime.merge(caller)), throwsA(isA<TimeoutException>()));
    try {
      while (!await log.exists() || !(await log.readAsLines()).contains('server/discover')) {
        await cancellableDelay(const Duration(milliseconds: 10), lifetime);
      }
      caller.cancel(TimeoutException('Caller deadline expired'));
      await result;
    } finally { caller.cancel(); }
    await connection.close();
    expect(await log.readAsLines(), isNot(contains('initialize')),
      reason: 'A deadline supplies no correlated protocol-version or method-not-found evidence.');
  });

  // mcp_2026_stdio_discovery.rs, all five local CA inheritance vectors.
  // Parent env/cwd are isolated in another real Dart client process, not an
  // injectable map that would bypass the actual launch path and pool identity.
  const caKeys = ['CODEX_CA_CERTIFICATE', 'SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE',
    'NODE_EXTRA_CA_CERTS', 'GIT_SSL_CAINFO', 'CARGO_HTTP_CAINFO', 'PIP_CERT', 'BUNDLE_SSL_CA_CERT',
    'npm_config_cafile', 'NPM_CONFIG_CAFILE'];
  for (final (override, name, expected) in [
    (false, 'SSL_CERT_FILE', 'absolute'), (false, 'REQUESTS_CA_BUNDLE', 'absolute'),
    (false, 'CODEX_CA_CERTIFICATE', null), (true, 'NPM_CONFIG_CAFILE', 'explicit/custom-ca.pem'),
    (true, 'npm_config_cafile', null),
  ]) {
    test('Codex stdio CA inheritance normalizes parent-relative paths: $name override=$override', () async {
      final source = await Directory('${root.path}/source').create();
      final server = await Directory('${root.path}/server').create();
      final output = await _client(source.path, {
        'command': Platform.resolvedExecutable, 'args': [fixture], 'cwd': server.path,
        'env': {if (override) 'NPM_CONFIG_CAFILE': 'explicit/custom-ca.pem'},
      }, [{'method': 'tools/call', 'params': {'name': 'probe', 'arguments': {'action': 'environment', 'names': [name]}}}],
        {for (final key in caKeys) key: 'certs/custom-ca.pem', 'CODEX_CA_CERTIFICATE': ''}, lifetime);
      expect(output['results'][0]['structuredContent'], {'cwd': await server.resolveSymbolicLinks(), 'environment': {
        name: expected == 'absolute' ? '${await source.resolveSymbolicLinks()}/certs/custom-ca.pem' : expected,
      }});
    });
  }
  test('Codex stdio default/explicit inheritance excludes host-only credentials even in literal overrides', () async {
    const defaults = ['LOGNAME', 'TERM', 'TZ'];
    const restricted = ['CODEX_EXEC_SERVER_NOISE_AUTH_TOKEN', 'NODE_REPL_AUTH_TOKEN', 'CODEX_GUARDIAN_DECISIONS_API_KEY',
      'OPENAI_FEDERATION_RULE_ID', 'openai_identity_token_file', 'OpenAI_Workload_Identity_Context'];
    final output = await _client(root.path, {
      'command': Platform.resolvedExecutable, 'args': [fixture],
      'inherit_env': ['EXTRA_RMCP_ENV', 'UNSET_RMCP_ENV', ...restricted],
      'env': {'TZ': 'custom', for (final key in restricted) key: 'private-context'},
    }, [{'method': 'tools/call', 'params': {'name': 'probe', 'arguments': {'action': 'environment',
      'names': [...defaults, 'EXTRA_RMCP_ENV', 'UNSET_RMCP_ENV', ...restricted]}}}],
      {for (final key in defaults) key: 'parent-$key', 'EXTRA_RMCP_ENV': 'from-env',
        for (final key in restricted) key: 'parent-private-context'}, lifetime);
    expect(output['results'][0]['structuredContent']['environment'], {
      for (final key in defaults) key: key == 'TZ' ? 'custom' : 'parent-$key',
      'EXTRA_RMCP_ENV': 'from-env', 'UNSET_RMCP_ENV': null, for (final key in restricted) key: null,
    });
  });
  for (final marker in ['2026-07-28', '1999-01-01']) {
    test('Codex legacy stdio preserves an explicit protocol marker without interpreting it: $marker', () async {
      final output = await _client(root.path, {
        'command': Platform.resolvedExecutable, 'args': [fixture],
        'env': {'MCP_LEGACY': 'true', 'CODEX_MCP_PROTOCOL_VERSION': marker},
      }, [{'method': 'tools/call', 'params': {'name': 'probe', 'arguments': {'action': 'environment',
        'names': ['CODEX_MCP_PROTOCOL_VERSION']}}}], {}, lifetime);
      expect(output['discovery']['protocolVersion'], '2025-06-18');
      expect(output['results'][0]['structuredContent']['environment'], {'CODEX_MCP_PROTOCOL_VERSION': marker});
    });
  }
  for (final legacy in [false, true]) {
    test('Codex local stdio catalogs preserve identity, resource metadata, reads and distinct errors: legacy=$legacy', () async {
      final output = await _client(root.path, {'command': Platform.resolvedExecutable, 'args': [fixture],
        'env': {'MCP_LEGACY': '$legacy', 'MCP_CONTRACT_CATALOGS': 'true'}}, [
          {'method': 'tools/list', 'params': <String, Object?>{}},
          {'method': 'resources/list', 'params': <String, Object?>{}},
          {'method': 'resources/templates/list', 'params': <String, Object?>{}},
          {'method': 'resources/read', 'params': {'uri': 'memo://codex/example-note'}},
          for (final uri in ['memo://codex/missing-first', 'memo://codex/missing-second'])
            {'method': 'resources/read', 'params': {'uri': uri}},
          {'method': 'prompts/list', 'params': <String, Object?>{}},
          {'method': 'prompts/get', 'params': {'name': 'memo-summary', 'arguments': {'slug': 'example-note'}}},
          {'method': 'prompts/get', 'params': {'name': 'missing'}},
        ], {}, lifetime);
      expect(legacy ? output['discovery']['serverInfo'] : output['discovery']['_meta']['io.modelcontextprotocol/serverInfo'],
        {'name': legacy ? 'legacy-fixture' : 'fixture', 'version': '1'});
      final results = output['results'] as List;
      expect(results[0]['tools'][0]['name'], 'probe');
      expect(results[1], {'resources': [{'name': 'example-note', 'title': 'Example Note', 'uri': 'memo://codex/example-note',
        'description': 'A sample MCP resource exposed for integration tests.', 'mimeType': 'text/plain'}]});
      expect(results[2], {'resourceTemplates': [{'name': 'codex-memo', 'title': 'Codex Memo', 'uriTemplate': 'memo://codex/{slug}',
        'description': 'Template for memo://codex/{slug} resources used in tests.', 'mimeType': 'text/plain'}]});
      expect(results[3], {'contents': [{'uri': 'memo://codex/example-note', 'mimeType': 'text/plain',
        'text': 'This is a sample MCP resource served by the rmcp test server.'}]});
      for (final (index, uri) in ['memo://codex/missing-first', 'memo://codex/missing-second'].indexed) {
        expect(results[4 + index], {'error': {'code': -32002, 'message': 'resource_not_found', 'data': {'uri': uri}}});
      }
      expect(results[6], {'prompts': [{'name': 'memo-summary', 'title': 'Summarize a memo', 'description': 'Summarize a selected memo.',
        'arguments': [{'name': 'slug', 'description': 'Memo slug', 'required': true}]}]});
      expect(results[7], {'description': 'Summarize a selected memo.', 'messages': [
        {'role': 'user', 'content': {'type': 'text', 'text': 'Summarize memo example-note.'}},
      ]});
      expect(results[8], {'error': {'code': -32602, 'message': 'invalid_prompt', 'data': {'name': 'missing'}}});
    });
  }
}

final _clientFixture = File('test/fixtures/mcp_client.dart').absolute.path;
final _packages = File('.dart_tool/package_config.json').absolute.path;
Future<Json> _client(String cwd, Json config, List<Json> requests, Map<String, String> environment, CancellationToken cancellation) async {
  final process = await Process.start(Platform.resolvedExecutable,
    ['--disable-dart-dev', '--packages=$_packages', _clientFixture, jsonEncode(config), jsonEncode(requests)],
    workingDirectory: cwd, environment: environment);
  final hook = CancellationHook(cancellation, () => process.kill(ProcessSignal.sigkill));
  final output = utf8.decoder.bind(process.stdout).join(), errors = utf8.decoder.bind(process.stderr).join();
  try {
    expect(await process.exitCode.asCancellable(cancellation), 0, reason: await errors);
    return jsonObject(jsonDecode(await output));
  } finally { hook.dispose(); process.kill(ProcessSignal.sigkill); }
}
