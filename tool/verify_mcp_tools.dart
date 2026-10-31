import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

/// Live append-only tool updates through both GPT transports. Credentials are
/// referenced privately; output contains checks and measurements only.
Future<void> main(List<String> args) async {
  final root = await Directory.systemTemp.createTemp('happen-tools-live-');
  final cancellation = TimeoutCancellationToken(const Duration(minutes: 5));
  final signal = ProcessSignal.sigint.watch().listen((_) => cancellation.cancel());
  final report = <String, dynamic>{
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'os': Platform.operatingSystem,
    'model': 'gpt-6.1-sol',
    'reasoning': 'low',
    'results': <Json>[],
  };
  try {
    for (final transport in ['http', 'websocket']) {
      cancellation.throwIfCancelled();
      final data = await Directory('${root.path}/$transport').create();
      final config = File('${data.path}/config.yaml');
      final auth = AuthManager(data.path);
      try {
        await auth.useCodex(args.isEmpty ? null : args.single);
        await auth.credentials();
      } finally {
        auth.close();
      }
      final server = await AgentServer.startEmbedded(
        directory: data.path, configPath: config.path,
      );
      final client = await AgentClient.connect(server.uri, cancellation: cancellation);
      final watch = Stopwatch()..start();
      final result = <String, dynamic>{'model_transport': transport};
      (report['results'] as List).add(result);
      Future<Json> turn(String method, Json params) async {
        cancellation.throwIfCancelled();
        final done = client.events.stream.firstWhere((event) =>
          ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']),
        );
        await client.request(method, params).asCancellable(cancellation);
        final terminal = await done.asCancellable(cancellation);
        if (terminal['type'] != 'turn.completed') {
          throw StateError('Live tool verification did not complete: ${terminal['data']['error']}');
        }
        return terminal;
      }
      try {
        final first = await turn('task.start', {
          'cwd': data.path,
          'model': report['model'],
          'reasoning': report['reasoning'],
          'settings': {'transport': transport},
          'max_steps': 6,
          'prompt': 'Reply READY only. Do not use tools.',
        });
        final task = first['task_id'];
        await config.writeAsString(jsonEncode({
          'mcp_servers': {
            'dart': {
              'command': Platform.resolvedExecutable,
              'args': ['mcp-server', '--disable', 'analysis'],
            },
            'live_probe': {
              'command': Platform.resolvedExecutable,
              'args': [File('test/fixtures/mcp_stdio.dart').absolute.path],
              'legacy_fallback': false,
            },
          },
        }), flush: true);
        final continued = await turn('task.send', {
          'task_id': task,
          'prompt': 'Call mcp__live_probe.probe directly with {"action":"inspect"}. '
              'Do not use functions.exec or shell commands. Reply with the returned PID only.',
        });
        final history = (await client.request('history.page', {'task_id': task, 'limit': 500}) as List)
            .map(jsonObject).toList();
        final catalog = history.lastWhere((event) => event['type'] == 'mcp.updated')['data']['snapshot']['tools'] as List;
        final statuses = await client.request('mcp.status', {}) as List;
        final pid = statuses.singleWhere((server) => server['name'] == 'live_probe')['pid'];
        final checks = <String, bool>{
          'dart_mcp_ready': statuses.any((server) => server['name'] == 'dart' && server['state'] == 'ready'),
          'dart_tools_loaded': catalog.any((tool) => tool['namespace'] == 'mcp__dart'),
          'declarations_persisted': history.any((event) => event['type'] == 'mcp.updated' && event['data']['item']['kind'] == 'tools'),
          'direct_call_executed': history.any((event) => event['type'] == 'tool.started' && event['data']['namespace'] == 'mcp__live_probe' && event['data']['name'] == 'probe'),
          'answer_matches_process': (continued['data']['text'] as String).contains('$pid'),
        };
        result.addAll({
          'elapsed_ms': watch.elapsedMilliseconds,
          'checks': checks,
          'telemetry': continued['data']['telemetry'],
        });
        if (checks.values.any((passed) => !passed)) {
          throw StateError('Live tool verification failed');
        }
      } finally {
        await client.close();
        await server.close();
      }
    }
  } catch (_) {
    report['failed'] = true;
    exitCode = 1;
    rethrow;
  } finally {
    cancellation.cancel();
    await signal.cancel();
    await root.delete(recursive: true);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  }
}
