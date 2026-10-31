import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';
import 'package:code_mode/src/quickjs.dart';
import 'package:storage/storage.dart';

Future<void> main(List<String> args) async {
  final root = await Directory.systemTemp.createTemp('agent-bench-');
  final report = <String, dynamic>{
    'dart': Platform.version,
    'os': Platform.operatingSystem,
    'cpus': Platform.numberOfProcessors,
    'mode': const bool.fromEnvironment('dart.vm.product') ? 'aot' : 'jit',
  };
  final baseline = ProcessInfo.currentRss;
  final delays = <int>[];
  var tick = DateTime.now().microsecondsSinceEpoch;
  final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
    final now = DateTime.now().microsecondsSinceEpoch;
    delays.add(now - tick);
    tick = now;
  });
  try {
    // The fresh and retained-runtime cases perform the same bootstrap and work.
    for (final reuse in [false, true]) {
      final retained = reuse ? QuickJs() : null;
      final elapsed = <int>[];
      for (var i = 0; i < 1000; i++) {
        final watch = Stopwatch()..start();
        final js = retained ?? QuickJs();
        if (reuse) js.resetContext();
        final result = await js.run(
          'text([1,2,3,4].map(x => x*x).reduce((a,b) => a+b, 0));',
          tool: (_, _, {required cancellation}) async => null,
          cancellation: CancellationToken(),
        );
        if ((result['output'] as List).single != '30') {
          throw StateError('Wrong JS result');
        }
        if (!reuse) js.close();
        elapsed.add(watch.elapsedMicroseconds);
      }
      retained?.close();
      report[reuse
          ? 'retained_runtime_fresh_context_us'
          : 'fresh_runtime_context_us'] = distribution(
        elapsed,
      );
    }

    delays.clear();
    tick = DateTime.now().microsecondsSinceEpoch;
    final ready = Stopwatch()..start();
    final agents = await Future.wait(
      List.generate(
        100,
        (i) => IsolateOwner.start(_benchmarkAgent, {
          'directory': root.path,
          'task_id': newId(),
          'slow': i == 0,
        }),
      ),
    );
    report['start_100_agents_and_100_writers_ms'] = ready.elapsedMilliseconds;
    report['rss_200_isolates_bytes'] = ProcessInfo.currentRss - baseline;
    final before = await Process.run('ps', ['-M', '-p', pid.toString()]);
    report['os_threads_before_work'] =
        const LineSplitter().convert(before.stdout.toString()).length - 1;
    final watch = Stopwatch()..start();
    final slowWriter = await IsolateOwner.start(_slowWriter, {
      'directory': root.path,
      'task_id': newId(),
    });
    var slowWriterFinished = false;
    var ordinaryFinishedWhileSqlBlocked = 0;
    final slowSql = callIsolate(slowWriter.port, 'run', {}).then((value) {
      slowWriterFinished = true;
      return value;
    });
    final work = agents
        .map(
          (agent) => callIsolate(agent.port, 'run', {}).then((value) {
            if (!slowWriterFinished) ordinaryFinishedWhileSqlBlocked++;
            return value;
          }),
        )
        .toList();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final during = await Process.run('ps', ['-M', '-p', pid.toString()]);
    report['os_threads_during_work'] =
        const LineSplitter().convert(during.stdout.toString()).length - 1;
    final results = (await Future.wait(work)).map(jsonObject).toList();
    report['100_agents_20_cells_each_ms'] = watch.elapsedMilliseconds;
    report['ordinary_agent_ms'] = distribution(
      results.skip(1).map((r) => r['elapsed_ms'] as int).toList(),
    );
    report['slow_agent_ms'] = results.first['elapsed_ms'];
    report['rss_peak_bytes'] = ProcessInfo.maxRss;
    report['observed_js_os_threads'] = results
        .expand((r) => r['threads'] as List)
        .toSet()
        .length;
    report['slow_sql'] = await slowSql;
    report['agents_finished_while_sql_blocked'] =
        ordinaryFinishedWhileSqlBlocked;
    await slowWriter.close();
    report['heartbeat_intervals_us'] = distribution(delays);
    delays.clear();
    final sustained = Stopwatch()..start();
    final latencies = <int>[], scheduleLag = <int>[];
    final scheduled = <Future<void>>[];
    var active = 0, maximumActive = 0;
    const cells = 1000, intervalUs = 10000;
    for (var i = 0; i < cells; i++) {
      final remaining = i * intervalUs - sustained.elapsedMicroseconds;
      if (remaining > 0) {
        await Future<void>.delayed(Duration(microseconds: remaining));
      }
      scheduleLag.add(sustained.elapsedMicroseconds - i * intervalUs);
      final started = Stopwatch()..start();
      active++;
      if (active > maximumActive) maximumActive = active;
      scheduled.add(
        callIsolate(agents[i % agents.length].port, 'run', {
          'cells': 1,
          'delay_ms': 0,
        }).then((_) {
          active--;
          latencies.add(started.elapsedMicroseconds);
        }),
      );
    }
    await Future.wait(scheduled);
    report['sustained'] = {
      'target_cells_per_second': 100,
      'completed_cells': cells,
      'elapsed_ms': sustained.elapsedMilliseconds,
      'completed_cells_per_second':
          cells * 1000000 / sustained.elapsedMicroseconds,
      'maximum_in_flight': maximumActive,
      'latency_us': distribution(latencies),
      'schedule_lag_us': distribution(scheduleLag),
      'heartbeat_intervals_us': distribution(delays),
    };
    await Future.wait(agents.map((agent) => agent.close()));
    report['rss_after_cleanup_bytes'] = ProcessInfo.currentRss;
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } finally {
    heartbeat.cancel();
    await root.delete(recursive: true);
  }
}

