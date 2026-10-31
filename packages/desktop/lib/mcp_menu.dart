import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

/// Read-only inventory rows inside the composer's shared autocomplete popover.
class McpStatusMenu extends StatelessWidget {
  const McpStatusMenu({super.key, required this.inventory, required this.verbose,
    required this.loading, required this.failed, required this.query, required this.onRetry});
  final Json? inventory;
  final bool verbose, loading, failed;
  final String query;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xa61a1c1f);
    final all = (inventory?['servers'] as List? ?? []).map(jsonObject).toList();
    final rows = all.where((row) => mcpMatches(row, query)).toList();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (loading)
        Padding(padding: const EdgeInsets.all(8), child: Text(verbose ? 'Loading MCP inventory…' : 'Loading MCP status…', style: const TextStyle(fontSize: 13, color: muted)))
      else if (failed)
        TextButton(onPressed: onRetry, child: const Text('Unable to load MCP status. Retry'))
      else ...[
        if (inventory?['config_error'] case final String error)
          Padding(padding: const EdgeInsets.all(8), child: Text('$error. Showing the last accepted configuration.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error))),
        if (all.isEmpty || rows.isEmpty)
          Padding(padding: const EdgeInsets.all(8), child: Text(all.isEmpty ? 'No MCP servers configured' : 'No commands', style: const TextStyle(fontSize: 13, color: muted))),
        for (final server in rows)
          Semantics(enabled: false, child: Opacity(opacity: verbose ? 1 : .5,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  LayoutBuilder(builder: (context, constraints) => Row(children: [
                    ConstrainedBox(constraints: BoxConstraints(maxWidth: constraints.maxWidth * .6),
                      child: Text(server['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, height: 10 / 7, color: muted, fontWeight: verbose ? FontWeight.w600 : null))),
                    const SizedBox(width: 8),
                    Expanded(child: Text(server['enabled'] == false ? 'Disabled' : 'Enabled', maxLines: 1,
                      style: const TextStyle(fontSize: 13, height: 10 / 7, color: muted))),
                  ])),
                  Padding(padding: const EdgeInsets.only(top: 2), child: Text(_authLabel(server), style: const TextStyle(fontSize: 12, height: 4 / 3, color: muted))),
                  if (verbose) ...[
                    _detail('${_stateLabel(server)} · ${server['tool_count']} ${server['tool_count'] == 1 ? 'tool' : 'tools'}'),
                    if (server['error'] case final String error) _detail(error),
                    if (server['state'] == 'ready') ...[
                      _detail('Tools: ${(server['tools'] as List).isEmpty ? '(none)' : (server['tools'] as List).join(', ')}'),
                      _detail('Resources: ${server['resources_error'] ?? _resourceLabels(server['resources'], 'uri')}'),
                      _detail('Resource templates: ${server['resource_templates_error'] ?? _resourceLabels(server['resource_templates'], 'uriTemplate')}'),
                    ] else _detail('Tool and resource inventory unavailable'),
                  ],
                ])),
          )),
      ],
    ]);
  }
}

bool mcpMatches(Json server, String query) {
  final text = '${server['name']} ${server['enabled'] == false ? 'Disabled' : 'Enabled'} ${_authLabel(server)} ${_stateLabel(server)}'.toLowerCase();
  var offset = 0;
  for (final character in query.trim().toLowerCase().runes) {
    final unit = String.fromCharCode(character);
    final next = text.indexOf(unit, offset);
    if (next < 0) return false;
    offset = next + unit.length;
  }
  return true;
}

Widget _detail(String text) => Padding(padding: const EdgeInsets.only(top: 4), child: Text(text, style: const TextStyle(fontSize: 12, height: 4 / 3)));

String _resourceLabels(Object? values, String uri) => (values as List? ?? []).isEmpty ? '(none)' :
    (values as List).map((value) => '${value['title'] ?? value['name']} (${value[uri]})').join(', ');

String _authLabel(Json server) => switch (server['auth_status']) {
  'not_authenticated' => 'Not authenticated',
  'configured_headers' => 'Configured HTTP headers',
  _ => 'Auth unsupported',
};

String _stateLabel(Json server) => switch (server['state']) {
  'ready' => 'Connected', 'connecting' || 'starting' => 'Starting',
  'reconnecting' => 'Reconnecting', 'failed' => 'Failed',
  'authentication_required' => 'Authentication required', 'disabled' => 'Disabled', _ => 'Unavailable',
};
