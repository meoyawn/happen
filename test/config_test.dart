import 'dart:convert';
import 'dart:io';

import 'package:config/config.dart';
import 'package:protocol/protocol.dart'
    show CancellationToken, CancelledException;
import 'package:test/test.dart';

void main() {
  test('YAML preserves command arguments and strings in immutable data', () {
    expect(globalConfigSchema, jsonDecode(File('packages/config/schema.json').readAsStringSync()));
    final config = parseConfig(r'''
# yaml-language-server: $schema=https://raw.githubusercontent.com/meoyawn/happen/master/packages/config/schema.json
# Global servers shared by all tasks.
code_mode_tool_search: true
mcp_servers:
  dart:
    command: dart
    args: [mcp-server, --disable, analysis]
    cwd: /tmp/a directory
    env: {PORT: "3000", FLAG: "false"}
    inherit_env: [SERVICE_API_KEY]
  remote:
    url: https://example.com/mcp
    header_env: {Authorization: MCP_AUTHORIZATION}
    oauth:
      client_id: fixture-client
      client_secret_env: MCP_CLIENT_SECRET
      token_endpoint_auth_method: client_secret_basic
      scopes: [training]
      callback_port: 8766
    enabled: false
''');
    expect(config['code_mode_tool_search'], isTrue);
    final local = config['mcp_servers']['dart'];
    expect(local['command'], 'dart');
    expect(local['args'], ['mcp-server', '--disable', 'analysis']);
    expect(local['cwd'], '/tmp/a directory');
    expect(local['env'], {'PORT': '3000', 'FLAG': 'false'});
    expect(config['mcp_servers']['remote']['enabled'], isFalse);
    expect(config['mcp_servers']['remote']['oauth']['callback_port'], 8766);
    expect(config['mcp_servers']['remote']['oauth']['scopes'], ['training']);
    expect(() => local['args'].add('unexpected'), throwsUnsupportedError);
    expect(() => local['command'] = 'changed', throwsUnsupportedError);
    expect(() => config.clear(), throwsUnsupportedError);
  });

  test('invalid YAML and schema violations never echo credential values', () {
    const secret = 'sensitive-config-value';
    final invalid = <String, String>{
      'root scalar': secret,
      'root list': '[$secret]',
      'explicit null': 'null',
      'syntax': 'mcp_servers: [$secret',
      'multiple documents': '{}\n---\n$secret',
      'duplicate keys': 'mcp_servers: {}\nmcp_servers: $secret',
      'non-string key': 'mcp_servers: {42: {command: dart}}',
      'recursive alias': 'mcp_servers: &self {dart: *self}',
      'unknown field': 'mcp_servres: $secret',
      'tool search string': 'code_mode_tool_search: $secret',
      'tool search quoted boolean': 'code_mode_tool_search: "true"',
      'tool search number': 'code_mode_tool_search: 1',
      'tool search null': 'code_mode_tool_search: null',
      'server array': 'mcp_servers: [$secret]',
      'server scalar': 'mcp_servers: {dart: $secret}',
      'missing transport': 'mcp_servers: {dart: {args: [$secret]}}',
      'both transports':
          'mcp_servers: {dart: {command: dart, url: https://example.com/mcp}}',
      'empty command': 'mcp_servers: {dart: {command: " "}}',
      'args scalar': 'mcp_servers: {dart: {command: dart, args: $secret}}',
      'argument type': 'mcp_servers: {dart: {command: dart, args: [42]}}',
      'env type':
          'mcp_servers: {dart: {command: dart, env: {TOKEN: [$secret]}}}',
      'env number': 'mcp_servers: {dart: {command: dart, env: {PORT: 3000}}}',
      'cwd type': 'mcp_servers: {dart: {command: dart, cwd: [$secret]}}',
      'inherit_env type':
          'mcp_servers: {dart: {command: dart, inherit_env: $secret}}',
      'boolean type': 'mcp_servers: {dart: {command: dart, enabled: "false"}}',
      'server typo': 'mcp_servers: {dart: {command: dart, arg: [$secret]}}',
      'wrong transport field':
          'mcp_servers: {dart: {url: https://example.com, args: []}}',
      'header type':
          'mcp_servers: {remote: {url: https://example.com, headers: {Authorization: [$secret]}}}',
      'local OAuth': 'mcp_servers: {local: {command: dart, oauth: {}}}',
      'OAuth enabled scalar': 'mcp_servers: {remote: {url: https://example.com, oauth: true}}',
      'OAuth unknown option': 'mcp_servers: {remote: {url: https://example.com, oauth: {token: $secret}}}',
      'OAuth callback port': 'mcp_servers: {remote: {url: https://example.com, oauth: {callback_port: 65536}}}',
      'OAuth scopes': 'mcp_servers: {remote: {url: https://example.com, oauth: {scopes: [$secret, 42]}}}',
      'OAuth client dependency': 'mcp_servers: {remote: {url: https://example.com, oauth: {client_secret_env: $secret}}}',
      'URL credentials':
          'mcp_servers: {remote: {url: "https://user:$secret@example.com"}}',
      'URL scheme': 'mcp_servers: {remote: {url: "file:///$secret"}}',
      'URL host': 'mcp_servers: {remote: {url: "https:///$secret"}}',
      'URL fragment':
          'mcp_servers: {remote: {url: "https://example.com/#$secret"}}',
      'non-MCP public URL': 'public_url: https://callback.example',
      'non-MCP provider settings': 'providers: {openai: {settings: {reasoning: low}}}',
      'non-MCP default provider': 'default_provider: openai',
      'non-MCP unload setting': 'idle_unload_seconds: 0',
      'removed code mode override': 'code_mode_only: false',
      'non-finite number':
          'mcp_servers: {dart: {command: dart, env: {LIMIT: .nan}}}',
      'server limit': jsonEncode({
        'mcp_servers': {
          for (var i = 0; i < 65; i++) 's$i': {'command': 'dart'},
        },
      }),
    };
    for (final entry in invalid.entries) {
      expect(
        () => parseConfig(entry.value),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'sanitized diagnostic',
            isNot(contains(secret)),
          ),
        ),
        reason: entry.key,
      );
    }
    expect(
      () => parseConfig('mcp_servers: {dart: {command: dart, args: [42]}}'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'invalid field',
          contains('/mcp_servers/dart/args/0'),
        ),
      ),
    );
  });

  test(
    'loading prefers YAML and never masks malformed files with legacy JSON',
    () async {
      final root = await Directory.systemTemp.createTemp('config-files-');
      addTearDown(() => root.delete(recursive: true));
      final yaml = File('${root.path}/config.yaml');
      final legacy = File('${root.path}/config.json');
      Future<ConfigSnapshot> load() =>
          loadConfig(yaml.path, legacyPath: legacy.path);
      expect((await load()).path, isNull);
      await legacy.writeAsString('{"mcp_servers":{"old":{"command":"old"}}}');
      expect((await load()).values['mcp_servers'].keys, ['old']);
      await yaml.writeAsString('code_mode_tool_search: false\nmcp_servers: {new: {command: new}}');
      expect((await load()).values['mcp_servers'].keys, ['new']);
      expect((await load()).values['code_mode_tool_search'], isFalse);
      expect((await load()).path, yaml.path);
      await yaml.writeAsString('mcp_servers: [');
      await expectLater(load(), throwsFormatException);
      for (final source in [
        'mcp_servers: {remote: {url: "https://example.com:99999/mcp"}}',
        'mcp_servers: {a-b: {command: dart}, a_b: {command: dart}}',
      ]) {
        await yaml.writeAsString(source);
        await expectLater(load(), throwsFormatException);
      }
      for (final empty in ['', '# Only a comment\n', '{}']) {
        await yaml.writeAsString(empty);
        expect((await load()).values, isEmpty);
      }
      await yaml.writeAsBytes([0xff]);
      await expectLater(load(), throwsFormatException);
      await yaml.writeAsString('#${'x' * (1024 * 1024)}');
      await expectLater(load(), throwsFormatException);
      await expectLater(
        loadConfig(yaml.path, cancellation: CancellationToken()..cancel()),
        throwsA(isA<CancelledException>()),
      );
    },
  );

  test('project icon writes preserve other YAML fields and comments across document styles', () async {
    final root = await Directory.systemTemp.createTemp('project-icon-config-');
    final token = CancellationToken();
    addTearDown(() async { token.cancel(); await root.delete(recursive: true); });
    final documents = [
      '# Keep this comment\nmcp_servers:\n  dart:\n    args: [mcp-server]\n',
      '# Keep this comment\nicon:\n  kind: lucide\n  name: terminal\n  color: blue\nmcp_servers: {}\n',
      '# Keep this comment\nmcp_servers: {}\nicon:\n  kind: emoji\n  emoji: 🚀\n',
      '# Keep this comment\nicon: old.png # Icon comment\nmcp_servers: {}\n',
      '# Keep this comment\n{"mcp_servers":{"dart":{"args":["mcp-server"]}}}\n',
      '# Keep this comment\n{icon: old.svg, mcp_servers: {}}\n',
      '# Keep this comment\n---\nmcp_servers: {}\n...\n',
      '# Keep this comment\n',
    ];
    for (var index = 0; index < documents.length; index++) {
      final directory = await Directory('${root.path}/$index/.happen').create(recursive: true);
      final file = File('${directory.path}/config.yaml');
      final source = documents[index], project = directory.parent.path;
      await file.writeAsString(source);
      final before = parseConfig(source, partialMcp: true);
      for (final icon in <ProjectIcon?>[
        const ProjectFileIcon('assets/logo.svg'), const ProjectMonogramIcon('HP', 'purple'), null,
      ]) {
        await saveProjectIcon(project, icon, cancellation: token);
        final saved = await file.readAsString();
        final values = parseConfig(saved, partialMcp: true);
        expect(values['icon'], projectIconConfig(icon), reason: 'Document $index');
        expect(values['mcp_servers'], before['mcp_servers'], reason: 'Document $index');
        expect(saved, contains('# Keep this comment'), reason: 'Document $index');
        expect(projectIconConfig(await loadProjectIcon(project, cancellation: token)), projectIconConfig(icon));
      }
      final committed = await file.readAsString();
      await expectLater(saveProjectIcon(project, const ProjectMonogramIcon('TOO LONG', 'blue'), cancellation: token), throwsFormatException);
      expect(await file.readAsString(), committed);
    }
  });
}
