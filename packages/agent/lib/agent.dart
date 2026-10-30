import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:code_mode/code_mode.dart';
import 'package:telemetry/telemetry.dart';

import 'src/tools.dart';
import 'src/instructions.dart';
import 'src/history_tools.dart';

export 'src/tool_specs.dart' show agentInstructions, codeTool;
export 'src/config.dart' show initialConfiguration;

Future<IsolateOwner> startAgent({
  required String taskId,
  required Json config,
  required SendPort writer,
  required SendPort network,
  SendPort? clientTools,
}) => IsolateOwner.start(_agentMain, {
  ...config,
  'task_id': taskId,
  'writer': writer,
  'network': network,
  'client_tools': clientTools,
});

void _agentMain(List<Object?> args) {
  final actor = _Agent(jsonObject(args[1]));
  final port = ReceivePort();
  (args[0] as SendPort).send(port.sendPort);
  Future<void>? running;
  port.listen((raw) async {
    final request = jsonObject(raw),
        params = jsonObject(jsonObject(raw)['params']);
    final reply = request['reply'] as SendPort?;
    try {
      switch (request['method']) {
        case 'turn':
          if (running != null)
            throw StateError('Task already has an active turn');
          running = actor.turn(
            params['prompt'] as String? ?? '',
            (event) => reply?.send({'event': event}),
            compact: params['compact'] == true,
            settings: jsonObject(params['settings'] ?? {}),
          );
          try {
            await running;
            reply?.send({'result': null});
          } finally {
            running = null;
          }
        case 'cancel':
          actor.cancel();
          reply?.send({'result': null});
        case 'close':
          actor.cancel();
          await running;
          reply?.send({'result': null});
          port.close();
        default:
          throw StateError('Unknown agent operation');
      }
    } catch (error) {
      reply?.send({'error': error.toString()});
    }
  });
}

class _Agent {
  _Agent(this.config);
  final Json config;
  CancellationToken? _cancellation;
  String get taskId => config['task_id'] as String;
  SendPort get writer => config['writer'] as SendPort;
  SendPort get network => config['network'] as SendPort;
  void cancel() {
    _cancellation?.cancel();
    network.send({
      'method': 'cancel',
      'params': {'task_id': taskId},
    });
  }

  Future<Object?> _metadata(String key) =>
      callIsolate(writer, 'metadata', {'key': key});
  Future<Json> _append(
    String type,
    Json data, {
    Json metadata = const {},
  }) async => jsonObject(
    await callIsolate(writer, 'append', {
      'type': type,
      'data': data,
      'metadata': metadata,
    }),
  );

