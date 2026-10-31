import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Independent MCP 2026-07-28 peer. The process identity lets the client test
// observe sharing and supervised restarts through actual stdin/stdout pipes.
void main() {
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
          final id = request['id'] as String?;
          final params = request['params'] as Map<String, dynamic>;
          if (request['method'] == 'notifications/cancelled') {
            final target = params['requestId'] as String;
            streams.remove(target)?.cancel();
            pending.remove(target);
            return;
          }
          if (params['_meta']?['io.modelcontextprotocol/protocolVersion'] !=
              '2026-07-28') {
            send({
              'id': id,
              'error': {'code': -32022, 'message': 'Protocol version required'},
            });
            return;
          }
          switch (request['method']) {
            case 'server/discover':
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
                  'serverInfo': {'name': 'fixture', 'version': '1'},
                  'capabilities': {'tools': {}, 'events': {}, 'resources': {}},
                  if (Platform.environment['MCP_INSTRUCTIONS'] case final String instructions)
                    'instructions': instructions,
                },
              });
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
                      'description': Platform.environment['MCP_TOOL_DESCRIPTION'] ?? 'Probe process ownership',
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
                    {'name': 'readme', 'title': 'Readme', 'uri': 'file:///readme'},
                  ],
                },
              });
            case 'resources/templates/list':
              send({
                'id': id,
                'result': {
                  'resourceTemplates': [
                    {'name': 'document', 'uriTemplate': 'file:///docs/{id}'},
                  ],
                },
              });
            case 'tools/call':
              final action = params['arguments']['action'];
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
