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
        (line) {
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
              send({
                'id': id,
                'result': {
                  'supportedVersions': ['2026-07-28'],
                  'serverInfo': {'name': 'fixture', 'version': '1'},
                  'capabilities': {'tools': {}, 'events': {}},
                },
              });
            case 'tools/list':
              send({
                'id': id,
                'result': {
                  'tools': [
                    {
                      'name': 'probe',
                      'description': 'Probe process ownership',
                      'inputSchema': {
                        'type': 'object',
                        'properties': {
                          'action': {'type': 'string'},
                        },
                      },
                    },
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
