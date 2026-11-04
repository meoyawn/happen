import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';
import 'support/thread.dart';

void main() {
  late Directory root, sources;
  late HttpServer provider;
  late AgentServer server;
  late AgentClient client;
  final requests = <Json>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('happen-upload-server-');
    sources = await Directory.systemTemp.createTemp('happen-upload-client-');
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture',
      'account_id': 'fixture', 'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests.clear();
    provider.listen((request) async {
      requests.add(jsonObject(jsonDecode(await utf8.decoder.bind(request).join())));
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
        'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
          'content': [{'type': 'output_text', 'text': 'Received'}]}],
      }})}\n\n');
      await request.response.close();
    });
    server = await AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml',
      port: 0, endpoint: 'http://127.0.0.1:${provider.port}/responses');
    client = await AgentClient.connect(server.uri);
  });
  tearDown(() async {
    await client.close();
    await server.close();
    await provider.close(force: true);
    await root.delete(recursive: true);
    await sources.delete(recursive: true);
  });

  Future<String> send(List<Json> attachments) async {
    final id = await createThread(client, {'cwd': root.path});
    final result = await runTurn(client, id, settings: {'input': attachments});
    expect(result['status'], 'completed', reason: result.toString());
    return id;
  }

  Future<List<FileSystemEntity>> staged() async {
    final directories = [Directory('${root.path}/staging')], files = <File>[];
    while (directories.isNotEmpty) {
      try {
        await for (final entry in directories.removeLast().list(followLinks: false)) {
          if (entry is Directory) directories.add(entry);
          if (entry is File) files.add(entry);
        }
      } on PathNotFoundException { /* Disconnect cleanup may remove a queued directory. */ }
    }
    return files;
  }

  test('remote originals larger than a WebSocket frame upload in large blocks and retain file contents', () async {
    // A real uncompressed 4096-square BMP is 64 MiB + 54 bytes. The server has
    // no reason to read this client path: only the upload identifier is sent.
    final image = await _bitmap('${sources.path}/large screenshot.bmp', 4096, 4096);
    final progress = <int>[];
    final uploaded = await client.uploadAttachment(image.path, name: 'large screenshot.bmp', type: 'image',
      cancellation: CancellationToken(), onProgress: (sent, total) {
        expect(total, 64 * 1024 * 1024 + 54);
        progress.add(sent);
      });
    expect(progress, [24 * 1024 * 1024, 48 * 1024 * 1024, 64 * 1024 * 1024 + 54]);
    final report = await File('${sources.path}/report.txt').writeAsString('Remote file contents ✓\n');
    final file = await client.uploadAttachment(report.path, name: 'report.txt', type: 'file', cancellation: CancellationToken());
    // Remove the client sources before task admission to prove portability.
    await sources.delete(recursive: true);
    await sources.create();
    final id = await send([uploaded, file]);
    final content = (requests.single['input'] as List).lastWhere((item) => item['role'] == 'user')['content'] as List;
    final imagePart = content.firstWhere((part) => part['type'] == 'input_image');
    expect(imagePart['detail'], 'high');
    final bytes = Uri.parse(imagePart['image_url'] as String).data!.contentAsBytes();
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final header = ByteData.sublistView(Uint8List.fromList(bytes));
    // Codex's 2,500 patches reduce a square to 1600 x 1600.
    expect((header.getUint32(16), header.getUint32(20)), (1600, 1600));
    final fileText = content.firstWhere((part) => part['type'] == 'input_text')['text'] as String;
    final path = jsonDecode(fileText.split('\n').firstWhere((line) => line.startsWith('Path: ')).substring(6)) as String;
    expect(path, isNot(startsWith(sources.path)));
    expect(await File(path).readAsString(), 'Remote file contents ✓\n');
    expect(await staged(), isEmpty);
    final history = jsonObject(await client.request('thread/items/list', {'threadId': id}));
    expect((history['data'] as List).singleWhere((entry) => entry['item']['type'] == 'userMessage')['item']['content'], hasLength(2));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('upload limits, offsets, connection ownership and cancellation release original data', () async {
    final id = newId();
    await client.request('attachments.begin', {'upload_id': id, 'name': 'image.png', 'type': 'image', 'size': 1024 * 1024 * 1024});
    await client.discardAttachment(id);
    await expectLater(client.request('attachments.begin', {
      'upload_id': newId(), 'name': 'image.png', 'type': 'image', 'size': 1024 * 1024 * 1024 + 1,
    }), throwsStateError);
    final bytes = base64Decode(_png);
    await client.request('attachments.begin', {'upload_id': id, 'name': 'image.png', 'type': 'image', 'size': bytes.length});
    await expectLater(client.request('attachments.append', {'upload_id': id, 'offset': 1, 'data': _png}), throwsStateError);
    await expectLater(client.request('attachments.finish', {'upload_id': id}), throwsStateError);
    await client.request('attachments.append', {'upload_id': id, 'offset': 0, 'data': _png});
    final part = jsonObject(await client.request('attachments.finish', {'upload_id': id}));
    final other = await AgentClient.connect(server.uri);
    try {
      final id = await createThread(other, {'cwd': root.path});
      await expectLater(other.request('turn/start', {'threadId': id, 'input': [part]}), throwsStateError);
    } finally { await other.close(); }
    await send([part]);
    expect(await staged(), isEmpty);

    final image = await _bitmap('${sources.path}/cancelled.bmp', 4096, 4096);
    final cancellation = CancellationToken();
    final progress = <int>[];
    await expectLater(client.uploadAttachment(image.path, name: 'cancelled.bmp', type: 'image', cancellation: cancellation,
      onProgress: (sent, _) { progress.add(sent); cancellation.cancel(); }), throwsA(isA<CancelledException>()));
    expect(progress, [24 * 1024 * 1024]);
    expect(await staged(), isEmpty);
    expect(jsonObject(await client.request('ping'))['version'], '0.1.0');
    await client.request('attachments.begin', {'upload_id': newId(), 'name': 'unfinished.png', 'type': 'image', 'size': 100});
    await client.close();
    for (var i = 0; i < 100 && (await staged()).isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await staged(), isEmpty);
    client = await AgentClient.connect(server.uri);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('local image paths apply original detail limits and invalid sources fail before admission', () async {
    final image = await _bitmap('${sources.path}/original.bmp', 4096, 4096);
    await send([{'type': 'image', 'name': 'original.bmp', 'path': image.path, 'detail': 'original'}]);
    final content = (requests.single['input'] as List).lastWhere((item) => item['role'] == 'user')['content'] as List;
    final part = content.single;
    expect(part['detail'], 'original');
    final data = ByteData.sublistView(Uint8List.fromList(Uri.parse(part['image_url'] as String).data!.contentAsBytes()));
    expect((data.getUint32(16), data.getUint32(20)), (3200, 3200));
    final corrupt = await File('${sources.path}/corrupt.png').writeAsString('not an image');
    final id = await createThread(client, {'cwd': root.path});
    await expectLater(client.request('turn/start', {'threadId': id, 'input': [
      {'type': 'image', 'name': 'corrupt.png', 'path': corrupt.path},
    ]}), throwsStateError);
    expect(requests, hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

Future<File> _bitmap(String path, int width, int height) async {
  final size = 54 + width * height * 4;
  final header = ByteData(54)..setUint8(0, 0x42)..setUint8(1, 0x4d)
    ..setUint32(2, size, Endian.little)..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)..setUint32(18, width, Endian.little)
    ..setUint32(22, height, Endian.little)..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little)..setUint32(34, width * height * 4, Endian.little);
  final file = File(path), output = await File(path).open(mode: FileMode.write);
  try {
    await output.writeFrom(header.buffer.asUint8List());
    await output.truncate(size);
  } finally { await output.close(); }
  return file;
}
