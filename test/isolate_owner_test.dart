import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('completed worker replies can be collected while the worker stays alive', () async {
    final cancellation = TimeoutCancellationToken(const Duration(seconds: 20));
    final owner = await IsolateOwner.start(_worker, {}, cancellation: cancellation);
    try {
      final replies = <WeakReference<List<int>>>[];
      for (var i = 0; i < 32; i++) {
        replies.add(await _reply(owner, cancellation));
      }
      await _collectGarbage(cancellation);
      expect(replies.where((reply) => reply.target != null), isEmpty,
        reason: 'Completed calls must release their reply payloads before worker exit.');
      expect(await callIsolate(owner.port, 'ping', {}, cancellation: cancellation), 'alive');
    } finally {
      cancellation.cancel();
      await owner.close();
    }
  });
}

Future<WeakReference<List<int>>> _reply(IsolateOwner owner, CancellationToken cancellation) async {
  final value = await callIsolate(owner.port, 'read', {}, cancellation: cancellation) as List<int>;
  return WeakReference(value);
}

Future<void> _collectGarbage(CancellationToken cancellation) async {
  final previous = await Service.getInfo();
  final service = previous.serverUri == null
    ? await Service.controlWebServer(enable: true, silenceOutput: true) : previous;
  final http = HttpClient();
  try {
    final uri = service.serverUri!.resolve('getAllocationProfile').replace(queryParameters: {
      'isolateId': Service.getIsolateId(Isolate.current)!, 'gc': 'true',
    });
    final request = await http.getUrl(uri).asCancellable(cancellation);
    final response = await request.close().asCancellable(cancellation);
    final result = jsonObject(jsonDecode(await utf8.decoder.bind(response).join().asCancellable(cancellation)));
    if (result['error'] != null) throw StateError('Garbage collection failed: ${result['error']}');
  } finally {
    http.close(force: true);
    if (previous.serverUri == null) await Service.controlWebServer(enable: false, silenceOutput: true);
  }
}

Future<void> _worker(List<Object?> arguments) async {
  final inbox = ReceivePort();
  (arguments[0] as SendPort).send(inbox.sendPort);
  await for (final raw in inbox) {
    final request = jsonObject(raw);
    final method = request['method'];
    (request['reply'] as SendPort?)?.send({'result': method == 'read' ? List<int>.filled(8192, 42) : 'alive'});
    if (method == 'close') {
      inbox.close();
      break;
    }
  }
}
