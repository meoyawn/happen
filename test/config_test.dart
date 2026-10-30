import 'dart:convert';
import 'dart:io';

import 'package:config/config.dart';
import 'package:protocol/protocol.dart'
    show CancellationToken, CancelledException;
import 'package:test/test.dart';

void main() {
  test('YAML preserves command arguments and strings in immutable data', () {
    final config = parseConfig('''
# Global servers shared by all tasks.
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
    enabled: false
providers:
  deepseek:
    backend: opencode
    settings: {reasoning: low}
''');
    final local = config['mcp_servers']['dart'];
    expect(local['command'], 'dart');
    expect(local['args'], ['mcp-server', '--disable', 'analysis']);
    expect(local['cwd'], '/tmp/a directory');
    expect(local['env'], {'PORT': '3000', 'FLAG': 'false'});
    expect(config['mcp_servers']['remote']['enabled'], isFalse);
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
      'URL credentials':
          'mcp_servers: {remote: {url: "https://user:$secret@example.com"}}',
      'URL scheme': 'mcp_servers: {remote: {url: "file:///$secret"}}',
      'URL host': 'mcp_servers: {remote: {url: "https:///$secret"}}',
      'URL fragment':
          'mcp_servers: {remote: {url: "https://example.com/#$secret"}}',
      'URL port':
          'mcp_servers: {remote: {url: "https://example.com:99999/$secret"}}',
      'public URL': 'public_url: "https://user:$secret@example.com"',
      'provider map': 'providers: [$secret]',
      'provider option': 'providers: {deepseek: {backend: $secret}}',
      'non-finite number':
          'providers: {deepseek: {settings: {temperature: .nan}}}',
      'colliding names':
          'mcp_servers: {a-b: {command: dart}, a_b: {command: dart}}',
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
      await yaml.writeAsString('mcp_servers: {new: {command: new}}');
      expect((await load()).values['mcp_servers'].keys, ['new']);
      expect((await load()).path, yaml.path);
      await yaml.writeAsString('mcp_servers: [');
      await expectLater(load(), throwsFormatException);
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
}
