import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Uri endpoint;
  late CancellationToken cancellation;
  final sockets = <WebSocket>[];
  const auth = {'access_token': 'fixture-secret', 'account_id': 'fixture-account'};
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('ws://127.0.0.1:${server.port}/dictation/stream?dictation_surface=composer');
    cancellation = CancellationToken();
  });
  tearDown(() async {
    cancellation.cancel();
    for (final socket in sockets) { await socket.close(); }
    sockets.clear();
    await server.close(force: true);
  });

  test('live audio receives ordered revisions before close and accepts independently numbered finals', () async {
    final audio = Completer<List<int>>();
    final revisions = <String>[];
    var closes = 0;
    server.listen((request) async {
      expect(request.uri.toString(), '/dictation/stream?dictation_surface=composer');
      expect(request.headers.value('authorization'), 'Bearer fixture-secret');
      expect(request.headers.value('chatgpt-account-id'), 'fixture-account');
      expect(request.headers.value('sec-websocket-protocol'), 'chatgpt-dictation, codex-desktop');
      final socket = await WebSocketTransformer.upgrade(request, protocolSelector: (_) => 'chatgpt-dictation');
      sockets.add(socket);
      socket.listen((raw) {
        final event = jsonObject(jsonDecode(raw as String));
        void send(Json event) => socket.add(jsonEncode(event));
        switch (event['type']) {
          case 'session.start':
            final config = jsonObject(event['config']);
            expect(config['input_audio_format'], 'pcm16');
            expect(config['sample_rate_hz'], 16000);
            expect(config['num_channels'], 1);
            expect(config['transcript_delivery_mode'], 'segment');
            send({'type': 'session.started'});
          case 'audio.append':
            audio.complete(base64Decode(event['audio'] as String));
            send({'type': 'transcript.segment', 'utterance_id': 'a', 'revision': 3, 'text': 'one'});
            send({'type': 'transcript.segment', 'utterance_id': 'a', 'revision': 2, 'text': 'stale'});
            send({'type': 'transcript.segment', 'utterance_id': 'b', 'revision': 1, 'text': 'two'});
          case 'session.close':
            closes++;
            send({'type': 'transcript.final', 'utterance_id': 'a', 'revision': 0, 'text': 'One.'});
            send({'type': 'transcript.segment', 'utterance_id': 'a', 'revision': 99, 'text': 'late'});
            send({'type': 'transcript.final', 'utterance_id': 'b', 'revision': 0, 'text': 'Two.'});
            send({'type': 'session.updated', 'session': {'status': 'closed'}});
        }
      });
    });
    final stream = TranscriptionStream(onTranscript: revisions.add, onError: () => fail('Unexpected stream failure'));
    await stream.connect(auth, cancellation: cancellation, endpoint: endpoint);
    stream.append(Uint8List.fromList([1, 2, 3, 4]));
    expect(await audio.future, [1, 2, 3, 4]);
    await _until(() => revisions.length == 2);
    expect(revisions, ['one', 'one two']);
    expect(closes, 0);
    expect(await stream.finish(), 'One. Two.');
    expect(closes, 1);
    expect(revisions, ['one', 'one two', 'One. two', 'One. Two.']);
  });

  for (final stage in ['handshake', 'startup', 'recording', 'finishing']) {
    test('cancellation releases the $stage connection and ignores late text', () async {
      final connected = Completer<void>();
      final closing = Completer<void>();
      final revisions = <String>[];
      server.listen((request) async {
        if (stage == 'handshake') { connected.complete(); return; }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final event = jsonObject(jsonDecode(raw as String));
          if (event['type'] == 'session.start') {
            connected.complete();
            if (stage != 'startup') socket.add('{"type":"session.started"}');
          } else if (event['type'] == 'session.close') {
            closing.complete();
          }
        });
      });
      final stream = TranscriptionStream(onTranscript: revisions.add, onError: () => fail('Cancellation is not a failure'));
      final opening = stream.connect(auth, cancellation: cancellation, endpoint: endpoint);
      if (stage == 'handshake' || stage == 'startup') {
        final cancelled = expectLater(opening, throwsA(isA<CancelledException>()));
        await connected.future;
        cancellation.cancel();
        await cancelled;
      } else {
        await opening;
        if (stage == 'finishing') {
          final cancelled = expectLater(stream.finish(), throwsA(isA<CancelledException>()));
          await closing.future;
          cancellation.cancel();
          await cancelled;
        } else { cancellation.cancel(); }
      }
      for (final socket in sockets) {
        socket.add('{"type":"transcript.final","utterance_id":"late","revision":0,"text":"late"}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(revisions, isEmpty);
      expect(stream.acceptingAudio, isFalse);
    });
  }

  test('an unfinished segment cannot become a successful final transcript', () async {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final type = jsonObject(jsonDecode(raw as String))['type'];
        if (type == 'session.start') socket.add('{"type":"session.started"}');
        if (type == 'session.close') {
          socket.add('{"type":"transcript.segment","utterance_id":"a","revision":8,"text":"partial"}');
          socket.add('{"type":"session.updated","session":{"status":"closed"}}');
        }
      });
    });
    final stream = TranscriptionStream(onTranscript: (_) {}, onError: () {});
    await stream.connect(auth, cancellation: cancellation, endpoint: endpoint);
    await expectLater(stream.finish(), throwsStateError);
    expect(stream.acceptingAudio, isFalse);
  });

  test('redirects are refused without forwarding account credentials', () async {
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = 302;
      request.response.headers.set('location', 'http://127.0.0.1:${server.port}/redirected');
      await request.response.close();
    });
    final stream = TranscriptionStream(onTranscript: (_) {}, onError: () {});
    await expectLater(stream.connect(auth, cancellation: cancellation, endpoint: endpoint), throwsStateError);
    expect(requests, 1);
  });
}

Future<void> _until(bool Function() predicate) async {
  final clock = Stopwatch()..start();
  while (!predicate()) {
    if (clock.elapsed > const Duration(seconds: 3)) throw StateError('Expected stream event did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
