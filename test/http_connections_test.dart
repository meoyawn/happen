import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai/ai.dart';
import 'package:http2/transport.dart' as h2;
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

SecurityContext _serverContext() => SecurityContext()
  ..useCertificateChain('test/fixtures/tls/cert.pem.txt')
  ..usePrivateKey('test/fixtures/tls/key.pem.txt');

void main() {
  test('both providers multiplex new tasks on one TLS connection and cancel only their stream', () async {
    final root = await Directory.systemTemp.createTemp('happen-http2-');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tls = _serverContext()..setAlpnProtocols(['h2'], true);
    final http = HttpClient(context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls/cert.pem.txt'));
    final connections = HttpConnections(http: http, context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls/cert.pem.txt'));
    final sockets = <SecureSocket>[];
    final waiting = Completer<void>(), reset = Completer<void>();
    final release = Completer<void>();
    var requests = 0;
    var dials = 0;
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await connections.close();
      http.close(force: true);
      for (final socket in sockets) { socket.destroy(); }
      await server.close();
      await root.delete(recursive: true);
    });
    server.listen((raw) async {
      // A lost TLS handshake precedes all HTTP bytes and is safe to retry.
      if (++dials == 1) {
        await raw.first;
        raw.add([21, 3, 3, 0, 2, 2, 80]);
        await raw.flush();
        raw.destroy();
        return;
      }
      final socket = await SecureSocket.secureServer(raw, tls);
      sockets.add(socket);
      expect(socket.selectedProtocol, 'h2');
      final peer = h2.ServerTransportConnection.viaSocket(socket);
      peer.incomingStreams.listen((stream) async {
        final bytes = <int>[];
        final fields = <String, String>{};
        await for (final message in stream.incomingMessages) {
          if (message is h2.HeadersStreamMessage) {
            fields.addAll({for (final field in message.headers) ascii.decode(field.name): utf8.decode(field.value)});
          } else if (message is h2.DataStreamMessage) { bytes.addAll(message.bytes); }
        }
        if (fields[':path'] == '/transcribe') {
          expect(fields['content-type'], startsWith('multipart/form-data; boundary='));
          expect(utf8.decode(bytes, allowMalformed: true), contains('filename="codex.wav"'));
          stream.sendHeaders([h2.Header.ascii(':status', '200')]);
          stream.sendData(utf8.encode('{"text":"VOICE"}'), endStream: true);
          return;
        }
        final body = jsonObject(jsonDecode(utf8.decode(bytes)));
        final openai = fields[':path'] == '/responses';
        expect(fields['authorization'], startsWith('Bearer fixture'));
        if (!openai) expect(body['reasoning_effort'], 'max');
        requests++;
        if (requests == 12) release.complete();
        if (jsonEncode(body).contains('WAIT_FOR_CANCEL')) {
          stream.onTerminated = (_) { if (!reset.isCompleted) reset.complete(); };
          waiting.complete();
          return;
        }
        // None of the first twelve can finish until all twelve have arrived.
        await release.future;
        stream.sendHeaders([h2.Header.ascii(':status', '200'),
          h2.Header.ascii('content-type', 'text/event-stream'), h2.Header.ascii('content-encoding', 'gzip')]);
        final payload = openai
          ? 'data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed', 'output': [
              {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'READY'}]},
            ], 'usage': {'input_tokens': 20, 'output_tokens': 1}}})}\n\n'
          : 'data: ${jsonEncode({'choices': [{'delta': {'content': 'READY'}, 'finish_reason': 'stop'}]})}\n\ndata: [DONE]\n\n';
        stream.sendData(gzip.encode(utf8.encode(payload)), endStream: true);
      });
    });
    await File('${root.path}/opencode-auth.json').writeAsString(jsonEncode({
      'version': 1, 'type': 'opencode', 'server': 'https://opencode.ai/console',
      'access_token': 'fixture-access', 'org_id': 'fixture-org',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    final auth = OpenCodeAuthManager(root.path, http: http, connections: connections);
    addTearDown(auth.close);
    final console = OpenCodeProvider(http: http, auth: auth, connections: connections,
      endpoint: Uri.parse('https://localhost:${server.port}/v1'));
    final openai = OpenAIProvider(ResponsesClient(http: http, connections: connections,
      endpoint: Uri.parse('https://localhost:${server.port}/responses'),
      credentials: ({bool refresh = false}) async => {'access_token': 'fixture-openai', 'account_id': 'fixture-account'}));
    Future<ModelReply> send(ModelProvider provider, String prompt, CancellationToken token) => provider.respond(
      ModelRequest(taskId: provider.newTaskId(),
        model: provider == console ? openCodeDeepSeekModel : 'gpt-6.1-sol',
        instructions: 'Reply briefly.', input: [ConversationItem.text('user', prompt)],
        tools: const [], settings: provider.resolveSettings({'reasoning': provider == console ? 'max' : 'high'}),
        effectiveReasoning: provider == console ? 'max' : 'high'), cancellation: token);
    final results = await Future.wait(List.generate(12, (i) => send(i.isEven ? console : openai,
      'hi', CancellationToken())), eagerError: true).timeout(const Duration(seconds: 10));
    expect(results.map((reply) => reply.text), everyElement('READY'));
    expect(sockets, hasLength(1));
    expect(dials, 2);
    final transcription = TranscriptionClient(http: http, connections: connections,
      endpoint: Uri.parse('https://localhost:${server.port}/transcribe'),
      credentials: ({bool refresh = false, required CancellationToken cancellation}) async => {
        'access_token': 'fixture-audio', 'account_id': 'fixture-account',
      });
    for (var recording = 0; recording < 2; recording++) {
      expect(await transcription.transcribe(Uint8List.fromList([82, 73, 70, 70]),
        accountId: 'fixture-account', cancellation: CancellationToken()), 'VOICE');
    }
    final cancelled = CancellationToken();
    final outcome = expectLater(send(console, 'WAIT_FOR_CANCEL', cancelled), throwsA(isA<CancelledException>()));
    await waiting.future.timeout(const Duration(seconds: 2));
    expect((await send(openai, 'hi', CancellationToken())).text, 'READY');
    cancelled.cancel();
    await outcome.timeout(const Duration(seconds: 2));
    await reset.future.timeout(const Duration(seconds: 2));
    expect((await send(console, 'hi', CancellationToken())).text, 'READY');
    expect(sockets, hasLength(1));
  });

  test('HTTP/1.1-only origins retain keep-alive and declared request lengths', () async {
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, _serverContext());
    final http = HttpClient(context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls/cert.pem.txt'));
    final connections = HttpConnections(http: http, context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls/cert.pem.txt'));
    final ports = <int>[];
    addTearDown(() async { await connections.close(); http.close(force: true); await server.close(force: true); });
    server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      expect(request.contentLength, utf8.encode('hello ✓').length);
      expect(await utf8.decoder.bind(request).join(), 'hello ✓');
      request.response.write('READY');
      await request.response.close();
    });
    for (var i = 0; i < 3; i++) {
      final response = await httpRequest(http, 'POST', Uri.parse('https://localhost:${server.port}/'),
        connections: connections, cancellation: CancellationToken(), body: utf8.encode('hello ✓'));
      expect(response.version, '1.1');
      expect(await utf8.decoder.bind(response).join(), 'READY');
    }
    expect(ports.toSet(), hasLength(1));
  });

  test('OpenAI retries an interrupted HTTP/2 response through its existing recovery policy', () async {
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0,
      _serverContext()..setAlpnProtocols(['h2'], true));
    final http = HttpClient();
    final connections = HttpConnections(context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls/cert.pem.txt'));
    final sockets = <SecureSocket>[];
    final partial = Completer<void>();
    final events = <Json>[];
    var requests = 0;
    addTearDown(() async {
      await connections.close();
      http.close(force: true);
      for (final socket in sockets) { socket.destroy(); }
      await server.close();
    });
    server.listen((socket) {
      sockets.add(socket);
      final peer = h2.ServerTransportConnection.viaSocket(socket);
      peer.incomingStreams.listen((stream) async {
        await stream.incomingMessages.drain<void>();
        stream.sendHeaders([h2.Header.ascii(':status', '200'), h2.Header.ascii('content-type', 'text/event-stream')]);
        if (++requests == 1) {
          stream.sendData(utf8.encode('data: {"type":"response.output_text.delta","delta":"PARTIAL"}\n\n'));
          await partial.future;
          socket.destroy();
        } else {
          stream.sendData(utf8.encode('data: ${jsonEncode({'type': 'response.completed', 'response': {
            'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
              'content': [{'type': 'output_text', 'text': 'READY'}]}],
          }})}\n\n'), endStream: true);
        }
      });
    });
    final client = ResponsesClient(http: http, connections: connections,
      endpoint: Uri.parse('https://localhost:${server.port}/responses'),
      credentials: ({bool refresh = false}) async => {'access_token': 'fixture', 'account_id': 'fixture'});
    Future<ResponsesReply> send() => client.respond(model: 'gpt-6.1-sol', instructions: 'Reply briefly.',
      input: const [], tools: const [], sessionId: 'fixture-session', reasoning: 'low',
      cancellation: CancellationToken(), onEvent: (event) {
        events.add(event);
        if (event['delta'] == 'PARTIAL' && !partial.isCompleted) partial.complete();
      });
    expect((await send().timeout(const Duration(seconds: 5))).text, 'READY');
    expect(events.where((event) => event['type'] == 'model.retrying'), hasLength(1));
    expect(requests, 2);
    expect(sockets, hasLength(2));
    expect((await send()).text, 'READY');
    expect(sockets, hasLength(2));
  });

  test('GOAWAY retires a connection while its existing response finishes', () async {
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0,
      _serverContext()..setAlpnProtocols(['h2'], true));
    final http = HttpClient();
    final connections = HttpConnections(context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls/cert.pem.txt'));
    final sockets = <SecureSocket>[];
    late h2.ServerTransportConnection draining;
    late h2.ServerTransportStream heldStream;
    addTearDown(() async {
      await connections.close();
      http.close(force: true);
      for (final socket in sockets) { socket.destroy(); }
      await server.close();
    });
    server.listen((socket) {
      sockets.add(socket);
      final peer = h2.ServerTransportConnection.viaSocket(socket);
      peer.incomingStreams.listen((stream) async {
        var hold = false;
        await for (final message in stream.incomingMessages) {
          if (message is h2.HeadersStreamMessage) {
            hold = message.headers.any((header) => ascii.decode(header.name) == ':path' && utf8.decode(header.value) == '/hold');
          }
        }
        if (hold) { draining = peer; heldStream = stream; }
        stream.sendHeaders([h2.Header.ascii(':status', '200')]);
        if (!hold) stream.sendData(utf8.encode('READY'), endStream: true);
      });
    });
    Future<HttpReply> send(String path) => httpRequest(http, 'GET', Uri.parse('https://localhost:${server.port}$path'),
      connections: connections, cancellation: CancellationToken());
    final held = await send('/hold');
    final first = utf8.decoder.bind(held).join();
    final finished = draining.finish();
    // The ACK follows GOAWAY in the peer's ordered frame stream.
    await draining.ping().timeout(const Duration(seconds: 2));
    expect(await utf8.decoder.bind(await send('/ready')).join(), 'READY');
    heldStream.sendData(utf8.encode('DRAINED'), endStream: true);
    expect(await first.timeout(const Duration(seconds: 2)), 'DRAINED');
    await finished;
    expect(await utf8.decoder.bind(await send('/ready')).join(), 'READY');
    expect(sockets, hasLength(2));
  });

  test('peer stream limits queue requests without replacing active connections and shutdown releases bodies', () async {
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0,
      _serverContext()..setAlpnProtocols(['h2'], true));
    final http = HttpClient();
    final connections = HttpConnections(context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls/cert.pem.txt'));
    final sockets = <SecureSocket>[];
    final pending = <h2.ServerTransportStream>[];
    final full = Completer<void>();
    var released = false, active = 0, peak = 0, seen = 0;
    void finish(h2.ServerTransportStream stream) {
      stream.sendData(utf8.encode('READY'), endStream: true);
      active--;
    }
    addTearDown(() async {
      await connections.close();
      http.close(force: true);
      for (final socket in sockets) { socket.destroy(); }
      await server.close();
    });
    server.listen((socket) {
      sockets.add(socket);
      final peer = h2.ServerTransportConnection.viaSocket(socket,
        settings: const h2.ServerSettings(concurrentStreamLimit: 2));
      peer.incomingStreams.listen((stream) async {
        var path = '';
        await for (final message in stream.incomingMessages) {
          if (message is h2.HeadersStreamMessage) {
            path = utf8.decode(message.headers.firstWhere((header) => ascii.decode(header.name) == ':path').value);
          }
        }
        active++;
        seen++;
        if (active > peak) peak = active;
        stream.sendHeaders([h2.Header.ascii(':status', '200')]);
        if (path == '/hold') return;
        if (released) { finish(stream); }
        else {
          pending.add(stream);
          if (pending.length == 2) full.complete();
        }
      });
    });
    final tokens = List.generate(6, (_) => CancellationToken());
    final requests = List.generate(6, (i) async {
      final response = await httpRequest(http, 'GET', Uri.parse('https://localhost:${server.port}/$i'),
        connections: connections, cancellation: tokens[i]);
      return utf8.decoder.bind(response).join();
    });
    final cancelled = expectLater(requests[2], throwsA(isA<CancelledException>()));
    await full.future.timeout(const Duration(seconds: 2));
    expect(seen, 2);
    tokens[2].cancel();
    await cancelled.timeout(const Duration(seconds: 2));
    released = true;
    for (final stream in pending) { finish(stream); }
    expect(await Future.wait([for (var i = 0; i < requests.length; i++) if (i != 2) requests[i]])
      .timeout(const Duration(seconds: 3)), everyElement('READY'));
    expect(seen, 5);
    expect(peak, 2);
    expect(sockets, hasLength(1));
    final held = await httpRequest(http, 'GET', Uri.parse('https://localhost:${server.port}/hold'),
      connections: connections, cancellation: CancellationToken());
    final stopped = expectLater(held.drain<void>(), throwsA(isA<CancelledException>()));
    await connections.close();
    await stopped.timeout(const Duration(seconds: 2));
  });
}
