import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

/// Live deferred discovery through both GPT transports. Credentials are
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
          'prompt': 'First call tool_search with query mcp__live_probe__probe and limit 1. '
              'Then call mcp__live_probe.probe directly with {"action":"inspect"}. '
              'Do not use functions.exec or shell commands. Reply with the returned PID only.',
        });
        final history = (await client.request('history.page', {'task_id': task, 'limit': 500}) as List)
            .map(jsonObject).toList();
        final catalog = history.lastWhere((event) => event['type'] == 'mcp.updated')['data']['snapshot']['tools'] as List;
        final statuses = await client.request('mcp.status', {}) as List;
        final pid = statuses.singleWhere((server) => server['name'] == 'live_probe')['pid'];
        final selected = [
          for (final event in history)
            if (event['data']['item'] is Map)
              ...((event['data']['item']['tools'] as List?) ?? []),
        ];
        final checks = <String, bool>{
          'dart_mcp_ready': statuses.any((server) => server['name'] == 'dart' && server['state'] == 'ready'),
          'dart_tools_discoverable': catalog.any((tool) => tool['namespace'] == 'mcp__dart'),
          'search_executed': history.any((event) => event['type'] == 'tool.started' && event['data']['name'] == 'tool_search'),
          'only_selected_schema_loaded': selected.length == 1 && selected.single['namespace'] == 'mcp__live_probe' && selected.single['name'] == 'probe',
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
        final coded = await turn('task.start', {
          'cwd': data.path, 'model': report['model'], 'reasoning': report['reasoning'],
          'settings': {'transport': transport},
          'prompt': 'Use functions.exec to call tools.tool_search({query:"mcp__live_probe__probe",limit:1}), '
            'inspect the result, then call tools.mcp__live_probe__probe({action:"inspect"}) in code mode. '
            'Reply with the process PID only.',
        });
        final codeHistory = (await client.request('history.page', {'task_id': coded['task_id'], 'limit': 500}) as List).map(jsonObject).toList();
        checks.addAll({
          'code_search_executed': codeHistory.any((event) => event['type'] == 'host_tool.started' && event['data']['name'] == 'tool_search'),
          'code_discovery_did_not_load_native_tools': !codeHistory.any((event) => (event['data']['item']?['tools'] as List? ?? []).isNotEmpty),
          'code_answer_matches_process': (coded['data']['text'] as String).contains('$pid'),
        });
        result['code_telemetry'] = coded['data']['telemetry'];
        result['elapsed_ms'] = watch.elapsedMilliseconds;
        if (checks.values.any((passed) => !passed)) throw StateError('Live code discovery verification failed');
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
