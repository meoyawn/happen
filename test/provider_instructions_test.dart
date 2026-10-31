import 'dart:convert';
import 'dart:io';

import 'package:agent/agent.dart';
import 'package:crypto/crypto.dart';
import 'package:openai/openai.dart';
import 'package:openai/src/instructions.dart' as codex;
import 'package:opencode/opencode.dart';
import 'package:opencode/src/instructions.dart' as opencode;
import 'package:opencode/src/mcp_instructions.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  // Captured from SessionSystemPrompt.make and Codex's model_messages at the
  // revisions recorded alongside the search fixtures. No Happen prose is added.
  test('provider system instructions match the upstream bytes', () {
    String digest(String text) => sha256.convert(utf8.encode(text)).toString();
    expect(digest(opencode.openCodeInstructions), '1ffd1d46e14c2699759ad6671aa13aae9d41d31391cdc24b32b97d2007a01cdf');
    const hashes = {
      'gpt-6-astra': 'e27c375cb2c1e882d124abd3aba006991eb7641a9c67882947b68287f2091725',
      'gpt-6.1-sol': '57bec554a2962d076174cafe62b31df136165d128077aa2dc198bb7a5142a7bf',
      'gpt-6.1-terra': 'e27c375cb2c1e882d124abd3aba006991eb7641a9c67882947b68287f2091725',
      'gpt-6-sol': 'd32c529e55930fd24e2aaf5cd7dc29ec5f0a6e4ced90baf4176b4f65c3196909',
      'gpt-6-luna': '9c813d3edbe3f727dae86999fd60ca61b60382a9e7330e06f2007b928183b8cd',
    };
    for (final entry in hashes.entries) {
      final model = GptModel(entry.key);
      final instructions = [model.instructions, model.persistentInstructions].where((value) => value.isNotEmpty).join('\n\n');
      expect(digest(instructions), entry.value, reason: entry.key);
      final config = initialConfiguration({
        'provider': 'openai', 'model': entry.key, 'base_instructions': instructions,
        'provider_settings': {'reasoning': 'low'},
      }, '/repo', false);
      expect(config['instructions'], instructions);
      expect(config['tool_interface'], 'openai');
    }
    final config = initialConfiguration({
      'provider': 'opencode', 'model': openCodeDeepSeekModel, 'base_instructions': 'obsolete shared instructions',
      'provider_settings': {'reasoning': 'high'},
    }, '/repo', false);
    expect(config['instructions'], opencode.openCodeInstructions);
    expect(config['tool_interface'], 'opencode');
  });

  test('Codex AGENTS.md snapshots, global separator, replacements, and removals are verbatim', () {
    final initial = <String, dynamic>{'cwd': '/repo', 'files': [
      {'path': '/global/AGENTS.md', 'global': true, 'text': 'Global\n'},
      {'path': '/repo/AGENTS.md', 'text': 'Project\n'},
      {'path': '/repo/sub/AGENTS.override.md', 'text': 'Nested'},
    ]};
    final text = codex.renderInstructions(initial, null);
    expect(text.role, 'user');
    expect(text.text, '# AGENTS.md instructions for /repo\n\n<INSTRUCTIONS>\nGlobal\n'
      '\n\n--- project-doc ---\n\nProject\n\n\nNested\n</INSTRUCTIONS>');
    expect(codex.renderInstructions({'cwd': '/repo', 'files': [{'text': 'New'}]}, initial).text,
      '# AGENTS.md instructions for /repo\n\n<INSTRUCTIONS>\nThese AGENTS.md instructions replace all previously provided AGENTS.md instructions.\n\nNew\n</INSTRUCTIONS>');
    expect(codex.renderInstructions({'cwd': '/repo', 'files': []}, initial).text,
      '# AGENTS.md instructions\n\n<INSTRUCTIONS>\nThe previously provided AGENTS.md instructions no longer apply.\n</INSTRUCTIONS>');
  });

  final fixture = jsonObject(jsonDecode(File('test/fixtures/tool_search/opencode_instructions.json').readAsStringSync()));
  for (final (index, raw) in (fixture['cases'] as List).indexed) {
    final entry = jsonObject(raw);
    test('OpenCode upstream instruction rendering and updates $index', () {
      if (entry['kind'] == 'mcp') {
        List<Json> catalog(List values) => [for (final value in values) {
          'namespace': 'mcp__${mcpNamespace(value['server'] as String)}',
          'server_name': value['server'], 'namespace_description': value['instructions'],
        }];
        expect(renderMcpInstructions(catalog(entry['current'] as List),
          entry.containsKey('previous') ? catalog(entry['previous'] as List) : null), entry['expected']);
      } else {
        Json snapshot(List files) => {'cwd': '/repo', 'files': [for (final file in files) {
          'path': file['path'], 'text': file['content'],
        }]};
        final rendered = opencode.renderInstructions(snapshot(entry['current'] as List),
          entry.containsKey('previous') ? snapshot(entry['previous'] as List) : null);
        expect(rendered.role, 'developer');
        expect(rendered.text, entry['expected']);
      }
    });
  }

  test('OpenCode preserves MCP hyphens and keeps server instructions outside namespace metadata', () {
    const interface = OpenCodeToolInterface();
    final catalog = <Json>[{
      'name': 'mcp__archive_v2__read_record', 'namespace': 'mcp__archive_v2', 'tool_name': 'read_record',
      'server_name': 'archive-v2', 'original_name': 'read-record',
      'namespace_description': 'Use complete records.\nKeep their identifiers.',
      'description': 'Read a record', 'parameters': {'type': 'object'},
    }];
    expect(interface.externalCatalog(catalog).single['name'], 'archive-v2.read-record');
    expect(interface.externalCatalog(catalog).single.containsKey('namespace_description'), isFalse);
    final text = interface.catalogContext(catalog, null)!;
    expect(text, contains('tools["archive-v2"]["read-record"]('));
    expect(text, contains('<mcp_instructions>\n  <server name="archive-v2">\n'
      '    Use tools from this server through `execute` under `tools["archive-v2"]`.\n'
      '    Use complete records.\n    Keep their identifiers.\n  </server>\n</mcp_instructions>'));
    expect(interface.catalogContext(catalog, catalog), isNull);
  });
}
