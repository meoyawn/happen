import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:code_mode/code_mode.dart';
import 'package:telemetry/telemetry.dart';

import 'src/instructions.dart';
import 'src/discovery.dart';
import 'src/skills.dart';
import 'src/providers.dart';

export 'src/config.dart' show initialConfiguration;

Future<IsolateOwner> startAgent({
  required String taskId,
  required Json config,
  required SendPort writer,
  required SendPort network,
  SendPort? clientTools,
  required SendPort taskTools,
  required int codeInterrupt,
}) => IsolateOwner.start(_agentMain, {
  ...config,
  'task_id': taskId,
  'writer': writer,
  'network': network,
  'client_tools': clientTools,
  'task_tools': taskTools,
  'code_interrupt': codeInterrupt,
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
  CancellationToken? _toolCancellation;
  Completer<void>? _toolPreemption;
  bool _accepting = false;
  final _steering = <Json>[];
  void steer(Json message) {
    if (_accepting && _cancellation?.isCancelled == false) {
      _steering.add(message);
      _responseCancellation?.cancel();
      _toolCancellation?.cancel();
      if (_toolPreemption?.isCompleted == false) _toolPreemption!.complete();
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
    final interface = toolInterface(config['tool_interface'] as String? ?? config['provider'] as String);
    ToolRuntime? host;
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
      host = interface.createRuntime(cwd, cancellation);
      final persisted = await _metadata('config');
      if (persisted == null) {
        final effective = {...config}
          ..remove('writer')
          ..remove('network')
          ..remove('client_tools')
          ..remove('task_tools')
          ..remove('code_interrupt');
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

      var skillsSnapshot = jsonObject(await _metadata('skills_state') ?? {});
      var skillsCatalog = <String, dynamic>{'skills': []};
      Future<void> refreshSkills() async {
        skillsCatalog = jsonObject(await callIsolate(network, 'skills.catalog', {
          'task_id': taskId, 'cwd': cwd,
        }, cancellation: cancellation));
        final next = skillContext(skillsCatalog, previous: skillsSnapshot,
          contextWindow: baseline['context_limit'] as int?);
        if (contextFingerprint(next.snapshot) == contextFingerprint(skillsSnapshot)) return;
        cancellation.throwIfCancelled();
        final item = next.item;
        event(await _append('skills.updated', {
          'skills_state': next.snapshot,
          if (item != null) 'item': item.toJson(),
        }, metadata: {'skills_state': next.snapshot}));
        skillsSnapshot = next.snapshot;
        if (item != null) input.add(item);
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
          interface.instructionContext(snapshot, previousSnapshot is Map ? jsonObject(previousSnapshot) : null),
          {'snapshot': snapshot},
        );
      }
      if (savedCwd == null || previousCwd != cwd) {
        update('environment.updated', interface.environmentContext(cwd, replacement: savedCwd != null), {'cwd': cwd});
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
      final legacyInterface = config['tool_interface'] == null && interface.replacesLegacyCatalog;
      final initialTools = legacyInterface ? interface.definitions : (config['tools'] as List)
          .map((v) => ToolDefinition.fromJson(jsonObject(v)))
          .toList();
      final providerContext = <ConversationItem>[
        if (legacyInterface) ConversationItem(
          role: 'developer', tools: interface.definitions,
          content: [{'type': 'text', 'text': interface.baseInstructions(config['model'] as String, config['base_instructions'] as String)}],
          native: {'harness': {'context': 'provider_tools', 'interface': interface.id}},
        ),
      ];
      if (providerContext.isNotEmpty && !input.any((item) => item.native['harness']?['context'] == 'provider_tools')) {
        final item = providerContext.single;
        event(await _append('tools.updated', {'item': item.toJson()}));
        input.add(item);
      }
      Map<String, ToolDefinition> loaded() => {
        for (final tool in initialTools) toolKey(tool): tool,
        ...loadedTools(input),
      };
      final additions = interface.definitions.where((tool) =>
        (interface.discovery == null || toolKey(tool) != toolKey(interface.discovery!)) &&
        !initialTools.any((initial) => toolKey(initial) == toolKey(tool) &&
          contextFingerprint(initial.toJson()) == contextFingerprint(tool.toJson()))).toList();
      if (additions.isNotEmpty) {
        final item = ConversationItem(kind: 'tools', tools: additions,
          native: {'harness': {'context': 'provider_additions'}});
        providerContext.add(item);
        final known = loaded();
        final missing = additions.where((tool) => !known.containsKey(toolKey(tool)) ||
          contextFingerprint(known[toolKey(tool)]!.toJson()) != contextFingerprint(tool.toJson())).toList();
        if (missing.isNotEmpty) {
          final update = ConversationItem(kind: 'tools', tools: missing, native: item.native);
          event(await _append('tools.updated', {'item': update.toJson()}));
          input.add(update);
        }
      }
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
      Future<void> refreshTools() async {
        await Future.wait([readMcpCatalog(), readClientCatalog()]);
        final mcpChanged = contextFingerprint(mcpCatalog) != contextFingerprint(mcpSnapshot);
        final clientChanged = contextFingerprint(clientCatalog) != contextFingerprint(clientSnapshot);
        final hasContext = input.any((item) => ['mcp', 'client_tools', 'tool_catalog'].contains(item.native['harness']?['context']));
        if (!mcpChanged && !clientChanged && hasContext) return;
        final known = loaded();
        final definitions = [...mcpToolDefinitions(mcpCatalog).tools, ...clientToolDefinitions(clientCatalog).tools];
        final changed = interface.discovery == null ? <ToolDefinition>[] : definitions.where((tool) => known.containsKey(toolKey(tool)) &&
          contextFingerprint(known[toolKey(tool)]!.toJson()) != contextFingerprint(tool.toJson()),
        ).toList();
        final text = interface.catalogContext(deferredCatalog(mcpCatalog, clientCatalog),
          hasContext ? deferredCatalog(mcpSnapshot, clientSnapshot) : null);
        final updates = <ConversationItem>[
          if (changed.isNotEmpty) ConversationItem(kind: 'tools', tools: changed,
            native: {'harness': {'context': mcpChanged ? 'mcp' : 'client_tools'}}),
          if (text != null) ConversationItem(role: 'developer', content: [{'type': 'text', 'text': text}],
            native: {'harness': {'context': 'tool_catalog'}}),
        ];
        if (updates.isNotEmpty) {
          cancellation.throwIfCancelled();
          final entries = await callIsolate(writer, 'append_batch', {
            'events': [for (final item in updates) {
              'type': mcpChanged ? 'mcp.updated' : 'client_tools.updated',
              'data': {'item': item.toJson(), 'snapshot': mcpChanged ? mcpCatalog : clientCatalog},
            }],
            'metadata': {'mcp_snapshot': mcpCatalog, 'client_tools_snapshot': clientCatalog},
          }) as List;
          for (final entry in entries) { event(jsonObject(entry)); }
          input.addAll(updates);
          persistedMcp = mcpCatalog; persistedClient = clientCatalog;
        }
        mcpSnapshot = mcpCatalog; clientSnapshot = clientCatalog;
      }

      // Older tasks retain their frozen prefix; introduce discovery as an
      // ordered declaration instead of rewriting their original configuration.
      final discovery = interface.discovery;
      if (discovery != null && !loaded().containsKey(toolKey(discovery))) {
        final item = ConversationItem(
          kind: 'tools', tools: [discovery],
          native: {'harness': {'context': 'discovery'}},
        );
        event(await _append('tools.updated', {'item': item.toJson()}));
        input.add(item);
      }
      ModelRequest request() => ModelRequest(
        taskId: taskId,
        model: config['model'] as String,
        instructions: interface.baseInstructions(config['model'] as String, config['instructions'] as String),
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
        // Inference and tools have fresh operation tokens; steering keeps the turn.
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
            'commands': commands,
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
        final freshSkills = skillContext(skillsCatalog,
          contextWindow: baseline['context_limit'] as int?);
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
          discovery: discovery,
          catalogContext: interface.catalogContext,
          instructionContext: interface.instructionContext,
          environmentContext: interface.environmentContext,
          providerContext: providerContext,
          skills: freshSkills.item,
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
            'skills_state': freshSkills.snapshot,
          },
          metadata: {
            'context_usage': size,
            'context_usage_items': restored.length,
            'skills_state': freshSkills.snapshot,
          },
        );
        input = restored;
        skillsSnapshot = freshSkills.snapshot;
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

      Future<bool> takeNotifications() async {
        final notices = await callIsolate(config['task_tools'] as SendPort, 'notifications',
          {'task_id': taskId}, cancellation: cancellation) as List;
        for (final notice in notices) {
          final item = ConversationItem(
            role: 'user', content: [{'type': 'text', 'text': notice}],
            native: {'harness': {'context': 'tool_notification'}},
          );
          event(await _append('input.committed', {'item': item.toJson()}));
          input.add(item);
        }
        return notices.isNotEmpty;
      }

      if (compact) {
        await refreshSkills();
        await refreshTools();
        await compactContext('manual');
        await finish('Context compacted. Full history remains available.');
        return;
      }

      var overflowRecovered = false;
      while (true) {
        cancellation.throwIfCancelled();
        await takeSteering();
        await takeNotifications();
        await refreshSkills();
        await refreshTools();
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
          if (await takeNotifications()) continue;
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
          var images = <Json>[];
          var selectedTools = <ToolDefinition>[];
          final cellCancellation = CodeCancellationToken.shared(config['code_interrupt'] as int);
          _toolCancellation = cellCancellation;
          final preemption = _toolPreemption = Completer<void>();
          final link = CancellationHook(cancellation, cellCancellation.cancel);
          try {
            if (_steering.isNotEmpty) throw const CancelledException();
            if (discovery != null && call.name == discovery.name && call.namespace == discovery.namespace) {
              final found = interface.search(await currentDeferredCatalog(cellCancellation), jsonObject(jsonDecode(call.input)));
              final selected = found.tools;
              selectedTools = selected.map((tool) => catalogDefinition(tool, mcp: mcpCatalog)).toList();
              result = {'output': found.output};
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
              result = await host.execute(call, ToolExecution(
                catalog: (cancellation) async => [
                  ...interface.hostCatalog,
                  ...interface.externalCatalog(await currentDeferredCatalog(cancellation)),
                ],
                cancellation: cellCancellation,
                values: values,
                call: (name, arguments, {required cancellation}) async {
                  cancellation.throwIfCancelled();
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
                    cancellation.throwIfCancelled();
                    final Object? output;
                    final service = interface.services[name];
                    if (discovery != null && name == discovery.name) {
                      output = interface.search(
                        await currentDeferredCatalog(cancellation), jsonObject(arguments), nested: true,
                      ).output;
                    } else if (service == 'skills.read') {
                      output = await callIsolate(network, 'skills.read', {
                        ...jsonObject(arguments), 'task_id': taskId, 'cwd': cwd,
                      }, cancellation: cancellation);
                    } else if (service == 'web.search') {
                      output = await searchWeb(arguments, cancellation);
                    } else if (service?.startsWith('history.') == true) {
                      output = await callIsolate(
                        writer,
                        service!,
                        jsonObject(arguments),
                        cancellation: cancellation,
                      );
                    } else if (name.startsWith('client__')) {
                      if (clientTools == null) {
                        throw StateError('Client tools are unavailable');
                      }
                      output = await callIsolate(clientTools, 'call', {
                        'task_id': taskId,
                        'name': name.substring(8),
                        'arguments': arguments,
                      }, cancellation: cancellation);
                    } else if (name.startsWith('mcp__')) {
                      output = jsonObject(
                        await callIsolate(network, 'mcp.call', {
                          'task_id': taskId,
                          'name': name,
                          'arguments': arguments,
                        }, cancellation: cancellation),
                      )..remove('_meta');
                    } else if (service != null) {
                      output = await callIsolate(network, 'mcp.resources', {
                        'task_id': taskId,
                        'method': service,
                        'arguments': arguments,
                      }, cancellation: cancellation);
                    } else {
                      output = await callIsolate(config['task_tools'] as SendPort, 'call', {
                        'task_id': taskId, 'provider': interface.id, 'cwd': cwd,
                        'name': name, 'arguments': arguments,
                      }, timeout: null, cancellation: cancellation);
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
              ));
              if (result['values'] != null) values = jsonObject(result['values']);
            }
            final separated = separateToolImages(result);
            result = separated.$1;
            if (separated.$2.isNotEmpty) {
              // The interpreter closes its execution token when the cell ends.
              // Image preparation is a new cancellable phase of the same tool.
              final preparation = CancellationToken();
              final preparationLink = CancellationHook(cancellation, preparation.cancel);
              _toolCancellation = preparation;
              try {
                if (_steering.isNotEmpty) throw const CancelledException();
                images = await interface.prepareImages(separated.$2, cancellation: preparation);
              } finally {
                preparationLink.dispose();
                preparation.cancel();
              }
            }
          } on CancelledException {
            // Native JS can observe the server's atomic interrupt before this
            // isolate services the corresponding steering/Stop mailbox message.
            if (cellCancellation.interrupted && _steering.isEmpty) {
              await preemption.future.asCancellable(cancellation);
            }
            cancellation.throwIfCancelled();
            if (_steering.isEmpty) rethrow;
            result = {'error': 'Tool call cancelled by steering. Side effects may have occurred; inspect state before retrying.'};
          } catch (error) {
            result = {'error': error.toString()};
          } finally {
            cellCancellation.cancel();
            _toolCancellation = null;
            _toolPreemption = null;
            link.dispose();
          }
          telemetry.observe('code', watch.elapsed);
          telemetry.add('code_cells');
          final output = interface.formatResult(call, result);
          final item = ConversationItem.toolResult(
            call,
            call.namespace?.startsWith('mcp__') == true
                ? truncateTextOutput(output)
                : output,
            isError: result.containsKey('error'),
            tools: selectedTools,
            images: images,
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
      await host?.close();
      _cancellation = null;
    }
  }
}
