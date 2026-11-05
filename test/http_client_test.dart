import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late HttpClient http;
  setUp(() async {
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, SecurityContext()
      ..useCertificateChain('test/fixtures/tls/cert.pem.txt')
      ..usePrivateKey('test/fixtures/tls/key.pem.txt'));
    http = HttpClient(context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls/cert.pem.txt'));
  });
  tearDown(() async { http.close(force: true); await server.close(force: true); });

  test('native HTTP retains keep-alive and declared request lengths', () async {
    final ports = <int>[];
    server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      expect(request.contentLength, utf8.encode('hello ✓').length);
      expect(await utf8.decoder.bind(request).join(), 'hello ✓');
      request.response.write('READY');
      await request.response.close();
    });
    for (var i = 0; i < 3; i++) {
      final response = await httpRequest(http, 'POST', Uri.parse('https://localhost:${server.port}/'),
        cancellation: CancellationToken(), body: utf8.encode('hello ✓'));
      expect(await utf8.decoder.bind(response).join(), 'READY');
    }
    expect(ports.toSet(), hasLength(1));
  });

  test('cancelling a request awaiting headers preserves sibling responses and native reuse', () async {
    final waiting = Completer<void>(), release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    server.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/cancel') { waiting.complete(); return; }
      if (request.uri.path == '/hold') {
        request.response.write('START');
        await request.response.flush();
        await release.future;
        request.response.write('END');
      } else { request.response.write('READY'); }
      await request.response.close();
    });
    Future<HttpReply> send(String path, CancellationToken token) => httpRequest(http, 'GET',
      Uri.parse('https://localhost:${server.port}$path'), cancellation: token);
    final lifetime = CancellationToken();
    addTearDown(lifetime.cancel);
    final sibling = utf8.decoder.bind(await send('/hold', lifetime)).join();
    final cancellation = CancellationToken();
    final stopped = expectLater(send('/cancel', cancellation), throwsA(isA<CancelledException>()));
    await waiting.future.timeout(const Duration(seconds: 2));
    cancellation.cancel();
    await stopped.timeout(const Duration(seconds: 2));
    expect(await utf8.decoder.bind(await send('/ready', lifetime)).join(), 'READY');
    release.complete();
    expect(await sibling.timeout(const Duration(seconds: 2)), 'STARTEND');
  });
}
