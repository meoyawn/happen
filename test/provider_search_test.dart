import 'dart:convert';
import 'dart:io';

import 'package:openai/src/declarations.dart' as openai;
import 'package:openai/src/discovery.dart' as codex;
import 'package:openai/src/search/bm25.dart';
import 'package:openai/src/tool_catalog.dart' as namespaces;
import 'package:opencode/src/discovery.dart' as opencode;
import 'package:opencode/src/tool_catalog.dart' as catalog;
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

// These are captured upstream executions, not expected values calculated by
// the Dart implementation. Source hashes and revision pins live in each file.
void main() {
  final openaiFixture = jsonObject(jsonDecode(File('test/fixtures/tool_search/openai.json').readAsStringSync()));
  final opencodeFixture = jsonObject(jsonDecode(File('test/fixtures/tool_search/opencode.json').readAsStringSync()));
  final namespaceFixture = jsonObject(jsonDecode(File('test/fixtures/tool_search/openai_catalog.json').readAsStringSync()));
  final declarationFixture = jsonObject(jsonDecode(File('test/fixtures/tool_search/openai_declarations.json').readAsStringSync()));
  List<Json> tools(Json fixture, int index) => (fixture['catalogs'][index] as List).map(jsonObject).toList();

  for (final (index, raw) in (opencodeFixture['search'] as List).indexed) {
    final fixture = jsonObject(raw), expected = jsonObject(fixture['expected']);
    test('OpenCode upstream search $index: ${fixture['query'] ?? fixture['args']}', () {
      Json search() => opencode.searchCodeArguments(tools(opencodeFixture, fixture['catalog'] as int),
        fixture['args'] as List? ?? [fixture['query']]);
      if (expected.containsKey('error')) {
        expect(search, throwsA(isA<opencode.ToolRuntimeError>()
          .having((error) => error.kind, 'kind', 'InvalidToolInput')
          .having((error) => error.toString(), 'upstream error', expected['error'])));
      } else {
        expect(search(), expected['value']);
      }
    });
  }
  for (final (index, raw) in (opencodeFixture['catalog'] as List).indexed) {
    final fixture = jsonObject(raw), expected = jsonObject(fixture['expected']);
    test('OpenCode upstream catalog, budget, and update $index', () {
      Json summarize(int index) => catalog.summarizeToolCatalog(tools(opencodeFixture, index), budget: fixture['budget'] as int? ?? 2000);
      final current = summarize(fixture['catalog'] as int);
      expect(current, expected['summary']);
      expect(catalog.renderToolCatalog(current), expected['render']);
      if (fixture['previous'] case final int previous) {
        expect(catalog.updateToolCatalog(summarize(previous), current), expected['update']);
      }
    });
  }

  for (final (index, raw) in (openaiFixture['tokens'] as List).indexed) {
    final fixture = jsonObject(raw);
    test('Codex upstream normalization, word boundaries, stop words, and stemming $index', () {
      expect((fixture['input'] as List).cast<String>().map(searchTokens).toList(), fixture['expected']);
    });
  }
  test('Codex upstream Unicode words and identifier punctuation', () {
    final fixture = jsonObject(jsonDecode(File('test/fixtures/tool_search/openai_tokens.json').readAsStringSync()));
    expect((fixture['input'] as List).cast<String>().map(searchTokens).toList(), fixture['expected']);
  });
  for (final (index, raw) in (openaiFixture['bm25'] as List).indexed) {
    final fixture = jsonObject(raw);
    test('Codex upstream BM25 scores and ranking $index', () {
      final matches = BM25Index((fixture['documents'] as List).cast<String>()).search(fixture['query'] as String, 1000);
      // Rust's HashMap iteration leaves equal-score ordering unspecified.
      expect({for (final row in matches) row.index: row.score},
        {for (final row in fixture['expected'] as List) row['index']: row['score']});
      expect(matches.map((row) => row.score).toList(), orderedEquals(
        (fixture['expected'] as List).map((row) => row['score'])));
    });
  }
  for (final (index, raw) in (openaiFixture['search'] as List).indexed) {
    final fixture = jsonObject(raw);
    test('Codex upstream metadata corpus and selected tools $index: ${fixture['query']}', () {
      final current = tools(openaiFixture, fixture['catalog'] as int);
      expect(current.map(codex.toolSearchText).toList(), fixture['documents']);
      final found = codex.discoverTools(current, {'query': fixture['query'], if (fixture.containsKey('limit')) 'limit': fixture['limit']});
      final expected = [for (final name in fixture['names'] as List)
        openai.describeTool(current.singleWhere((tool) => tool['name'] == name))];
      expect(found, {'tools': [for (final tool in expected)
        {'name': tool['name'], 'description': tool['description']}]});
    });
  }
  for (final (index, raw) in (openaiFixture['schemas'] as List).indexed) {
    final fixture = jsonObject(raw);
    test('Codex upstream declaration schema, references, and byte budget $index', () {
      expect(openai.schemaType(fixture['schema'], maxBytes: fixture['budget'] as int? ?? 16000), fixture['expected']);
    });
  }
  for (final (index, raw) in (namespaceFixture['cases'] as List).indexed) {
    final fixture = jsonObject(raw);
    List<Json> catalog(Object? values) => [for (final entry in jsonObject(values).entries) {
      'name': '${entry.key}__probe', 'namespace': entry.key, 'tool_name': 'probe',
      'namespace_description': namespaceFixture['descriptions'][entry.value],
    }];
    test('Codex upstream namespace snapshot, delta, and UTF-8 budget $index', () {
      expect(namespaces.renderDeferredNamespaces(catalog(fixture['namespaces']),
        fixture.containsKey('previous') ? catalog(fixture['previous']) : null), fixture['expected']);
    });
  }
  for (final raw in declarationFixture['cases'] as List) {
    final fixture = jsonObject(raw), tool = jsonObject(fixture['tool']);
    test('Codex upstream declaration and callable name: ${fixture['name']}', () {
      final described = openai.describeTool(tool);
      expect({'name': described['name'], 'description': described['description']}, fixture['expected']);
      expect(codex.discoverTools([tool], {'query': 'archived'}),
        {'tools': [fixture['expected']]});
    });
  }
}
