import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

const browserTool = {
  'name': 'browser_title',
  'description': 'Return the title of a client browser tab.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'tab': {'type': 'integer'},
    },
    'required': ['tab'],
  },
};

void main() {
  for (final embedded in [false, true]) {
    test(
      'client tools over ${embedded ? 'in-process UDS' : 'loopback WebSocket'} preserve ownership and disconnect safely',
      () async {
        final root = await Directory.systemTemp.createTemp('client-tool-test-');
        final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <Json>[];
        var call = 0;
        await File('${root.path}/auth.json').writeAsString(
          jsonEncode({
            'type': 'chatgpt',
            'access_token': 'fixture',
            'refresh_token': 'fixture',
            'account_id': 'fixture',
            'expires_at': DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          }),
        );
        provider.listen((request) async {
          final payload = await utf8.decoder.bind(request).join();
          if (payload.isEmpty) {
            await request.response.close();
            return;
          }
          final body = jsonObject(jsonDecode(payload));
          requests.add(body);
          final input = (body['input'] as List).map(jsonObject).toList();
          final lastUser = input.lastIndexWhere(
            (item) => item['role'] == 'user',
          );
          final prompt = input[lastUser]['content'];
          final outputs = input
              .skip(lastUser + 1)
              .where(
                (item) => [
                  'function_call_output',
                  'custom_tool_call_output',
                ].contains(item['type']),
              )
              .toList();
          final result = outputs.isNotEmpty
              ? <Json>[
                  {
                    'type': 'message',
                    'role': 'assistant',
                    'content': [
                      {'type': 'output_text', 'text': outputs.last['output']},
                    ],
                  },
                ]
              : prompt == 'direct'
              ? <Json>[
                  {
                    'type': 'function_call',
                    'namespace': 'client',
                    'name': 'browser_title',
                    'arguments': '{"tab":3}',
                    'call_id': 'call_${++call}',
                  },
                ]
              : <Json>[
                  {
                    'type': 'custom_tool_call',
                    'namespace': 'functions',
                    'name': 'exec',
                    'call_id': 'call_${++call}',
                    'input': 'text(await Promise.all([tools.client__browser_title({tab:1}),tools.client__browser_title({tab:2})]));',
                  },
                ];
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(
            'data: ${jsonEncode({
              'type': 'response.completed',
              'response': {
                'status': 'completed',
                'output': result,
                'usage': {'input_tokens': 20, 'output_tokens': 10},
              },
            })}\n\n',
          );
          await request.response.close();
        });
        final endpoint = 'http://127.0.0.1:${provider.port}/responses';
        final server = embedded
            ? await AgentServer.startEmbedded(
                directory: root.path,
                endpoint: endpoint,
              )
            : await AgentServer.start(
                directory: root.path,
                port: 0,
                endpoint: endpoint,
              );
        final owner = await _Peer.connect(server.uri),
            observer = await _Peer.connect(server.uri);
        addTearDown(() async {
          await owner.close();
          await observer.close();
          final path = server.socketPath;
          await server.close();
          if (path != null)
            expect(
              await FileSystemEntity.type(path),
              FileSystemEntityType.notFound,
            );
          await provider.close(force: true);
          await root.delete(recursive: true);
        });
        if (embedded) {
          expect(server.http.address.type, InternetAddressType.unix);
          expect((await File(server.socketPath!).stat()).mode & 0x1ff, 0x180);
          await expectLater(
            AgentServer.start(
              directory: root.path,
              socketPath: server.socketPath,
            ),
            throwsA(isA<FileSystemException>()),
          );
        }
        final firstCalls = <Json>[];
        final twoCalls = Completer<void>();
        final subscription = owner.incoming.stream.listen((message) {
          if (message['method'] == 'tools.call') {
            firstCalls.add(message);
            if (firstCalls.length == 2) twoCalls.complete();
          }
        });
        final done = owner.terminal();
        final started = jsonObject(
          await owner.request('task.start', {
            'cwd': root.path,
            'prompt': 'parallel',
            'client_tools': [browserTool],
          }),
        );
        final task = started['task_id'];
        await twoCalls.future.timeout(const Duration(seconds: 10));
        await subscription.cancel();
        await observer.request('task.subscribe', {'task_id': task});
        final wrongOwner = observer.incoming.stream.firstWhere(
          (message) => message['id'] == firstCalls.first['id'],
        );
        observer.respond(firstCalls.first, 'forged');
        expect((await wrongOwner)['error'], isNotNull);
        await expectLater(
          observer.request('tools.register', {
            'task_id': task,
            'tools': [browserTool],
          }),
          throwsStateError,
        );
        // Complete backwards: correlation, not delivery order, determines results.
        owner.respond(firstCalls.last, 'second title');
        owner.respond(firstCalls.first, 'first title');
        final completed = await done;
        expect(
          completed['type'],
          'turn.completed',
          reason: completed.toString(),
        );
        final answer = completed['data']['text'] as String;
        expect(answer, contains('first title'));
        expect(answer, contains('second title'));
        expect(answer, isNot(contains('forged')));
        expect((requests.first['tools'] as List).map((v) => v['name']), [
          'functions',
        ]);
        final declaration = (requests.first['input'] as List).singleWhere(
          (v) => v['type'] == 'additional_tools',
        );
        expect(declaration['tools'][0]['name'], 'client');
        expect(declaration['tools'][0]['tools'][0]['name'], 'browser_title');

        // A direct model call uses the same bridge; no code-mode-only shortcut.
        final direct = owner.incoming.stream.firstWhere(
          (v) => v['method'] == 'tools.call',
        );
        final disconnected = observer.terminal(after: completed['seq'] as int);
        await owner.request('task.send', {'task_id': task, 'prompt': 'direct'});
        final pending = await direct.timeout(const Duration(seconds: 10));
        expect(pending['params']['arguments'], {'tab': 3});
        expect(
          (requests.last['input'] as List).any(
            (v) => v['type'] == 'additional_tools',
          ),
          isTrue,
          reason: 'Client tool declarations must survive loading the next turn from history',
        );
        await owner.close();
        final terminal = await disconnected;
        expect(terminal['type'], 'turn.completed', reason: terminal.toString());
        expect(terminal['data']['text'], contains('outcome is unknown'));
        final removal = (requests.last['input'] as List).lastWhere(
          (v) => v['role'] == 'developer',
        );
        expect(
          jsonEncode(removal),
          contains('All other client tools are unavailable'),
        );

        // Reattachment starts a new ownership lifetime with the same stable names.
        await observer.request('tools.register', {
          'task_id': task,
          'tools': [browserTool],
        });
        final afterReconnect = observer.incoming.stream.firstWhere(
          (v) => v['method'] == 'tools.call',
        );
        final cancelled = observer.terminal(after: terminal['seq'] as int);
        await observer.request('task.send', {
          'task_id': task,
          'prompt': 'direct',
        });
        final active = await afterReconnect.timeout(
          const Duration(seconds: 10),
        );
        final cancelNotification = observer.incoming.stream.firstWhere(
          (v) => v['method'] == 'tools.cancel',
        );
        await observer.request('task.cancel', {'task_id': task});
        expect((await cancelled)['type'], 'turn.cancelled');
        expect((await cancelNotification)['params']['call_id'], active['id']);
        expect((await observer.request('ping') as Map)['version'], '0.1.0');
      },
    );
  }
}