void _slowWriter(List<Object?> args) async {
  final config = jsonObject(args[1]);
  final store = TaskStore(
    config['directory'] as String,
    config['task_id'] as String,
  );
  final port = ReceivePort();
  (args[0] as SendPort).send(port.sendPort);
  await for (final raw in port) {
    final request = jsonObject(raw),
        reply = jsonObject(raw)['reply'] as SendPort;
    if (request['method'] == 'close') {
      store.close();
      reply.send({'result': null});
      port.close();
      break;
    }
    final watch = Stopwatch()..start();
    final thread = nativeThreadId();
    // A single long sqlite3_step writes one row; no synthetic file lock or sleep.
    store.db.execute("""
      INSERT INTO events(type, created_at, data)
      WITH RECURSIVE counter(n) AS (
        VALUES(1) UNION ALL SELECT n+1 FROM counter WHERE n < 20000000
      )
      SELECT 'bench.slow', '2026-10-29T00:00:00Z', json_object('sum', sum(n)) FROM counter
    """);
    reply.send({
      'result': {'elapsed_ms': watch.elapsedMilliseconds, 'thread_id': thread},
    });
  }
}

Json distribution(List<int> values) {
  values.sort();
  return {
    'count': values.length,
    'p50': values[values.length ~/ 2],
    'p95': values[(values.length * .95).floor().clamp(0, values.length - 1)],
    'p99': values[(values.length * .99).floor().clamp(0, values.length - 1)],
    'max': values.last,
    'sum': values.fold(0, (int a, b) => a + b),
  };
}

void _benchmarkAgent(List<Object?> args) async {
  final config = jsonObject(args[1]);
  final writer = await startStore(
    config['directory'] as String,
    config['task_id'] as String,
  );
  final port = ReceivePort();
  (args[0] as SendPort).send(port.sendPort);
  await for (final raw in port) {
    final request = jsonObject(raw),
        reply = jsonObject(raw)['reply'] as SendPort;
    if (request['method'] == 'close') {
      await writer.close();
      reply.send({'result': null});
      port.close();
      break;
    }
    try {
      final watch = Stopwatch()..start();
      final threads = <int>{};
      final params = jsonObject(request['params']);
      for (var i = 0; i < (params['cells'] as int? ?? 20); i++) {
        final js = QuickJs();
        try {
          threads.add(nativeThreadId());
          final output = await js.run(
            'const r = await tools.wait({}); text(r);',
            cancellation: CancellationToken(),
            tool: (_, _, {required cancellation}) async {
              await Future<void>.delayed(
                Duration(
                  milliseconds:
                      params['delay_ms'] as int? ??
                      (config['slow'] == true ? 100 : 10),
                ),
              );
              return 42;
            },
          );
          await callIsolate(writer.port, 'append', {
            'type': 'bench.cell',
            'data': output,
          });
        } finally {
          js.close();
        }
      }
      reply.send({
        'result': {
          'elapsed_ms': watch.elapsedMilliseconds,
          'threads': threads.toList(),
        },
      });
    } catch (error) {
      reply.send({'error': error.toString()});
    }
  }
}
