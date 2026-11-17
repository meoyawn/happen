import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  // Codex 49d657aad0: core/src/client.rs bounds only the WebSocket
  // handshake; codex-api/src/endpoint/responses_websocket.rs awaits sending
  // the turn before reading with the model idle budget. Keep five opaque
  // image payloads in order, as in core/tests/suite/image_rollout.rs.
  for (final transport in ['http', 'websocket']) {
    test('$transport sends five images without restarting a slow accepted request', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = ResponsesClient(endpoint: Uri.parse('http://127.0.0.1:${server.port}/responses'),
        credentials: ({bool refresh = false}) async => {});
      final cancellation = TimeoutCancellationToken(const Duration(seconds: 5));
      final sockets = <WebSocket>[];
      final requests = <Json>[];
      final events = <Json>[];
      // Synthetic base64 keeps the wire size of the reported five-photo
      // request (~14.5 MB) without saving the user's photographs as fixtures.
      final images = [for (var i = 0; i < 5; i++)
        {'type': 'input_image', 'image_url': 'data:image/jpeg;base64,${String.fromCharCode(65 + i) * 2900000}'}];
      final input = <Json>[{'type': 'message', 'role': 'user', 'content': [
        {'type': 'input_text', 'text': 'Read these five meters. ✓🌱'}, ...images,
      ]}];
      addTearDown(() async {
        cancellation.cancel(); client.close();
        for (final socket in sockets) { unawaited(socket.close()); }
        await server.close(force: true);
      });
      const created = <String, dynamic>{'type': 'response.created'};
      const completed = <String, dynamic>{'type': 'response.completed', 'response': {
        'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
          'content': [{'type': 'output_text', 'text': 'Five images received'}]}],
      }};
      Future<void> receive(String raw, void Function(Json) send) async {
        requests.add(jsonObject(jsonDecode(raw)));
        // Real inference took 47 seconds to admit the captured request.
        await Future<void>.delayed(const Duration(seconds: 47));
        send(created); send(completed);
      }
      final reply = await runZoned(() async {
        server.listen((request) async {
          try {
            if (WebSocketTransformer.isUpgradeRequest(request)) {
              final socket = await WebSocketTransformer.upgrade(request);
              sockets.add(socket);
              socket.listen((raw) => unawaited(receive(raw as String, (event) {
                if (socket.readyState == WebSocket.open) socket.add(jsonEncode(event));
              })));
            } else {
              final raw = await utf8.decoder.bind(request).join();
              request.response.headers.contentType = ContentType('text', 'event-stream');
              await receive(raw, (event) => request.response.write('data: ${jsonEncode(event)}\n\n'));
              await request.response.close();
            }
          } on HttpException { /* The failing baseline aborts its upload. */ }
          on SocketException { /* The failing baseline aborts its upload. */ }
        });
        return client.respond(model: 'gpt-6.1-sol', instructions: '', input: input, tools: [],
          sessionId: newId(), cancellation: cancellation, transport: transport, reasoning: 'low',
          onEvent: (event) {
            events.add(event);
            // Stop a failing baseline from repeatedly uploading 14.5 MB.
            if (event['type'] == 'model.retrying') cancellation.cancel();
          });
      }, zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
        parent.createTimer(zone, duration == const Duration(seconds: 5) || duration == const Duration(seconds: 47)
          ? duration ~/ 100 : duration, callback)));
      expect(reply.text, 'Five images received');
      expect(requests, hasLength(1), reason: 'A healthy upload must not be replayed or switch transports');
      expect(requests.single['input'].last, input.single);
      expect(events.map((event) => event['type']), ['model.connected']);
    });
  }
}