/// A protocol peer, without application/browser behavior, for server boundary tests.
class _Peer {
  _Peer(this.socket) {
    socket.listen(
      (raw) {
        final message = jsonObject(jsonDecode(raw as String));
        if (message.containsKey('event') &&
            !_closing &&
            socket.readyState == WebSocket.open) {
          socket.add(
            jsonEncode({
              'method': 'events.ack',
              'params': {'count': 1},
            }),
          );
        }
        final reply = message['method'] == null
            ? _pending.remove(message['id'])
            : null;
        if (reply != null) {
          if (message.containsKey('error')) {
            reply.completeError(StateError(message['error'].toString()));
          } else {
            reply.complete(message['result']);
          }
        } else {
          incoming.add(message);
        }
      },
      onDone: () {
        if (!incoming.isClosed) unawaited(incoming.close());
      },
    );
  }
  final WebSocket socket;
  final incoming = StreamController<Json>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  var _next = 0;
  bool _closing = false;

  static Future<_Peer> connect(Uri uri) async {
    final http = HttpClient()..findProxy = (_) => 'DIRECT';
    if (uri.scheme == 'unix') {
      http.connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(uri.path, type: InternetAddressType.unix),
        0,
      );
    }
    try {
      return _Peer(
        await WebSocket.connect(
          uri.scheme == 'unix' ? 'ws://localhost/ws' : uri.toString(),
          customClient: http,
        ),
      );
    } finally {
      http.close();
    }
  }

  Future<Object?> request(String method, [Json params = const {}]) {
    final id = ++_next, reply = Completer<Object?>();
    _pending[id] = reply;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return reply.future.timeout(const Duration(seconds: 10));
  }

  Future<Json> terminal({int after = 0}) => incoming.stream
      .where((v) => v['event'] != null)
      .map((v) => jsonObject(v['event']))
      .firstWhere(
        (v) =>
            [
              'turn.completed',
              'turn.cancelled',
              'turn.failed',
            ].contains(v['type']) &&
            (v['seq'] as int? ?? 0) > after,
      )
      .timeout(const Duration(seconds: 10));
  void respond(Json request, String text) => socket.add(
    jsonEncode({
      'id': request['id'],
      'result': {
        'success': true,
        'contentItems': [
          {'type': 'inputText', 'text': text},
        ],
      },
    }),
  );
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    await socket.close();
  }
}
