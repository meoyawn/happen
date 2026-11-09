import 'dart:async';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, work;
  late AgentServer server;
  late AgentClient client;
  late CancellationToken lifetime;
  Future<void> acknowledgements = Future<void>.value();
  setUp(() async {
    root = await Directory.systemTemp.createTemp('host-terminal-');
    work = await Directory('${root.path}/remote checkout λ').create();
    lifetime = CancellationToken();
    acknowledgements = Future<void>.value();
    server = await AgentServer.start(directory: '${root.path}/data', port: 0,
      configPath: '${root.path}/config.yaml', skillsHome: root.path, telemetry: false);
    client = await AgentClient.connect(server.uri, sharedFilesystem: false);
  });
  tearDown(() async {
    await acknowledgements;
    lifetime.cancel();
    await client.close(); await server.close(); await root.delete(recursive: true);
  });
  Future<Json> rpc(String method, String id, [Json params = const {}]) =>
    client.request('terminal/$method', {'terminalId': id, ...params}).then(jsonObject);
  void acknowledge(String id, int sequence) {
    acknowledgements = acknowledgements.then((_) async { await rpc('ack', id, {'sequence': sequence}); });
  }

  test('socket terminal runs in the host checkout, accepts input and resize, and drains output before exit', () async {
    final id = newId(), ready = Completer<void>(), exited = Completer<void>();
    final output = StringBuffer(), methods = <String>[];
    final subscription = client.events.stream.listen((event) {
      final params = event['params'];
      if (params is! Map || params['terminalId'] != id) return;
      methods.add(event['method'] as String);
      if (event['method'] == 'terminal/output') {
        output.write(params['data']);
        acknowledge(id, params['sequence'] as int);
        if (output.toString().contains('READY') && !ready.isCompleted) ready.complete();
      }
      if (event['method'] == 'terminal/exited') { expect(params['code'], 7); exited.complete(); }
    });
    addTearDown(subscription.cancel);
    final opened = await rpc('open', id, {'cwd': work.path, 'command': r'''
printf 'cwd=%s\n' "$PWD"
stty -echo
printf '\033[32mREADY\033[0m\n'
IFS= read -r answer
printf 'input=%s\n' "$answer"
stty size
exit 7
'''});
    expect(opened['pid'], isPositive);
    expect(opened['platform'], Platform.operatingSystem);
    await ready.future.timeout(const Duration(seconds: 10));
    await rpc('resize', id, {'columns': 101, 'rows': 33});
    await rpc('write', id, {'data': 'λ-input\n'});
    await exited.future.timeout(const Duration(seconds: 10));
    expect(output.toString(), contains('cwd=${await work.resolveSymbolicLinks()}'));
    expect(output.toString(), contains('\x1b[32mREADY\x1b[0m'));
    expect(output.toString(), contains('input=λ-input'));
    expect(output.toString(), contains('33 101'));
    expect(methods.last, 'terminal/exited');
    expect(methods, isNot(contains('terminal/error')));
    await rpc('close', id);
  });

  for (final disconnect in [false, true]) {
    test('${disconnect ? 'disconnect' : 'close'} releases the host shell and background jobs; another connection cannot control them', () async {
      final id = newId(), ready = Completer<void>();
      final other = await AgentClient.connect(server.uri, sharedFilesystem: false);
      addTearDown(other.close);
      final foreign = <Json>[];
      final foreignEvents = other.events.stream.listen(foreign.add);
      addTearDown(foreignEvents.cancel);
      final subscription = client.events.stream.listen((event) {
        if (event['method'] == 'terminal/output' && event['params']['terminalId'] == id &&
            (event['params']['data'] as String).contains('READY') && !ready.isCompleted) { ready.complete(); }
      });
      addTearDown(subscription.cancel);
      final opened = await rpc('open', id, {'cwd': work.path,
        'command': r'sleep 60 & echo $! > child.pid; printf "READY\n"; wait'});
      await ready.future.timeout(const Duration(seconds: 10));
      final child = int.parse((await File('${work.path}/child.pid').readAsString()).trim());
      for (final (method, params) in [
        ('write', <String, dynamic>{'data': 'exit\n'}),
        ('resize', <String, dynamic>{'columns': 100, 'rows': 30}),
        ('close', <String, dynamic>{}),
      ]) {
        await expectLater(other.request('terminal/$method', {'terminalId': id, ...params}),
          throwsA(predicate<Object>((error) => error.toString().contains('another connection'))));
      }
      expect(foreign.where((event) => (event['method'] as String? ?? '').startsWith('terminal/')), isEmpty);
      if (disconnect) { await client.close(); } else { await rpc('close', id); }
      final timeout = Stopwatch()..start();
      Future<bool> alive(int pid) async {
        final result = await Process.run('ps', ['-p', '$pid', '-o', 'stat=']);
        final state = (result.stdout as String).trim();
        return result.exitCode == 0 && state.isNotEmpty && !state.startsWith('Z');
      }
      while (await alive(opened['pid'] as int) || await alive(child)) {
        if (timeout.elapsed > const Duration(seconds: 10)) fail('Closing left a host terminal process running');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
  }

  test('slow output consumers apply backpressure and resume without losing bytes', () async {
    final id = newId(), paused = Completer<void>(), exited = Completer<void>();
    var length = 0, lastSequence = 0;
    var acknowledge = false;
    final subscription = client.events.stream.listen((event) {
      if (!(event['method'] as String? ?? '').startsWith('terminal/') || event['params']['terminalId'] != id) return;
      if (event['method'] == 'terminal/output') {
        length += (event['params']['data'] as String).length;
        lastSequence = event['params']['sequence'] as int;
        if (length >= 131072 && !paused.isCompleted) paused.complete();
        if (acknowledge) {
          acknowledgements = acknowledgements.then((_) async { await rpc('ack', id, {'sequence': lastSequence}); });
        }
      }
      if (event['method'] == 'terminal/exited') { expect(event['params']['code'], 0); exited.complete(); }
    });
    addTearDown(subscription.cancel);
    await rpc('open', id, {'cwd': work.path, 'command': r'head -c 1048576 /dev/zero | tr "\000" x'});
    await paused.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(length, lessThan(262144));
    expect(exited.isCompleted, false);
    acknowledge = true;
    await rpc('ack', id, {'sequence': lastSequence});
    await exited.future.timeout(const Duration(seconds: 10));
    expect(length, 1048576);
  });
}
