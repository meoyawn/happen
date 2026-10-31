import 'package:protocol/protocol.dart';

import 'signatures.dart';

// CodeModeCatalog and CodeModeInstructions at the pinned OpenCode revision.
// One global budget covers every namespace; pinned entries always remain shown.
Json summarizeToolCatalog(List<Json> catalog, {int budget = 2000}) {
  final groups = <String, List<Json>>{};
  for (final tool in {for (final tool in catalog) tool['name']: tool}.values) {
    (groups[(tool['name'] as String).split('.').first] ??= []).add(tool);
  }
  final namespaces = <Json>[];
  for (final name in groups.keys.toList()..sort()) {
    final tools = groups[name]!;
    final listings = [for (final tool in tools) {
      'path': tool['name'],
      'line': '  - ${toolSignature(tool)}${_description(tool['description'] as String? ?? '')}',
    }]..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    final pinned = {for (final tool in tools) if (tool['pinned'] == true) tool['name']};
    final ranked = listings.where((entry) => !pinned.contains(entry['path'])).toList()..sort((a, b) =>
      _cost(a['line'] as String) != _cost(b['line'] as String)
        ? _cost(a['line'] as String).compareTo(_cost(b['line'] as String))
        : (a['path'] as String).compareTo(b['path'] as String));
    final descriptions = tools.map((tool) => tool['namespace_description']).whereType<String>().where((text) => text.isNotEmpty);
    namespaces.add({
      'name': name, if (descriptions.isNotEmpty) 'description': descriptions.first,
      'count': listings.length, 'entries': <Json>[],
      '_listings': listings, '_ranked': ranked, '_selected': pinned, '_index': 0,
    });
  }
  var remaining = budget - namespaces.fold<int>(0, (sum, ns) => sum + _cost(namespaceLine(ns))) -
    namespaces.fold<int>(0, (sum, ns) => sum + (ns['_listings'] as List).where((entry) =>
      (ns['_selected'] as Set).contains(entry['path'])).fold<int>(0, (sum, entry) => sum + _cost(entry['line'] as String)));
  final active = namespaces.toList();
  while (active.isNotEmpty) {
    for (final ns in active.toList()) {
      final ranked = ns['_ranked'] as List, index = ns['_index'] as int;
      if (index >= ranked.length || _cost(ranked[index]['line'] as String) > remaining) { active.remove(ns); continue; }
      (ns['_selected'] as Set).add(ranked[index]['path']);
      ns['_index'] = index + 1;
      remaining -= _cost(ranked[index]['line'] as String);
      if (index + 1 == ranked.length) active.remove(ns);
    }
  }
  for (final ns in namespaces) {
    ns['entries'] = (ns['_listings'] as List).where((entry) => (ns['_selected'] as Set).contains(entry['path'])).toList();
    ns.removeWhere((key, _) => key.startsWith('_'));
  }
  return {'total': namespaces.fold<int>(0, (sum, ns) => sum + (ns['count'] as int)),
    'shown': namespaces.fold<int>(0, (sum, ns) => sum + (ns['entries'] as List).length), 'namespaces': namespaces};
}

int _cost(String text) => (text.length / 4).round();
String _description(String description) {
  final first = description.split('\n').first.trim();
  final text = first.length > 120 ? '${first.substring(0, 117)}...' : first;
  return text.isEmpty ? '' : ' // $text';
}

String namespaceLine(Json ns) {
  final count = ns['count'] == 1 ? '1 tool' : '${ns['count']} tools';
  final shown = (ns['entries'] as List).length;
  final label = shown == ns['count'] ? count : shown == 0 ? '$count, none shown' : '$count, $shown shown';
  return '- ${ns['name']} ($label)${ns['description'] == null ? '' : ' // ${ns['description']}'}';
}

const searchSignature = '''search({
  query?: string,
  namespace?: string,
  /** @integer @exclusiveMinimum 0 */
  limit?: number,
  /** @integer @minimum 0 */
  offset?: number,
}): {
  items: Array<{
      path: string,
      description: string,
      signature: string,
    }>,
  /** @integer @minimum 0 */
  remaining: number,
  next: {
      /** @integer @minimum 0 */
      offset: number,
    } | null,
}''';

