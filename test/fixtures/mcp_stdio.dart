import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Independent MCP 2026-07-28 peer. The process identity lets the client test
// observe sharing and supervised restarts through actual stdin/stdout pipes.
void main(List<String> arguments) {
  final starts = Platform.environment['MCP_STARTS_FILE'];
  if (starts != null) {
    final overlaps = Platform.environment['MCP_OVERLAPS_FILE'];
    if (overlaps != null && File(starts).existsSync()) {
      for (final previous in File(starts).readAsLinesSync().map(int.parse)) {
        if (Process.killPid(previous, ProcessSignal.sigcont)) {
          File(overlaps).writeAsStringSync('$previous:$pid\n', mode: FileMode.append);
        }
      }
    }
    File(starts).writeAsStringSync('$pid\n', mode: FileMode.append);
  }
  final legacy = Platform.environment['MCP_LEGACY'] == 'true';
  final catalogs = Platform.environment['MCP_CONTRACT_CATALOGS'] == 'true';
  final streams = <String, Timer>{};
  final pending = <String>{};
  void send(Map<String, dynamic> value) =>
      stdout.writeln(jsonEncode({'jsonrpc': '2.0', ...value}));
  void notification(String id, String method, Map<String, dynamic> params) =>
      send({
        'method': method,
        'params': {
          ...params,
          '_meta': {'io.modelcontextprotocol/subscriptionId': id},
        },
      });
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) async {
          final request = jsonDecode(line) as Map<String, dynamic>;
          if (Platform.environment['MCP_REQUESTS_FILE'] case final String path) {
            File(path).writeAsStringSync('${request['method']}\n', mode: FileMode.append);
          }
          final id = request['id'] as String?;
          final params = request['params'] as Map<String, dynamic>;
          if (request['method'] == 'notifications/cancelled') {
            final target = params['requestId'] as String;
            streams.remove(target)?.cancel();
            pending.remove(target);
            return;
          }
          if (!legacy && params['_meta']?['io.modelcontextprotocol/protocolVersion'] !=
              '2026-07-28') {
            send({
              'id': id,
              'error': {'code': -32022, 'message': 'Protocol version required'},
            });
            return;
          }
          switch (request['method']) {
            case 'server/discover':
              if (legacy) {
                send({'id': id, 'error': {'code': -32601, 'message': 'Method not found'}});
                return;
              }
              final gate = Platform.environment['MCP_DISCOVERY_GATE'];
              while (gate != null && !await File(gate).exists()) {
                await Future<void>.delayed(const Duration(milliseconds: 5));
              }
              final delay =
                  int.tryParse(
                    Platform.environment['MCP_DISCOVERY_DELAY_MS'] ?? '',
                  ) ??
                  0;
              if (delay > 0) {
                await Future<void>.delayed(Duration(milliseconds: delay));
              }
              send({
                'id': id,
                'result': {
                  'supportedVersions': ['2026-07-28'],
                  if (catalogs) '_meta': {'io.modelcontextprotocol/serverInfo': {'name': 'fixture', 'version': '1'}}
                  else 'serverInfo': {'name': 'fixture', 'version': '1'},
                  'capabilities': {'tools': <String, Object?>{}, 'events': <String, Object?>{}, 'resources': <String, Object?>{},
                    if (catalogs) 'prompts': <String, Object?>{}},
                  if (Platform.environment['MCP_INSTRUCTIONS'] case final String instructions)
                    'instructions': instructions,
                },
              });
            case 'initialize':
              send({'id': id, 'result': {'protocolVersion': '2025-06-18',
                'capabilities': {'tools': <String, Object?>{}, 'resources': <String, Object?>{}, if (catalogs) 'prompts': <String, Object?>{}},
                'serverInfo': {'name': 'legacy-fixture', 'version': '1'}}});
            case 'notifications/initialized': return;
            case 'tools/list':
              send({
                'id': id,
                'result': {
                  'tools': [
                    for (var i = 0; i < (int.tryParse(Platform.environment['MCP_EXTRA_TOOLS'] ?? '') ?? 0); i++)
                      {
                        'name': 'unused_$i',
                        'description': 'Unrelated archive operation $i',
                        'inputSchema': {
                          'type': 'object',
                          'properties': {'unused_schema_$i': {'type': 'string'}},
                        },
                      },
                    {
                      'name': 'probe',
                      'description': Platform.environment['MCP_TOOL_DESCRIPTION_BYTES'] == null
                        ? Platform.environment['MCP_TOOL_DESCRIPTION'] ?? 'Probe process ownership'
                        : 'x' * int.parse(Platform.environment['MCP_TOOL_DESCRIPTION_BYTES']!),
                      'inputSchema': {
                        'type': 'object',
                        'properties': {
                          'action': {'type': 'string'},
                          'bytes': {'type': 'integer'},
                        },
                      },
                    },
                  ],
                },
              });
            case 'resources/list':
              if (Platform.environment['MCP_RESOURCES_WAIT'] == 'true') {
                pending.add(id!);
                return;
              }
              send({
                'id': id,
                'result': {
                  'resources': [
                    if (catalogs) {'name': 'example-note', 'title': 'Example Note', 'uri': 'memo://codex/example-note',
                      'description': 'A sample MCP resource exposed for integration tests.', 'mimeType': 'text/plain'}
                    else {'name': 'readme', 'title': 'Readme', 'uri': 'file:///readme'},
                  ],
                },
              });
            case 'resources/templates/list':
              send({
                'id': id,
                'result': {
                  'resourceTemplates': [
                    if (catalogs) {'name': 'codex-memo', 'title': 'Codex Memo', 'uriTemplate': 'memo://codex/{slug}',
                      'description': 'Template for memo://codex/{slug} resources used in tests.', 'mimeType': 'text/plain'}
                    else {'name': 'document', 'uriTemplate': 'file:///docs/{id}'},
                  ],
                },
              });
            case 'resources/read':
              if (params['uri'] != 'memo://codex/example-note') {
                send({'id': id, 'error': {'code': -32002, 'message': 'resource_not_found', 'data': {'uri': params['uri']}}});
              } else {
                send({'id': id, 'result': {'contents': [{'uri': params['uri'], 'mimeType': 'text/plain',
                  'text': 'This is a sample MCP resource served by the rmcp test server.'}]}});
              }
            case 'prompts/list':
              send({'id': id, 'result': {'prompts': [{'name': 'memo-summary', 'title': 'Summarize a memo',
                'description': 'Summarize a selected memo.', 'arguments': [{'name': 'slug', 'description': 'Memo slug', 'required': true}]}]}});
            case 'prompts/get':
              if (params['name'] != 'memo-summary' || params['arguments']?['slug'] is! String) {
                send({'id': id, 'error': {'code': -32602, 'message': 'invalid_prompt', 'data': {'name': params['name']}}});
              } else {
                send({'id': id, 'result': {'description': 'Summarize a selected memo.', 'messages': [
                  {'role': 'user', 'content': {'type': 'text', 'text': 'Summarize memo ${params['arguments']['slug']}.'}},
                ]}});
              }
            case 'tools/call':
              final action = params['arguments']['action'];
              if (action == 'environment') {
                send({'id': id, 'result': {'content': <Object?>[], 'structuredContent': {
                  'cwd': Directory.current.path,
                  'environment': {for (final name in params['arguments']['names'] as List)
                    name as String: Platform.environment[name]},
                }}});
                return;
              }
              if (action == 'crash') {
                exit(7);
              }
              if (action == 'wait') {
                pending.add(id!);
                return;
              }
              if (action == 'large' || action == 'large_error') {
                final bytes = params['arguments']['bytes'] as int;
                send({
                  'id': id,
                  'result': {
                    'resultType': 'complete',
                    'content': [
                      {
                        'type': 'text',
                        'text': jsonEncode({
                          'padding': 'BEGIN${'x' * bytes}END',
                          'libraries': [
                            {'uri': 'package:desktop/app.dart', 'id': 'app'},
                            {'uri': 'dart:core', 'id': 'core'},
                          ],
                        }),
                      },
                    ],
                    'structuredContent': {'bytes': bytes},
                    'isError': action == 'large_error',
                    '_meta': {'private': 'client-only-metadata'},
                  },
                });
                return;
              }
              send({
                'id': id,
                'result': {
                  'resultType': 'complete',
                  'content': [
                    {
                      'type': 'text',
                      'text': jsonEncode({
                        'pid': pid,
                        'waiting': pending.length,
                        'streams': streams.length,
                        if (starts != null) 'cwd': Directory.current.path,
                        if (starts != null) 'arguments': arguments,
                        if (starts != null) 'environment': {for (final entry in Platform.environment.entries)
                          if (entry.key.startsWith('MCP_SCOPE_')) entry.key: entry.value},
                      }),
                    },
                  ],
                },
              });
            case 'events/list':
              send({
                'id': id,
                'result': {
                  'events': [
                    {
                      'name': 'tick',
                      'description': 'Process ticks',
                      'delivery': ['push'],
                      'inputSchema': {'type': 'object'},
                      'payloadSchema': {'type': 'object'},
                    },
                  ],
                },
              });
            case 'events/stream':
              var tick = 0;
              notification(id!, 'notifications/events/active', {
                'cursor': params['cursor'],
                'truncated': false,
              });
              streams[id] = Timer.periodic(const Duration(milliseconds: 40), (
                _,
              ) {
                notification(id, 'notifications/events/event', {
                  'eventId': '$id:${++tick}',
                  'name': 'tick',
                  'timestamp': DateTime.now().toUtc().toIso8601String(),
                  'data': {'pid': pid},
                  'cursor': '$tick',
                });
              });
            default:
              send({
                'id': id,
                'error': {
                  'code': -32601,
                  'message': 'Unsupported fixture operation',
                },
              });
          }
        },
        onDone: () {
          for (final timer in streams.values) {
            timer.cancel();
          }
        },
      );
}
