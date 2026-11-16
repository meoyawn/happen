import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CancellationToken cancellation;
  late ToolRuntime runtime;
  final sessions = <int, int>{};
  final completions = <int, Completer<Json>>{};
  Completer<void>? finalizing, releaseCompletion;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('command-sessions-');
    cancellation = TimeoutCancellationToken(const Duration(seconds: 30));
    runtime = const OpenAIToolInterface().createRuntime(root.path, cancellation);
    sessions.clear();
    completions.clear();
    finalizing = null;
    releaseCompletion = null;
  });
  tearDown(() async {
    if (releaseCompletion case final release? when !release.isCompleted) release.complete();
    await runtime.close();
    cancellation.cancel();
    await root.delete(recursive: true);
  });

  Future<Json> call(String name, Json input, {CancellationToken? token}) async =>
    jsonObject(await runtime.call(name, input, cancellation: token ?? cancellation));

  Future<void> start(int index, {bool finishFromFile = false}) async {
    final completed = completions[index] = Completer<Json>();
    final result = jsonObject(await runtime.call('exec_command', {
      'cmd': 'echo \$\$ > process-$index.pid; '
        'read value${finishFromFile ? ' < finish' : ''}; '
        'printf "finished:$index:%s\\n" "\$value"; exit 7',
      'shell': '/bin/sh', 'login': false, 'yield_time_ms': 250,
    }, cancellation: cancellation, callId: '$index', onItem: (phase, item) async {
      if (phase != 'completed') return;
      if (index == 1 && releaseCompletion != null) {
        finalizing!.complete();
        await releaseCompletion!.future.asCancellable(cancellation);
      }
      completed.complete(item);
    }));
    expect(result['exit_code'], isNull);
    sessions[index] = result['session_id'] as int;
  }

  Future<void> fill({int? exitIndex}) async {
    if (exitIndex != null) {
      expect((await call('exec_command', {
        'cmd': 'mkfifo finish', 'shell': '/bin/sh', 'login': false,
      }))['exit_code'], 0);
    }
    // Establish the oldest two independently of native spawn completion order.
    await start(0, finishFromFile: exitIndex == 0);
    await start(1, finishFromFile: exitIndex == 1);
    await Future.wait([for (var index = 2; index < 56; index++) start(index, finishFromFile: exitIndex == index)]);
    await Future.wait([for (var index = 56; index < 64; index++) start(index, finishFromFile: exitIndex == index)]);
  }

  Future<Json> poll(int index, {CancellationToken? token, int wait = 1}) =>
    call('write_stdin', {'session_id': sessions[index], 'yield_time_ms': wait}, token: token);

  Future<Json> exec(String source) => runtime.execute(
    ToolCall(id: newId(), namespace: 'functions', name: 'exec', format: 'text', input: source),
    ToolExecution(call: runtime.call, catalog: (_) async => const OpenAIToolInterface().hostCatalog,
      values: const {}, cancellation: cancellation));

  for (final scenario in [
    (name: 'prefers exited processes outside recently used', exitIndex: 1, touchOldest: false, evicted: 1),
    (name: 'falls back to LRU when no processes have exited', exitIndex: null, touchOldest: true, evicted: 1),
    (name: 'protects recent processes even if exited', exitIndex: 63, touchOldest: false, evicted: 0),
  ]) {
    test('Codex session pruning ${scenario.name}', () async {
      await fill(exitIndex: scenario.exitIndex);
      if (scenario.exitIndex case final index?) {
        await File('${root.path}/finish').writeAsString('released\n');
        expect((await completions[index]!.future.asCancellable(cancellation))['exit_code'], 7);
      }
      if (scenario.touchOldest) expect((await poll(0))['session_id'], sessions[0]);

      final result = await exec('text(await tools.exec_command({cmd:"read value",shell:"/bin/sh",login:false,yield_time_ms:250}));'
        '${scenario.touchOldest ? 'text(await tools.exec_command({cmd:"printf second",shell:"/bin/sh",login:false})); '
          'text(await tools.exec_command({cmd:"printf third",shell:"/bin/sh",login:false}));' : ''}');
      expect(result['error'], isNull, reason: 'Session pressure must not abort an awaited JavaScript tool sequence');
      final receipts = (result['output'] as List).cast<String>().map(jsonDecode).map(jsonObject).toList();
      expect(receipts.first['session_id'], isA<int>());
      if (scenario.touchOldest) {
        expect(receipts.skip(1).map((receipt) => receipt['output']), ['second', 'third']);
        expect(receipts.skip(1).map((receipt) => receipt['exit_code']), [0, 0]);
      }
      await expectLater(poll(scenario.evicted), throwsA(isA<StateError>().having(
        (error) => error.message, 'message', 'Unknown command session: ${sessions[scenario.evicted]}')));
      final victim = await completions[scenario.evicted]!.future.asCancellable(cancellation);
      expect(victim['exit_code'], isNotNull, reason: 'Eviction must terminate a live process');
      final pid = (await File('${root.path}/process-${scenario.evicted}.pid').readAsString()).trim();
      final status = await Process.run('ps', ['-p', pid, '-o', 'stat=']);
      expect(status.stdout.toString().trim(), anyOf(isEmpty, startsWith('Z')));
      expect((await poll(scenario.evicted == 0 ? 1 : 0))['session_id'], isA<int>());
      if (scenario.exitIndex == 63) {
        final recent = await poll(63);
        expect(recent['exit_code'], 7);
        expect(recent['output'], 'finished:63:released\n');
      }
    }, skip: Platform.isWindows ? 'Requires POSIX shells and FIFOs' : false);
  }

  test('Codex session pruning leaves live processes while an exited process finalizes', () async {
    finalizing = Completer<void>();
    releaseCompletion = Completer<void>();
    await fill(exitIndex: 1);
    await File('${root.path}/finish').writeAsString('released\n');
    await finalizing!.future.asCancellable(cancellation);

    await start(64);
    expect((await poll(0))['session_id'], sessions[0],
      reason: 'A blocked completion may temporarily exceed the soft cap');
    expect(completions[0]!.isCompleted, isFalse);
    releaseCompletion!.complete();
    await completions[1]!.future.asCancellable(cancellation);
    await start(65);
    await expectLater(poll(1), throwsStateError);
    expect((await poll(0))['session_id'], sessions[0]);
  }, skip: Platform.isWindows ? 'Requires POSIX shells and FIFOs' : false);

  test('Codex session pruning skips an active poll even after it becomes least recently used', () async {
    await fill();
    final observation = CancellationToken();
    final pending = poll(0, token: cancellation.merge(observation), wait: 30000);
    final cancelled = expectLater(pending, throwsA(isA<CancelledException>()));
    try {
      await Future.wait([for (var index = 1; index < 64; index++) poll(index)]);
      await start(64);
      expect(completions[0]!.isCompleted, isFalse);
      await expectLater(poll(1), throwsStateError);
    } finally {
      observation.cancel();
      await cancelled;
    }
    expect((await poll(0))['session_id'], sessions[0]);
  }, skip: Platform.isWindows ? 'Requires POSIX shells' : false);
}