  Future<void> turn(
    String prompt,
    void Function(Json) emit, {
    bool compact = false,
    Json settings = const {},
  }) async {
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    final telemetry = Telemetry(enabled: config['telemetry'] != false);
    final total = Stopwatch()..start();
    HostTools? host;
    final turnId = newId();
    void event(Json value) =>
        emit({'task_id': taskId, 'turn_id': turnId, ...value});
    try {
      if (settings['model'] != null && settings['model'] != config['model'] ||
          settings['provider'] != null &&
              settings['provider'] != config['provider']) {
        throw ArgumentError('The model and provider are fixed for this task');
      }
      final baseline = jsonObject(config['provider_settings']);
      final previousEffort =
          await _metadata('effective_reasoning') ?? baseline['reasoning'];
      final effort =
          settings['reasoning'] as String? ?? previousEffort as String;
      if (effort != previousEffort && config['reasoning_updates'] != true) {
        throw ArgumentError('Reasoning effort is fixed for this task');
      }
      if (settings['settings'] != null)
        throw ArgumentError(
          'Provider settings are fixed at task creation; use reasoning for a supported effort update',
        );
      await callIsolate(network, 'validate_settings', {
        'provider': config['provider'],
        'model': config['model'],
        'settings': {...baseline, 'reasoning': effort},
      }, cancellation: cancellation);
      cancellation.throwIfCancelled();
      final previousCwd =
          await _metadata('current_cwd') as String? ?? config['cwd'] as String;
      final cwd = settings['cwd'] as String? ?? previousCwd;
      var values = jsonObject(await _metadata('values') ?? {});
      host = HostTools(cwd, cancellation);
      final persisted = await _metadata('config');
      if (persisted == null) {
        final effective = {...config}
          ..remove('writer')
          ..remove('network')
          ..remove('client_tools');
        event(
          await _append(
            'task.created',
            effective,
            metadata: {'config': effective},
          ),
        );
      }
      event(
        await _append(
          'turn.started',
          {'id': turnId},
          metadata: {'status': 'running'},
        ),
      );
      var input = (await callIsolate(
        writer,
        'context',
        {},
        cancellation: cancellation,
      ) as List).map((v) => ConversationItem.fromJson(jsonObject(v))).toList();
      final completed = input
          .expand((item) => item.content)
          .where((p) => p['type'] == 'tool_result')
          .map((p) => p['call_id'])
          .toSet();
      for (final call in input.expand((item) => item.calls).toList()) {
        if (!completed.contains(call.id)) {
          final result = ConversationItem.toolResult(
            call,
            'Interrupted before a durable result. Side effects may have occurred; inspect state before retrying.',
            isError: true,
          );
          event(await _append('tool.completed', {'item': result.toJson()}));
          input.add(result);
        }
      }

      final snapshot = await loadAgentsMd(
        cwd,
        config['global_directory'] as String,
        cancellation,
      );
      final previousSnapshot = await _metadata('agents_snapshot');
      final updates = <Json>[];
      void update(String type, ConversationItem item, [Json data = const {}]) =>
          updates.add({
            'type': type,
            'data': {...data, 'item': item.toJson()},
          });
      if (jsonEncode(previousSnapshot) != jsonEncode(snapshot)) {
        update(
          'agents.updated',
          instructionMessage(snapshot, replacement: previousSnapshot != null),
          {'snapshot': snapshot},
        );
      }
      if (persisted == null || previousCwd != cwd) {
        update('environment.updated', environmentMessage(cwd), {'cwd': cwd});
      }
      if (settings['instructions'] != null)
        update(
          'instructions.updated',
          ConversationItem.text(
            'developer',
            requiredString(settings, 'instructions'),
          ),
        );
      if (effort != previousEffort)
        update(
          'configuration.updated',
          ConversationItem(
            kind: 'configuration',
            settings: {'reasoning': effort},
          ),
          {'effort': effort},
        );
      if (!compact) {
        update('input.committed', ConversationItem.text('user', prompt));
      } else if (effort != previousEffort) {
        update(
          'input.committed',
          ConversationItem.text(
            'user',
            'Apply the updated settings and compact the current context.',
          ),
        );
      }
      if (updates.isNotEmpty) {
        cancellation.throwIfCancelled();
        final committed = await callIsolate(writer, 'append_batch', {
          'events': updates,
          'metadata': {
            'effective_reasoning': effort,
            'current_cwd': cwd,
            'agents_snapshot': snapshot,
          },
        }) as List;
        for (final raw in committed) {
          final entry = jsonObject(raw);
          event(entry);
          input.add(
            ConversationItem.fromJson(jsonObject(entry['data']['item'])),
          );
        }
      }

      var usageTokens = await _metadata('context_usage') as int? ?? 0;
      var usageItems = await _metadata('context_usage_items') as int? ?? 0;
      var mcpSnapshot = jsonObject(await _metadata('mcp_snapshot') ?? {});
      var clientSnapshot = jsonObject(
        await _metadata('client_tools_snapshot') ?? {'tools': []},
      );
      final clientTools = config['client_tools'] as SendPort?;
      Future<void> refreshClientTools() async {
        final current = clientTools == null
            ? <String, dynamic>{'tools': []}
            : jsonObject(
                await callIsolate(clientTools, 'catalog', {
                  'task_id': taskId,
                }, cancellation: cancellation),
              );
        if (jsonEncode(current) == jsonEncode(clientSnapshot)) return;
        final previous = {
          for (final raw in clientSnapshot['tools'] as List)
            (raw as Map)['name']: raw,
        };
        final changed = (current['tools'] as List)
            .map(jsonObject)
            .where(
              (tool) => jsonEncode(previous[tool['name']]) != jsonEncode(tool),
            )
            .toList();
        final updates = <ConversationItem>[
          if (changed.isNotEmpty) clientToolDefinitions({'tools': changed}),
          clientToolsContext(current),
        ];
        final entries = await callIsolate(writer, 'append_batch', {
          'events': [
            for (final item in updates)
              {
                'type': 'client_tools.updated',
                'data': {'item': item.toJson(), 'snapshot': current},
              },
          ],
          'metadata': {'client_tools_snapshot': current},
        }) as List;
        for (final entry in entries) {
          event(jsonObject(entry));
        }
        input.addAll(updates);
        clientSnapshot = current;
      }

      Future<void> refreshMcp() async {
        final current = jsonObject(
          await callIsolate(network, 'mcp.catalog', {
            'task_id': taskId,
          }, cancellation: cancellation),
        );
        if (jsonEncode(current) != jsonEncode(mcpSnapshot)) {
          final item = mcpContext(current);
          event(
            await _append(
              'mcp.updated',
              {'snapshot': current, 'item': item.toJson()},
              metadata: {'mcp_snapshot': current},
            ),
          );
          input.add(item);
          mcpSnapshot = current;
        }
      }

      await refreshMcp();
      await refreshClientTools();
      final initialTools = (config['tools'] as List)
          .map((v) => ToolDefinition.fromJson(jsonObject(v)))
          .toList();
      ModelRequest request() => ModelRequest(
        taskId: taskId,
        model: config['model'] as String,
        instructions: config['instructions'] as String,
        input: input,
        tools: initialTools,
        settings: baseline,
        effectiveReasoning: effort,
      );
      Future<Json> networkCall(String method) async {
        cancellation.throwIfCancelled();
        return jsonObject(
          await callIsolate(
            network,
            method,
            {'provider': config['provider'], ...request().toJson()},
            onEvent: event,
            cancellation: cancellation,
          ),
        );
      }

      void countUsage(ModelUsage usage) {
        telemetry.add('input_tokens', usage.inputTokens);
        telemetry.add('cached_input_tokens', usage.cachedInputTokens);
        telemetry.add('cache_write_tokens', usage.cacheWriteTokens);
        telemetry.add('output_tokens', usage.outputTokens);
      }

      Future<void> compactContext(String reason) async {
        cancellation.throwIfCancelled();
        event(await _append('compaction.started', {'reason': reason}));
        final result = CompactionResult.fromJson(await networkCall('compact'));
        cancellation.throwIfCancelled();
        final restored = restoreContext(
          result.context,
          input,
          snapshot,
          cwd,
          baseline['reasoning'] as String,
          effort,
          config['reasoning_updates'] == true,
          mcpSnapshot: mcpSnapshot,
          clientSnapshot: clientSnapshot,
        );
        final size =
            estimateTokens(restored) +
            (config['instructions'] as String).length ~/ 3;
        final entry = await _append(
          'context.compacted',
          {
            'input': restored.map((v) => v.toJson()).toList(),
            'summary': result.summary,
            'usage': result.usage.toJson(),
            'reason': reason,
          },
          metadata: {
            'context_usage': size,
            'context_usage_items': restored.length,
          },
        );
        input = restored;
        usageTokens = size;
        usageItems = input.length;
        countUsage(result.usage);
        telemetry.add('compactions');
        event(entry);
      }

      Future<void> finish(String text) async {
        telemetry.observe('turn', total.elapsed);
        event(
          await _append(
            'turn.completed',
            {'text': text, 'telemetry': telemetry.snapshot()},
            metadata: {'status': 'idle'},
          ),
        );
      }

      if (compact) {
        await compactContext('manual');
        await finish('Context compacted. Full history remains available.');
        return;
      }

      var overflowRecovered = false;
      final maxSteps = config['max_steps'] as int? ?? 64;
      for (var step = 0; step < maxSteps; step++) {
        cancellation.throwIfCancelled();
        await refreshMcp();
        await refreshClientTools();
        final estimate = usageTokens > 0 && usageItems <= input.length
            ? usageTokens + estimateTokens(input.skip(usageItems))
            : estimateTokens(input) +
                  (config['instructions'] as String).length ~/ 3;
        if (estimate >=
            (baseline['context_limit'] as int) -
                (baseline['compaction_headroom'] as int)) {
          await compactContext('threshold');
        }
        final modelTime = Stopwatch()..start();
        final ModelReply reply;
        try {
          reply = ModelReply.fromJson(await networkCall('respond'));
        } on RemoteFailure catch (error) {
          if (error.code == 'context_overflow' && !overflowRecovered) {
            overflowRecovered = true;
            await compactContext('overflow');
            step--;
            continue;
          }
          rethrow;
        }
        cancellation.throwIfCancelled();
        telemetry.observe('model', modelTime.elapsed);
        telemetry.add('model_requests');
        countUsage(reply.usage);
        input.addAll(reply.output);
        usageTokens = reply.usage.contextTokens;
        usageItems = input.length;
        event(
          await _append(
            'model.completed',
            reply.toJson(),
            metadata: {
              'context_usage': usageTokens,
              'context_usage_items': usageItems,
            },
          ),
        );
        if (reply.calls.isEmpty) {
          await finish(reply.text);
          return;
        }
        for (final call in reply.calls) {
          cancellation.throwIfCancelled();
          event(
            await _append('tool.started', {
              'call_id': call.id,
              'name': call.name,
              'input': call.input,
            }),
          );
          final watch = Stopwatch()..start();
          Json result;
          final cellCancellation = CancellationToken();
          final link = CancellationHook(cancellation, cellCancellation.cancel);
          try {
            if (call.namespace == 'client') {
              if (clientTools == null)
                throw StateError('Client tools are unavailable');
              final output = jsonObject(
                await callIsolate(clientTools, 'call', {
                  'task_id': taskId,
                  'name': call.name,
                  'arguments': jsonObject(jsonDecode(call.input)),
                }, cancellation: cellCancellation),
              );
              result = output['success'] == true
                  ? {'output': output}
                  : {'error': output};
            } else {
              if (call.name != 'exec' ||
                  call.namespace != null && call.namespace != 'functions')
                throw StateError('Unknown model tool');
              result = await const CodeMode().execute(
                call.input,
                catalog: [
                  ...(config['host_catalog'] as List).map(jsonObject),
                  ...historyCatalog,
                  ...(mcpSnapshot['tools'] as List? ?? []).map(jsonObject),
                  ...mcpResourceCatalog,
                  for (final raw in clientSnapshot['tools'] as List)
                    {...jsonObject(raw), 'name': 'client__${raw['name']}'},
                ],
                cancellation: cellCancellation,
                values: values,
                tool: (name, arguments) async {
                  cellCancellation.throwIfCancelled();
                  final id = newId();
                  await _append('host_tool.started', {
                    'id': id,
                    'name': name,
                    'arguments': arguments,
                  });
                  try {
                    final Object? output;
                    if (name.startsWith('history__')) {
                      output = await callIsolate(
                        writer,
                        'history.${name.substring(9)}',
                        jsonObject(arguments),
                        cancellation: cellCancellation,
                      );
                    } else if (name.startsWith('client__')) {
                      if (clientTools == null)
                        throw StateError('Client tools are unavailable');
                      output = await callIsolate(clientTools, 'call', {
                        'task_id': taskId,
                        'name': name.substring(8),
                        'arguments': arguments,
                      }, cancellation: cellCancellation);
                    } else if (name.startsWith('mcp__')) {
                      output = await callIsolate(network, 'mcp.call', {
                        'task_id': taskId,
                        'name': name,
                        'arguments': arguments,
                      }, cancellation: cellCancellation);
                    } else if (mcpResourceMethods.containsKey(name)) {
                      output = await callIsolate(network, 'mcp.resources', {
                        'task_id': taskId,
                        'method': mcpResourceMethods[name],
                        'arguments': arguments,
                      }, cancellation: cellCancellation);
                    } else {
                      output = await host!.call(name, arguments);
                    }
                    await _append('host_tool.completed', {
                      'id': id,
                      'name': name,
                      'output': output,
                    });
                    return output;
                  } catch (error) {
                    if (error is CancelledException) rethrow;
                    await _append('host_tool.completed', {
                      'id': id,
                      'name': name,
                      'error': error.toString(),
                    });
                    rethrow;
                  }
                },
              );
              values = jsonObject(result['values']);
            }
          } on CancelledException {
            rethrow;
          } catch (error) {
            result = {'error': error.toString()};
          } finally {
            cellCancellation.cancel();
            link.dispose();
          }
          telemetry.observe('code', watch.elapsed);
          telemetry.add('code_cells');
          final item = ConversationItem.toolResult(
            call,
            jsonEncode(
              result.containsKey('error')
                  ? result
                  : {'output': result['output']},
            ),
            isError: result.containsKey('error'),
          );
          event(
            await _append(
              'tool.completed',
              {'item': item.toJson(), 'values': values},
              metadata: {'values': values},
            ),
          );
          input.add(item);
        }
      }
      throw StateError('Agent step limit reached');
    } catch (error) {
      telemetry.observe('turn', total.elapsed);
      event(
        await _append(
          cancellation.isCancelled ? 'turn.cancelled' : 'turn.failed',
          {'error': error.toString(), 'telemetry': telemetry.snapshot()},
          metadata: {'status': 'idle'},
        ),
      );
    } finally {
      cancellation.cancel();
      host?.close();
      _cancellation = null;
    }
  }
}
