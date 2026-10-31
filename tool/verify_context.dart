import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

/// Live verification through the public API. Output contains measurements and
/// checks only; credentials, model context, and native checkpoints stay private.
Future<void> main(List<String> args) async {
  final root = await Directory.systemTemp.createTemp('happen-context-live-');
  final cancellation = TimeoutCancellationToken(const Duration(minutes: 15));
  final signal = ProcessSignal.sigint.watch().listen(
    (_) => cancellation.cancel(),
  );
  final report = <String, dynamic>{
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'os': Platform.operatingSystem,
    'model': 'gpt-6.1-sol',
    'baseline_effort': 'low',
    'changed_effort': 'high',
    'results': <Json>[],
  };
  try {
    for (final transport in ['http', 'websocket']) {
      cancellation.throwIfCancelled();
      final data = await Directory('${root.path}/$transport/data')
          .create(recursive: true);
      final work = await Directory('${root.path}/$transport/work').create();
      await Directory('${work.path}/.git').create();
      await File('${work.path}/AGENTS.md').writeAsString(
        'End every final answer with CONTEXT_OK. Use Python standard library only.\n',
      );
      final auth = AuthManager(data.path);
      try {
        await auth.useCodex(args.isEmpty ? null : args.single);
        await auth.credentials();
      } finally {
        auth.close();
      }
      var server = await AgentServer.startEmbedded(
        directory: data.path,
        configPath: '${data.path}/config.yaml',
      );
      var client = await AgentClient.connect(
        server.uri,
        cancellation: cancellation,
      );
      final result = <String, dynamic>{
        'model_transport': transport,
        'client_transport': 'uds',
        'stages': <Json>[],
        'checks': <String, bool>{},
      };
      (report['results'] as List).add(result);
      Future<Object?> request(String method, Json params) {
        cancellation.throwIfCancelled();
        return client
            .request(method, params)
            .asCancellable(
              cancellation,
              onCancel: () => unawaited(client.close()),
            );
      }

      Future<Json> turn(String stage, String method, Json params) async {
        cancellation.throwIfCancelled();
        final watch = Stopwatch()..start();
        final completed = client.events.stream.firstWhere(
          (event) => const {
            'turn.completed',
            'turn.failed',
            'turn.cancelled',
          }.contains(event['type']),
        );
        await request(method, params);
        final terminal = await completed.asCancellable(cancellation);
        (result['stages'] as List).add({
          'stage': stage,
          'status': terminal['type'],
          'elapsed_ms': watch.elapsedMilliseconds,
          'usage': terminal['data']['telemetry']?['counters'],
          if (terminal['data']['error'] != null)
            'error': terminal['data']['error'],
        });
        if (terminal['type'] != 'turn.completed') {
          throw StateError('$transport $stage did not complete');
        }
        return terminal;
      }

      Future<List<Json>> history(String taskId) async => (await request(
        'history.page',
        {'task_id': taskId, 'limit': 500},
      ) as List).map(jsonObject).toList();

      try {
        final first = await turn('seed', 'task.start', {
          'cwd': work.path,
          'model': 'gpt-6.1-sol',
          'reasoning': 'low',
          'settings': {'transport': transport},
          'prompt': '''The project code is maple-47. Later, when I ask you to
continue, create result.txt containing exactly that code followed by one newline.
Do not create the file yet. First use code mode and tools.exec_command to run:
python3 -c 'import secrets; print("HISTORY_RECEIPT=" + secrets.token_hex(16))'
Keep the random receipt only in conversation/tool history; do not write it to a
file. Reply READY without repeating the receipt. Do not use network, skills,
plugins, or delegated agents.''',
        });
        final taskId = first['task_id'] as String;
        final seed = await history(taskId);
        final receiptPattern = RegExp(r'HISTORY_RECEIPT=([a-f0-9]{32})');
        final receiptEvent = seed.firstWhere(
          (event) =>
              event['type'] == 'tool.completed' &&
              receiptPattern.hasMatch(jsonEncode(event['data'])),
        );
        final receipt = receiptPattern
            .firstMatch(jsonEncode(receiptEvent['data']))!
            .group(1)!;
        const reminder =
            'Keep the file task unfinished until I ask you to continue. Reply READY.';
        await turn('same_effort', 'task.send', {
          'task_id': taskId,
          'prompt': reminder,
        });
        await turn('changed_effort', 'task.send', {
          'task_id': taskId,
          'prompt': reminder,
          'reasoning': 'high',
        });
        final compacted = await turn('compact', 'task.compact', {
          'task_id': taskId,
        });
        final afterCompaction = await history(taskId);
        final checkpoint = afterCompaction.lastWhere(
          (event) => event['type'] == 'context.compacted',
        );
        final context = checkpoint['data']['input'] as List;
        final checks = result['checks'] as Map<String, bool>;
        checks['native_checkpoint'] = context.any(
          (item) => item['kind'] == 'compaction',
        );
        checks['receipt_removed_from_visible_context'] = !jsonEncode(context)
            .contains(receipt);
        checks['instructions_restored'] = jsonEncode(context)
            .contains('End every final answer with CONTEXT_OK');
        checks['effective_effort_restored'] = context.any(
          (item) =>
              item['kind'] == 'configuration' &&
              item['settings']['reasoning'] == 'high',
        );
        checks['unfinished_file_absent'] = !await File(
          '${work.path}/result.txt',
        ).exists();

        await client.close();
        await server.close();
        server = await AgentServer.startEmbedded(
          directory: data.path,
          configPath: '${data.path}/config.yaml',
        );
        client = await AgentClient.connect(
          server.uri,
          cancellation: cancellation,
        );
        final fork = jsonObject(
          await request('task.fork', {
            'task_id': taskId,
            'through': compacted['seq'],
          }),
        );
        final bundle = '${root.path}/$transport/history.jsonl';
        await request('history.export', {
          'task_id': fork['task_id'],
          'path': bundle,
        });
        final imported = jsonObject(
          await request('history.import', {'path': bundle}),
        );
        final importedId = imported['task_id'] as String;
        final transferred = await history(importedId);
        checks['historical_item_survives_transfer'] = transferred.any(
          (event) =>
              event['id'] == receiptEvent['id'] &&
              jsonEncode(event['data']) == jsonEncode(receiptEvent['data']),
        );
        final continued = await turn(
          'recall_after_restart_and_transfer',
          'task.send',
          {
            'task_id': importedId,
            'prompt':
                '''Continue the unfinished file task now. Also retrieve the
original HISTORY_RECEIPT from durable history using the history tools exposed in
code mode; do not generate a new receipt or rely only on the compacted summary.
Search tool results and read the matching historical item. Include the receipt,
project code, filename, and newline requirement in your final answer.''',
          },
        );
        final answer = continued['data']['text'] as String;
        final resumedHistory = await history(importedId);
        checks['history_tools_called'] = resumedHistory.any(
          (event) =>
              (event['seq'] as int) > (compacted['seq'] as int) &&
              event['type'] == 'model.completed' &&
              jsonEncode(event['data']).contains('history__'),
        );
        checks['receipt_recalled'] = answer.contains(receipt);
        checks['facts_recalled'] =
            answer.contains('maple-47') &&
            answer.contains('result.txt') &&
            answer.toLowerCase().contains('newline');
        checks['instructions_followed'] = answer.trim().endsWith('CONTEXT_OK');
        final file = File('${work.path}/result.txt');
        checks['unfinished_action_completed'] =
            await file.exists() && await file.readAsString() == 'maple-47\n';
        result['passed'] = checks.values.every((value) => value);
      } finally {
        await client.close();
        await server.close();
      }
    }
  } catch (error) {
    report['error'] = error.toString();
  } finally {
    cancellation.cancel();
    await signal.cancel();
    await root.delete(recursive: true);
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  if ((report['results'] as List).length != 2 ||
      (report['results'] as List).any((value) => value['passed'] != true)) {
    exitCode = 1;
  }
}