String renderToolCatalog(Json catalog) {
  if (catalog['total'] == 0) {
    return 'No Code Mode tools are currently available. Later Code Mode catalog updates may add or remove tools. Do not call `execute` unless there is at least one available Code Mode tool.';
  }
  final partial = catalog['shown'] != catalog['total'];
  final discovery = partial
    ? 'The catalog is partial. Before calling a tool that is not listed below, find it with the global `search(...)` function. Do not guess tool names. Each result\'s `path` is the complete call expression: write it out as code, for example `await tools.ns.tool_name({ ... })`. Do not use it as a key such as `tools[path]`.\n\n- $searchSignature'
    : 'The catalog is complete. Do not guess tool names.';
  final lines = [for (final ns in (catalog['namespaces'] as List).map(jsonObject)) ...[
    namespaceLine(ns), for (final entry in ns['entries'] as List) entry['line'] as String,
  ]];
  return '# Code Mode\n\nThe tools listed below${partial ? ', and `search`,' : ''} cannot be called directly: they only work as JavaScript inside the `execute` tool. Every other tool you have is a normal tool call: call it directly, never inside `execute`.\n\n$discovery\n\n## Code Mode tools (call only inside `execute`)\n\n${lines.join('\n')}';
}

String updateToolCatalog(Json previous, Json current) {
  final replacement = 'The Code Mode tool catalog has changed. This catalog supersedes the previous Code Mode tool catalog.\n\n${renderToolCatalog(current)}';
  if (current['total'] == 0 || (previous['shown'] == previous['total']) != (current['shown'] == current['total'])) return replacement;
  Map<String, Json> namespaces(Json summary) => {for (final ns in (summary['namespaces'] as List).map(jsonObject)) ns['name'] as String: ns};
  final before = namespaces(previous), after = namespaces(current);
  final descriptionsBefore = {for (final entry in before.entries) if (entry.value['description'] != null) entry.key: entry.value['description']};
  final descriptionsAfter = {for (final entry in after.entries) if (entry.value['description'] != null) entry.key: entry.value['description']};
  if (descriptionsBefore.length != descriptionsAfter.length || descriptionsBefore.entries.any((entry) => descriptionsAfter[entry.key] != entry.value)) return replacement;
  Map<String, Json> entries(Json summary) => {for (final ns in summary['namespaces'] as List)
    for (final entry in (ns['entries'] as List).map(jsonObject)) entry['path'] as String: entry};
  final prior = entries(previous), next = entries(current);
  final added = next.keys.where((key) => !prior.containsKey(key)).toList();
  final removed = prior.keys.where((key) => !next.containsKey(key)).toList();
  final changed = next.keys.where((key) => prior.containsKey(key) && prior[key]!['line'] != next[key]!['line']).toList();
  final parts = ['The Code Mode tool catalog has changed.'];
  if (current['shown'] != current['total']) {
    if (added.isNotEmpty || removed.isNotEmpty || changed.isNotEmpty) return replacement;
    final newNamespaces = after.keys.where((key) => !before.containsKey(key)).toList();
    final removedNamespaces = before.keys.where((key) => !after.containsKey(key)).toList();
    final changedNamespaces = after.keys.where((key) => before.containsKey(key) && before[key]!['count'] != after[key]!['count']).toList();
    if (newNamespaces.isEmpty && removedNamespaces.isEmpty && changedNamespaces.isEmpty) return replacement;
    if (newNamespaces.isNotEmpty) parts.add('New tool namespaces are available: ${newNamespaces.map((key) => '`${after[key]!['name']}` (${after[key]!['count']} tools)').join(', ')}.');
    if (changedNamespaces.isNotEmpty) parts.add('The following namespace inventories changed; search them again before relying on previous results: ${changedNamespaces.map((key) => '`${after[key]!['name']}` now has ${after[key]!['count']} tools').join(', ')}.');
    if (removedNamespaces.isNotEmpty) parts.add('The following tool namespaces are no longer available and must not be used: ${removedNamespaces.map((key) => '`${before[key]!['name']}`').join(', ')}.');
  } else {
    if (added.isEmpty && removed.isEmpty && changed.isEmpty) return replacement;
    if (added.isNotEmpty) parts.add(['New tools are available in addition to those previously listed:', ...added.map((key) => next[key]!['line'])].join('\n'));
    if (changed.isNotEmpty) parts.add(['Changed tool listings supersede the previously listed ones:', ...changed.map((key) => next[key]!['line'])].join('\n'));
    if (removed.isNotEmpty) parts.add('The following tools are no longer available and must not be called: ${removed.map(toolExpression).join(', ')}.');
  }
  final delta = parts.join('\n\n');
  return delta.length < replacement.length ? delta : replacement;
}
