import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'web_search_schema.dart';
import 'web_search_description.dart';

// SearchCommands at Codex efdacaf46ff54660a239189a6d62434c5db33d2c.
const webSearchDefinition = ToolDefinition(
  name: 'run',
  namespace: 'web',
  description: webSearchInstructions,
  parameters: webSearchParameters,
);

const webSearchHost = <String, dynamic>{
  'name': 'web__run', 'namespace': 'web', 'tool_name': 'run',
  'namespace_description': 'Tools in the web namespace.',
  'description': webSearchInstructions, 'parameters': webSearchParameters,
};

final _searchProperties = jsonObject(webSearchParameters['properties']);
final _literatureParameters = <String, dynamic>{
  ...webSearchParameters,
  'properties': {
    ..._searchProperties,
    'literature_search_query': {
      ...jsonObject(_searchProperties['search_query']),
      'description': 'Search for scientific papers. Open relevant papers and cite the primary sources you use.',
    },
  },
};

final _literatureDefinition = ToolDefinition.fromJson({
  ...webSearchDefinition.toJson(), 'parameters': _literatureParameters,
});
final _literatureHost = {...webSearchHost, 'parameters': _literatureParameters};

ToolDefinition webSearchDefinitionFor({required bool literatureSearch}) =>
  literatureSearch ? _literatureDefinition : webSearchDefinition;

Json webSearchHostFor({required bool literatureSearch}) =>
  literatureSearch ? _literatureHost : webSearchHost;

Json webSearchCommands(Object? value, {bool literatureSearch = false}) {
  final commands = jsonObject(value);
  validateToolInput(commands, literatureSearch ? _literatureParameters : webSearchParameters, 'web.run');
  return commands;
}

// Codex ext/web-search/src/tool.rs::command_action. Results remain opaque so
// newer server projections survive storage and client delivery unchanged.
Json webSearchAction(Json commands) {
  for (final key in ['search_query', 'literature_search_query', 'image_query']) {
    final queries = (commands[key] as List? ?? []).map((query) => query['q'] as String).toList();
    if (queries.isNotEmpty) {
      return {'type': 'search', 'query': queries.length == 1 ? queries.single : null,
        'queries': queries.length > 1 ? queries : null};
    }
  }
  String? url(Object? ref) {
    if (ref is! String) return null;
    final uri = Uri.tryParse(ref);
    return uri != null && uri.hasScheme &&
      (!{'http', 'https'}.contains(uri.scheme) || uri.host.isNotEmpty) ? ref : null;
  }
  final open = (commands['open'] as List? ?? []).firstOrNull;
  final opened = url(open?['ref_id']);
  if (opened != null) return {'type': 'openPage', 'url': opened};
  final find = (commands['find'] as List? ?? []).firstOrNull;
  if (find != null) return {'type': 'findInPage', 'url': url(find['ref_id']), 'pattern': find['pattern']};
  return {'type': 'other'};
}

String webSearchActionDetail(Json action) => switch (action['type']) {
  'search' => action['query'] as String? ??
    ((action['queries'] as List? ?? []).firstOrNull as String? ?? '') +
      ((action['queries'] as List? ?? []).length > 1 ? ' ...' : ''),
  'openPage' => action['url'] as String? ?? '',
  'findInPage' => [if (action['pattern'] != null) "'${action['pattern']}'", if (action['url'] != null) action['url']].join(' in '),
  _ => '',
};
