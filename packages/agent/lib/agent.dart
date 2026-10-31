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
import 'src/discovery.dart';
import 'src/tool_specs.dart' show toolSearchDefinition;

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
          if (running != null) {
            throw StateError('Task already has an active turn');
          }
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
        case 'steer':
          actor.steer(params);
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
  CancellationToken? _responseCancellation;
  bool _accepting = false;
  final _steering = <Json>[];
  void steer(Json message) {
    if (_accepting && _cancellation?.isCancelled == false) {
      _steering.add(message);
      _responseCancellation?.cancel();
    }
  }

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
    _accepting = !compact;
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
      var effort =
          settings['reasoning'] as String? ?? previousEffort as String;
      if (effort != previousEffort && config['reasoning_updates'] != true) {
        throw ArgumentError('Reasoning effort is fixed for this task');
      }
      if (settings['settings'] != null) {
        throw ArgumentError(
          'Provider settings are fixed at task creation; use reasoning for a supported effort update',
        );
      }
      await callIsolate(network, 'validate_settings', {
        'provider': config['provider'],
        'model': config['model'],
        'settings': {...baseline, 'reasoning': effort},
      }, cancellation: cancellation);
      cancellation.throwIfCancelled();
      final savedCwd = await _metadata('current_cwd') as String?;
      final previousCwd = savedCwd ?? config['cwd'] as String;
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

      final repository = jsonObject(await callIsolate(network, 'agents.repository', {
        'task_id': taskId, 'cwd': cwd,
      }, cancellation: cancellation));
      final snapshot = await loadAgentsMd(
        repository,
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
      final hadInstructions = previousSnapshot is Map &&
          (previousSnapshot['files'] as List).isNotEmpty;
      if (jsonEncode(previousSnapshot) != jsonEncode(snapshot) &&
          (hadInstructions || (snapshot['files'] as List).isNotEmpty)) {
        update(
          'agents.updated',
          instructionMessage(snapshot, replacement: hadInstructions),
          {'snapshot': snapshot},
        );
      }
      if (savedCwd == null || previousCwd != cwd) {
        update('environment.updated', environmentMessage(cwd), {'cwd': cwd});
      }
      if (settings['instructions'] != null) {
        update(
          'instructions.updated',
          ConversationItem.text(
            'developer',
            requiredString(settings, 'instructions'),
          ),
        );
      }
      if (effort != previousEffort) {
        update(
          'configuration.updated',
          ConversationItem(
            kind: 'configuration',
            settings: {'reasoning': effort},
          ),
          {'effort': effort},
        );
      }
      if (!compact) {
        update('input.committed', ConversationItem.user(prompt, attachments: settings['attachments']), {
          if (settings['message_id'] != null)
            'message_id': settings['message_id'],
          if (settings['sent_at'] != null) 'sent_at': settings['sent_at'],
        });
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
      Future<bool> takeSteering() async {
        cancellation.throwIfCancelled();
        if (_steering.isEmpty) return false;
        final messages = _steering.toList();
        _steering.clear();
        final updates = <Json>[];
        for (final message in messages) {
          if (message['reasoning'] case final String selected when selected != effort) {
            if (config['reasoning_updates'] != true) {
              throw ArgumentError('Reasoning effort is fixed for this task');
            }
            updates.add({
              'type': 'configuration.updated',
              'data': {
                'effort': selected,
                'item': ConversationItem(
                  kind: 'configuration',
                  settings: {'reasoning': selected},
                ).toJson(),
              },
            });
            effort = selected;
          }
          updates.add({
            'type': 'input.committed',
            'data': {
              'message_id': message['id'],
              'delivery': 'steer',
              if (message['created_at'] != null) 'sent_at': message['created_at'],
              'item': ConversationItem.user(
                message['prompt'] as String,
                attachments: message['attachments'],
              ).toJson(),
            },
          });
        }
        final entries = await callIsolate(writer, 'append_batch', {
          'events': updates,
          'metadata': {'effective_reasoning': effort},
        }) as List;
        for (final raw in entries) {
          final entry = jsonObject(raw);
          event(entry);
          input.add(
            ConversationItem.fromJson(jsonObject(entry['data']['item'])),
          );
        }
        return true;
      }

      var usageItems = await _metadata('context_usage_items') as int? ?? 0;
      var mcpSnapshot = jsonObject(await _metadata('mcp_snapshot') ?? {});
      var clientSnapshot = jsonObject(
        await _metadata('client_tools_snapshot') ?? {'tools': []},
      );
      var persistedMcp = mcpSnapshot, persistedClient = clientSnapshot;
      final initialTools = (config['tools'] as List)
          .map((v) => ToolDefinition.fromJson(jsonObject(v)))
          .toList();
      Map<String, ToolDefinition> loaded() => {
        for (final tool in initialTools) toolKey(tool): tool,
        ...loadedTools(input),
      };
      final clientTools = config['client_tools'] as SendPort?;
      var mcpCatalog = mcpSnapshot, clientCatalog = clientSnapshot;
      Future<Json> readMcpCatalog([CancellationToken? token]) async {
        final current = jsonObject(await callIsolate(network, 'mcp.catalog', {
          'task_id': taskId, 'revision': mcpCatalog['revision'],
        }, cancellation: token ?? cancellation));
        if (current['unchanged'] != true) mcpCatalog = current;
        return mcpCatalog;
      }
      Future<Json> readClientCatalog([CancellationToken? token]) async {
        final current = clientTools == null ? <String, dynamic>{'tools': []}
          : jsonObject(await callIsolate(clientTools, 'catalog', {
            'task_id': taskId, 'revision': clientCatalog['revision'],
          }, cancellation: token ?? cancellation));
        if (current['unchanged'] != true) clientCatalog = current;
        return clientCatalog;
      }
      Future<List<Json>> currentDeferredCatalog(CancellationToken token) async {
        await Future.wait([readMcpCatalog(token), readClientCatalog(token)]);
        return deferredCatalog(mcpCatalog, clientCatalog);
      }
      Future<void> updateCatalog(Json current, Json previous, {required bool mcp}) async {
        final known = loaded();
        final definitions = mcp ? mcpToolDefinitions(current).tools : clientToolDefinitions(current).tools;
        final changed = definitions.where((tool) => known.containsKey(toolKey(tool)) &&
          contextFingerprint(known[toolKey(tool)]!.toJson()) != contextFingerprint(tool.toJson()),
        ).toList();
        final updates = <ConversationItem>[
          if (changed.isNotEmpty) ConversationItem(
            kind: 'tools', tools: changed,
            native: {'harness': {'context': mcp ? 'mcp' : 'client_tools'}},
          ),
          ?catalogContext(current, previous, known.keys.toSet(), mcp: mcp),
        ];
        if (updates.isEmpty) return;
        cancellation.throwIfCancelled();
        final entries = await callIsolate(writer, 'append_batch', {
          'events': [for (final item in updates) {
            'type': mcp ? 'mcp.updated' : 'client_tools.updated',
            'data': {'item': item.toJson(), 'snapshot': current},
          }],
          'metadata': {mcp ? 'mcp_snapshot' : 'client_tools_snapshot': current},
        }) as List;
        for (final entry in entries) {
          event(jsonObject(entry));
        }
        input.addAll(updates);
        if (mcp) {
          persistedMcp = current;
        } else {
          persistedClient = current;
        }
      }

      Future<void> refreshClientTools() async {
        final current = await readClientCatalog();
        if (identical(current, clientSnapshot)) return;
        if (contextFingerprint(current) == contextFingerprint(clientSnapshot)) return;
        await updateCatalog(current, clientSnapshot, mcp: false);
        clientSnapshot = current;
      }

      Future<void> refreshMcp() async {
        final current = await readMcpCatalog();
        if (identical(current, mcpSnapshot)) return;
        if (contextFingerprint(current) != contextFingerprint(mcpSnapshot)) {
          await updateCatalog(current, mcpSnapshot, mcp: true);
          mcpSnapshot = current;
        }
      }

      // Older tasks retain their frozen prefix; introduce discovery as an
      // ordered declaration instead of rewriting their original configuration.
      if (!loaded().containsKey(toolKey(toolSearchDefinition))) {
        final item = ConversationItem(
          kind: 'tools', tools: [toolSearchDefinition],
          native: {'harness': {'context': 'discovery'}},
        );
        event(await _append('tools.updated', {'item': item.toJson()}));
        input.add(item);
      }
      ModelRequest request() => ModelRequest(
        taskId: taskId,
        model: config['model'] as String,
        instructions: config['instructions'] as String,
        input: input,
        tools: initialTools,
        settings: baseline,
        effectiveReasoning: effort,
      );
      Future<Json> networkCall(String method, [CancellationToken? token]) async {
        final active = token ?? cancellation;
        active.throwIfCancelled();
        return jsonObject(
          await callIsolate(
            network,
            method,
            {'provider': config['provider'], ...request().toJson()},
            onEvent: (value) {
              if (!active.isCancelled) event(value);
            },
            timeout: null,
            cancellation: active,
          ),
        );
      }

      Future<ModelReply?> respond() async {
        // Steering preempts inference, without cancelling the turn or its tools.
        final token = _responseCancellation = CancellationToken();
        final link = CancellationHook(cancellation, token.cancel);
        try {
          // Input may arrive during catalog refresh or automatic compaction.
          if (_steering.isNotEmpty) return null;
          return ModelReply.fromJson(await networkCall('respond', token));
        } on CancelledException {
          cancellation.throwIfCancelled();
          if (!token.isCancelled || _steering.isEmpty) rethrow;
          return null;
        } finally {
          _responseCancellation = null;
          link.dispose();
          token.cancel();
        }
      }

      Future<String> searchWeb(Object? commands, CancellationToken token) async =>
          await callIsolate(network, 'web.search', {
            'provider': config['provider'],
            ...request().toJson(),
            'commands': webSearchCommands(commands),
          }, timeout: null, cancellation: token) as String;

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
          initialTools: initialTools,
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
        _accepting = false;
        telemetry.observe('turn', total.elapsed);
        event(
          await _append(
            'turn.completed',
            {'text': text, 'telemetry': telemetry.snapshot()},
            metadata: {
              'status': 'idle',
              if (!identical(mcpSnapshot, persistedMcp)) 'mcp_snapshot': mcpSnapshot,
              if (!identical(clientSnapshot, persistedClient)) 'client_tools_snapshot': clientSnapshot,
            },
          ),
        );
      }

      if (compact) {
        await refreshMcp();
        await refreshClientTools();
        await compactContext('manual');
        await finish('Context compacted. Full history remains available.');
        return;
      }

      var overflowRecovered = false;
      while (true) {
        cancellation.throwIfCancelled();
        await takeSteering();
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
        final ModelReply? reply;
        try {
          reply = await respond();
        } on RemoteFailure catch (error) {
          if (error.code == 'context_overflow' && !overflowRecovered) {
            overflowRecovered = true;
            await compactContext('overflow');
            continue;
          }
          rethrow;
        }
        cancellation.throwIfCancelled();
        if (reply == null) continue;
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
          if (await takeSteering()) continue;
          await finish(reply.text);
          return;
        }
        for (final call in reply.calls) {
          cancellation.throwIfCancelled();
          event(
            await _append('tool.started', {
              'call_id': call.id,
              'name': call.name,
              if (call.namespace != null) 'namespace': call.namespace,
              'input': call.input,
            }),
          );
          final watch = Stopwatch()..start();
          Json result;
          var selectedTools = <ToolDefinition>[];
          final cellCancellation = CancellationToken();
          final link = CancellationHook(cancellation, cellCancellation.cancel);
          try {
            if (call.name == 'tool_search' && call.namespace == null) {
              final selected = searchTools(await currentDeferredCatalog(cellCancellation), jsonObject(jsonDecode(call.input)));
              final known = loaded();
              selectedTools = selected.map((tool) => catalogDefinition(tool, mcp: mcpCatalog)).where((tool) =>
                contextFingerprint(known[toolKey(tool)]?.toJson()) != contextFingerprint(tool.toJson()),
              ).toList();
              result = {'output': {'tools': selected.map((tool) => tool['name']).toList()}};
            } else if (call.namespace == 'web' && call.name == 'run') {
              result = {'output': await searchWeb(jsonDecode(call.input), cellCancellation)};
            } else if (call.namespace == 'client') {
              if (clientTools == null) {
                throw StateError('Client tools are unavailable');
              }
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
            } else if (call.namespace?.startsWith('mcp__') == true) {
              final output = jsonObject(
                await callIsolate(network, 'mcp.call', {
                  'task_id': taskId,
                  'name': '${call.namespace}__${call.name}',
                  'arguments': jsonObject(jsonDecode(call.input)),
                }, cancellation: cellCancellation),
              )..remove('_meta');
              result = output['isError'] == true
                  ? {'error': output}
                  : {'output': output};
            } else {
              if (call.name != 'exec' ||
                  call.namespace != null && call.namespace != 'functions') {
                throw StateError('Unknown model tool');
              }
              result = await const CodeMode().execute(
                call.input,
                catalog: [
                  ...(config['host_catalog'] as List).map(jsonObject).where((tool) => tool['name'] != 'web__run'),
                  webSearchHost,
                  ...historyCatalog,
                  {...toolSearchDefinition.toJson(), 'format': 'json'},
                  ...(await currentDeferredCatalog(cellCancellation)).map(describeHostTool),
                  ...mcpResourceCatalog,
                ],
                cancellation: cellCancellation,
                values: values,
                tool: (name, arguments) async {
                  cellCancellation.throwIfCancelled();
                  final id = newId();
                  event(
                    await _append('host_tool.started', {
                      'id': id,
                      'parent_call_id': call.id,
                      'name': name,
                      'arguments': arguments,
                    }),
                  );
                  try {
                    final Object? output;
                    if (name == 'tool_search') {
                      output = discoveryResult(searchTools(
                        await currentDeferredCatalog(cellCancellation), jsonObject(arguments),
                      ), mcpCatalog);
                    } else if (name == 'web__run') {
                      output = await searchWeb(arguments, cellCancellation);
                    } else if (name.startsWith('history__')) {
                      output = await callIsolate(
                        writer,
                        'history.${name.substring(9)}',
                        jsonObject(arguments),
                        cancellation: cellCancellation,
                      );
                    } else if (name.startsWith('client__')) {
                      if (clientTools == null) {
                        throw StateError('Client tools are unavailable');
                      }
                      output = await callIsolate(clientTools, 'call', {
                        'task_id': taskId,
                        'name': name.substring(8),
                        'arguments': arguments,
                      }, cancellation: cellCancellation);
                    } else if (name.startsWith('mcp__')) {
                      output = jsonObject(
                        await callIsolate(network, 'mcp.call', {
                          'task_id': taskId,
                          'name': name,
                          'arguments': arguments,
                        }, cancellation: cellCancellation),
                      )..remove('_meta');
                    } else if (mcpResourceMethods.containsKey(name)) {
                      output = await callIsolate(network, 'mcp.resources', {
                        'task_id': taskId,
                        'method': mcpResourceMethods[name],
                        'arguments': arguments,
                      }, cancellation: cellCancellation);
                    } else {
                      output = await host!.call(name, arguments);
                    }
                    event(
                      await _append('host_tool.completed', {
                        'id': id,
                        'parent_call_id': call.id,
                        'name': name,
                        'output': output,
                      }),
                    );
                    return output;
                  } catch (error) {
                    event(
                      await _append('host_tool.completed', {
                        'id': id,
                        'parent_call_id': call.id,
                        'name': name,
                        if (error is CancelledException) 'cancelled': true,
                        'error': error.toString(),
                      }),
                    );
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
          final output = call.namespace == 'web' && call.name == 'run' && !result.containsKey('error')
              ? result['output'] as String : jsonEncode(
            result.containsKey('error')
                ? result
                : {'output': result['output']},
          );
          final item = ConversationItem.toolResult(
            call,
            call.namespace?.startsWith('mcp__') == true
                ? truncateTextOutput(output)
                : output,
            isError: result.containsKey('error'),
            tools: selectedTools,
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
      _accepting = false;
      _steering.clear();
      cancellation.cancel();
      host?.close();
      _cancellation = null;
    }
  }
}
