import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer backend;
  late HttpClient http;
  late Directory root;
  final uploads = <Uint8List>[];
  final headers = <Map<String, String?>>[];
  var status = 200;
  Json response = {'text': 'dictated text'};
  Completer<void>? arrived, release;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('happen-dictation-');
    await _auth(root, 'account');
    http = HttpClient();
    backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uploads.clear();
    headers.clear();
    status = 200;
    response = {'text': 'dictated text'};
    arrived = null;
    release = null;
    backend.listen((request) async {
      expect(request.uri.path, '/transcribe');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in request) { bytes.add(chunk); }
      uploads.add(bytes.takeBytes());
      headers.add({for (final name in ['authorization', 'chatgpt-account-id', 'content-type']) name: request.headers.value(name)});
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      if (arrived != null) {
        request.response.write('{');
        await request.response.flush();
        arrived!.complete();
        await release!.future;
      } else {
        request.response.write(jsonEncode(response));
      }
      try { await request.response.close(); } catch (_) { /* Cancelled request. */ }
    });
  });
  tearDown(() async {
    if (release != null && !release!.isCompleted) release!.complete();
    http.close(force: true);
    await backend.close(force: true);
    await root.delete(recursive: true);
  });

  test('desktop uploads directly, binds the local account and stays outside task history', () async {
    final server = await AgentServer.startEmbedded(directory: root.path,
      configPath: '${root.path}/config.yaml');
    final client = await AgentClient.connect(server.uri);
    addTearDown(() async { await client.close(); await server.close(); });
    final cancellation = CancellationToken();
    final authorization = await client.desktopAuthorization(cancellation: cancellation);
    final transcription = TranscriptionClient(http: http,
      endpoint: Uri.parse('http://127.0.0.1:${backend.port}/transcribe'), credentials: client.desktopAuthorization);
    final wav = _wav(2 * 1024 * 1024 + 200);
    final account = requiredString(authorization, 'account_id');
    expect(await transcription.transcribe(wav, accountId: account, cancellation: cancellation), 'dictated text');
    expect(uploads, hasLength(1));
    final body = uploads.single;
    final type = headers.single['content-type']!;
    final boundary = type.substring(type.indexOf('boundary=') + 9);
    final prefix = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="codex.wav"\r\nContent-Type: audio/wav\r\n\r\n');
    expect(body.sublist(0, prefix.length), prefix);
    expect(body.sublist(prefix.length, prefix.length + wav.length), wav);
    expect(utf8.decode(body.sublist(prefix.length + wav.length)), '\r\n--$boundary--\r\n');
    expect(headers.single['chatgpt-account-id'], 'account');
    expect(jsonObject(await client.request('telemetry'))['resident_tasks'], 0);

    status = 503;
    response = {'can_retry': false};
    await expectLater(transcription.transcribe(wav, accountId: account, cancellation: cancellation), throwsStateError);
    expect(uploads, hasLength(2), reason: 'can_retry:false forbids automatic retry');
    status = 200;
    response = {'text': 'recovered'};
    expect(await transcription.transcribe(wav, accountId: account, cancellation: cancellation), 'recovered');
    await _auth(root, 'another-account');
    await expectLater(transcription.transcribe(wav, accountId: account, cancellation: cancellation), throwsA(predicate((e) => e.toString().contains('workspace changed'))));
    expect(uploads, hasLength(3));
  });

  test('desktop credentials are unavailable over the TCP task API', () async {
    final server = await AgentServer.start(directory: root.path, port: 0, configPath: '${root.path}/config.yaml');
    final client = await AgentClient.connect(server.uri);
    addTearDown(() async { await client.close(); await server.close(); });
    await expectLater(client.desktopAuthorization(cancellation: CancellationToken()),
      throwsA(predicate((e) => e.toString().contains('requires a local Unix socket'))));
    expect(uploads, isEmpty);
  });

  test('cancelling during a response body aborts transcription and keeps the connection usable', () async {
    final server = await AgentServer.startEmbedded(directory: root.path,
      configPath: '${root.path}/config.yaml');
    final client = await AgentClient.connect(server.uri);
    addTearDown(() async { await client.close(); await server.close(); });
    final cancellation = CancellationToken();
    final transcription = TranscriptionClient(http: http,
      endpoint: Uri.parse('http://127.0.0.1:${backend.port}/transcribe'), credentials: client.desktopAuthorization);
    arrived = Completer<void>();
    release = Completer<void>();
    final pending = transcription.transcribe(_wav(16000), accountId: 'account', cancellation: cancellation);
    final cancelled = expectLater(pending, throwsA(isA<CancelledException>()));
    await arrived!.future;
    cancellation.cancel();
    await cancelled;
    expect(jsonObject(await client.request('ping'))['version'], '0.1.0');
  });

  test('401 refresh is separate from transcription retry and workspace refusals never refresh', () async {
    var refreshed = 0;
    final transcription = TranscriptionClient(http: http,
      endpoint: Uri.parse('http://127.0.0.1:${backend.port}/transcribe'),
      credentials: ({bool refresh = false, required CancellationToken cancellation}) async {
        if (refresh) { refreshed++; status = 200; response = {'text': 'refreshed'}; }
        return {'account_id': 'account', 'access_token': 'fixture'};
      });
    status = 401;
    response = {};
    expect(await transcription.transcribe(_wav(16000), accountId: 'account', cancellation: CancellationToken()), 'refreshed');
    expect(refreshed, 1);
    expect(uploads, hasLength(2));
    status = 401;
    response = {'error': {'code': 'workspace_ip_not_authorized'}};
    await expectLater(transcription.transcribe(_wav(16000), accountId: 'account', cancellation: CancellationToken()),
      throwsA(predicate((e) => e.toString().contains('IP address'))));
    expect(refreshed, 1);
    expect(uploads, hasLength(3));
  });

  test('transient HTTP failures retry at most twice; refusals and malformed successes do not retry', () async {
    final transcription = TranscriptionClient(http: http,
      endpoint: Uri.parse('http://127.0.0.1:${backend.port}/transcribe'),
      credentials: ({bool refresh = false, required CancellationToken cancellation}) async => {'account_id': 'account', 'access_token': 'fixture'});
    status = 503;
    response = {};
    await expectLater(transcription.transcribe(_wav(16000), accountId: 'account', cancellation: CancellationToken()), throwsStateError);
    expect(uploads, hasLength(3));
    status = 429;
    await expectLater(transcription.transcribe(_wav(16000), accountId: 'account', cancellation: CancellationToken()), throwsStateError);
    expect(uploads, hasLength(4));
    status = 200;
    await expectLater(transcription.transcribe(_wav(16000), accountId: 'account', cancellation: CancellationToken()), throwsStateError);
    expect(uploads, hasLength(5));
  });
}

Future<void> _auth(Directory directory, String account) => File('${directory.path}/auth.json').writeAsString(jsonEncode({
  'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': account,
  'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
}));

Uint8List _wav(int length) {
  final bytes = Uint8List(44 + length);
  final header = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  header.setUint32(4, length + 36, Endian.little);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  header.setUint32(40, length, Endian.little);
  return bytes;
}
