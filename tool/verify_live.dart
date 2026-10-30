import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

const prompt =
    '''Create summarize.py using Python's standard library. Its two positional
arguments are an input CSV path and an output text path. Read UTF-8 CSV with columns
product,quantity,unit_price,status. Sum quantity * unit_price only for rows whose
status is paid, using exact decimal arithmetic. Write a fixed two-decimal total
followed by one newline. Handle an input with only a header by writing 0.00.
Run it on orders.csv to create total.txt and verify your result. Do not use network,
skills, plugins, or delegated agents.''';
const fixture =
    'product,quantity,unit_price,status\nяблоко,2,1.25,paid\norange,3,2.00,paid\nbanana,1,10.00,cancelled\n';

Future<void> main(List<String> args) async {
  final root = await Directory.systemTemp.createTemp('happen-live-');
  final report = <String, dynamic>{
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'os': Platform.operatingSystem,
    'model': 'gpt-6.1-sol',
    'reasoning': 'low',
    'task': prompt,
    'results': <Json>[],
  };
  final cancellation = TimeoutCancellationToken(const Duration(minutes: 10));
  final signal = ProcessSignal.sigint.watch().listen(
    (_) => cancellation.cancel(),
  );
  try {
    for (final transport in ['http', 'websocket']) {
      cancellation.throwIfCancelled();
      final work = await Directory('${root.path}/happen-$transport/work')
          .create(recursive: true);
      final data = await Directory('${root.path}/happen-$transport/data')
          .create();
      await File('${work.path}/orders.csv').writeAsString(fixture);
      final auth = AuthManager(data.path);
      try {
        await auth.useCodex(args.isEmpty ? null : args.single);
        await auth.credentials();
      } finally {
        auth.close();
      }
      final server = await AgentServer.startEmbedded(
        directory: data.path,
        configPath: '${data.path}/config.yaml',
      );
      final client = await AgentClient.connect(
        server.uri,
        cancellation: cancellation,
      );
      final watch = Stopwatch()..start();
      final result = <String, dynamic>{
        'harness': 'happen',
        'model_transport': transport,
        'client_transport': 'uds',
      };
      try {
        final completion = client.events.stream.firstWhere(
          (v) => [
            'turn.completed',
            'turn.failed',
            'turn.cancelled',
          ].contains(v['type']),
        );
        final started = jsonObject(
          await client.request('task.start', {
            'cwd': work.path,
            'prompt': prompt,
            'model': 'gpt-6.1-sol',
            'reasoning': 'low',
            'settings': {'transport': transport},
          }),
        );
        final terminal = await completion.asCancellable(
          cancellation,
          onCancel: () {
            unawaited(
              client
                  .request('task.cancel', {'task_id': started['task_id']})
                  .catchError((Object _) => null),
            );
          },
        );
        result['status'] = terminal['type'];
        result['elapsed_ms'] = watch.elapsedMilliseconds;
        result['telemetry'] = terminal['data']['telemetry'];
        if (terminal['data']['error'] != null) {
          result['error'] = terminal['data']['error'];
        }
        result['artifacts'] = await verify(work, cancellation);
      } finally {
        await client.close();
        await server.close();
      }
      (report['results'] as List).add(result);
    }
    cancellation.throwIfCancelled();
    final work = await Directory('${root.path}/codex/work')
        .create(recursive: true);
    await File('${work.path}/orders.csv').writeAsString(fixture);
    final command = [
      'exec',
      '--ignore-user-config',
      '--ignore-rules',
      '--skip-git-repo-check',
      '--ephemeral',
      '--disable',
      'plugins',
      '-c',
      'skills.bundled.enabled=false',
      '-c',
      'skills.include_instructions=false',
      '-c',
      'cloud.skills.enabled=false',
      '-c',
      'orchestrator.mcp.enabled=false',
      '-c',
      'model_reasoning_effort="low"',
      '--sandbox',
      'danger-full-access',
      '-m',
      'gpt-6.1-sol',
      '--json',
      '-C',
      work.path,
      prompt,
    ];
    final watch = Stopwatch()..start();
    final process = await Process.start('codex', command);
    await process.stdin.close();
    final hook = CancellationHook(
      cancellation,
      () => process.kill(ProcessSignal.sigterm),
    );
    Json? usage;
    var toolFailures = 0;
    final stderr = process.stderr.listen((_) {});
    final output = boundedLines(process.stdout, maxBytes: 4 * 1024 * 1024)
        .listen((line) {
          try {
            final event = jsonObject(jsonDecode(line));
            if (event['type'] == 'turn.completed') {
              usage = jsonObject(event['usage'] ?? {});
            }
            if (event['type'] == 'item.completed' &&
                event['item']?['exit_code'] is int &&
                event['item']['exit_code'] != 0) {
              toolFailures++;
            }
          } on FormatException {
            /* CLI notices are not evidence of model behavior. */
          }
        });
    final drained = output.asFuture<void>();
    try {
      final status = await process.exitCode.asCancellable(cancellation);
      await drained.asCancellable(cancellation);
      (report['results'] as List).add({
        'harness': 'codex',
        'exit_code': status,
        'elapsed_ms': watch.elapsedMilliseconds,
        'usage': usage,
        'tool_failures': toolFailures,
        'artifacts': await verify(work, cancellation),
        'isolation_options': command.take(command.length - 3).toList(),
      });
    } finally {
      hook.dispose();
      await output.cancel();
      await stderr.cancel();
    }
  } catch (error) {
    report['error'] = error.toString();
  } finally {
    cancellation.cancel();
    await signal.cancel();
    await root.delete(recursive: true);
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  if ((report['results'] as List).length != 3 ||
      (report['results'] as List).any(
        (value) => value['artifacts']?['passed'] != true,
      )) {
    exitCode = 1;
  }
}

Future<Json> verify(Directory work, CancellationToken cancellation) async {
  final script = File('${work.path}/summarize.py'),
      total = File('${work.path}/total.txt');
  if (!await script.exists() || !await total.exists()) {
    return {'passed': false, 'missing_artifact': true};
  }
  final initial = await total.readAsString() == '8.50\n';
  final checks = <bool>[];
  for (final fixture in [
    ('product,quantity,unit_price,status\n', '0.00\n'),
    (
      'product,quantity,unit_price,status\nx,3,0.10,paid\ny,99,10.00,cancelled\n',
      '0.30\n',
    ),
  ]) {
    cancellation.throwIfCancelled();
    final input = File('${work.path}/check.csv'),
        output = File('${work.path}/check.txt');
    await input.writeAsString(fixture.$1);
    final process = await Process.start('python3', [
      script.path,
      input.path,
      output.path,
    ], workingDirectory: work.path);
    final hook = CancellationHook(cancellation, () => process.kill());
    final stdout = process.stdout.drain<void>(),
        stderr = process.stderr.drain<void>();
    try {
      final code = await process.exitCode.asCancellable(cancellation);
      await Future.wait([stdout, stderr]);
      checks.add(
        code == 0 &&
            await output.exists() &&
            await output.readAsString() == fixture.$2,
      );
    } finally {
      hook.dispose();
    }
  }
  return {
    'passed': initial && checks.every((value) => value),
    'initial_total': initial,
    'header_only': checks[0],
    'decimal_and_status': checks[1],
  };
}
