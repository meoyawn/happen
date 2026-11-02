import 'dart:async';
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
  String? turnOperation;
  final reads = <String, CancellationToken>{};
  port.listen((raw) async {
    final request = jsonObject(raw),
        params = jsonObject(jsonObject(raw)['params']);
    final reply = request['reply'] as SendPort?;
    try {
      switch (request['method']) {
        case 'turn':
        case 'prepare':
          if (running != null) {
            throw StateError('Task already has an active turn');
          }
          turnOperation = request['operation_id'] as String?;
          running = actor.turn(
            params['prompt'] as String? ?? '',
            (event) => reply?.send({'event': event}),
            compact: params['compact'] == true,
            prepareOnly: request['method'] == 'prepare',
            settings: jsonObject(params['settings'] ?? {}),
          );
          try {
            await running;
            reply?.send({'result': null});
          } finally {
            running = null;
            turnOperation = null;
          }
        case 'context':
          final id = request['operation_id'] as String;
          final cancellation = reads[id] = CancellationToken();
          try {
            reply?.send({'result': await actor.context(cancellation)});
          } finally {
            reads.remove(id);
            cancellation.cancel();
          }
        case 'cancel':
          final operation = params['operation_id'];
          if (operation == null || operation == turnOperation) {
            actor.cancel();
          } else {
            reads[operation]?.cancel();
          }
          reply?.send({'result': null});
        case 'steer':
          actor.steer(params);
          reply?.send({'result': null});
        case 'close':
          actor.cancel();
          await running;
          actor.dispose();
          for (final read in reads.values) { read.cancel(); }
          reply?.send({'result': null});
          port.close();
        default:
          throw StateError('Unknown agent operation');
      }
    } catch (error) {
      reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
    }
  });
}

class _Agent {
  _Agent(this.config);
  final Json config;
  final _lifetime = CancellationToken();
  Future<void>? _restoring;
  List<ConversationItem> input = [];
  List<ToolDefinition>? _tools;
  Json _contextState = {};
  String get effort => _contextState['effectiveReasoning'] as String? ?? config['provider_settings']['reasoning'] as String;
  set effort(String value) => _contextState['effectiveReasoning'] = value;

  Future<void> _restore() => _restoring ??= () async {
    final saved = jsonObject(await callIsolate(writer, 'context', {}, cancellation: _lifetime));
    input = (saved['input'] as List).map((item) => ConversationItem.fromJson(jsonObject(item))).toList();
    _contextState = {...saved}..remove('input');
    if (saved['requestTools'] case final List tools) {
      _tools = tools.map((tool) => ToolDefinition.fromJson(jsonObject(tool))).toList();
    }
  }();

  ModelRequest request() {
    final interface = toolInterface(config['tool_interface'] as String, settings: jsonObject(config['provider_settings']));
    return ModelRequest(
      taskId: taskId, model: config['model'] as String,
      instructions: config['instructions'] as String,
      input: input, tools: _tools ?? interface.definitions,
      settings: jsonObject(config['provider_settings']), effectiveReasoning: effort,
    );
  }

  Future<Json> context(CancellationToken cancellation) async {
    await _restore().asCancellable(cancellation);
    cancellation.throwIfCancelled();
    final current = request();
    final counts = <String, int>{};
    for (final item in current.input) {
      final kind = item.kind == 'message' ? (item.native['harness'] == null ? item.role! : 'context') : item.kind;
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
    return {
      ..._contextState,
      'sessionID': taskId, 'model': {'providerID': config['provider'], 'id': current.model},
      'limit': current.settings['context_limit'],
      'instructions': current.instructions, 'tools': current.tools.map((tool) => tool.toJson()).toList(),
      'settings': current.settings, 'effectiveReasoning': current.effectiveReasoning,
      'input': current.input.map((item) => item.toJson()).toList(),
      'inputCount': current.input.length, 'counts': counts,
    };
  }

  void dispose() => _lifetime.cancel();

  Json _record(Json entry) {
    final type = entry['type'] as String, data = jsonObject(entry['data']);
    final items = modelContextItems(type, data);
    if (type == 'context.compacted') {
      input = items.toList();
      _contextState['tokens'] = null;
    } else {
      input.addAll(items);
    }
    if (type == 'model.completed') _contextState['tokens'] = sessionTokens(jsonObject(data['usage'] ?? {}));
    if (type == 'tools.updated' && data['tools'] is List) {
      _tools = (data['tools'] as List).map((tool) => ToolDefinition.fromJson(jsonObject(tool))).toList();
    }
    if (type == 'configuration.updated' && data['effort'] is String) effort = data['effort'] as String;
    final time = DateTime.parse(entry['created_at'] as String).millisecondsSinceEpoch;
    _contextState['created'] ??= time;
    _contextState['updated'] = time;
    _contextState['sourceThrough'] = entry['seq'];
    _contextState['windowID'] = entry['window_id'];
    for (final event in entry['session_events'] as List? ?? []) {
      _contextState['through'] = event['durable']['seq'];
    }
    return entry;
  }

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
  }) async => _record(jsonObject(
    await callIsolate(writer, 'append', {
      'type': type,
      'data': data,
      'metadata': metadata,
    }),
  ));

  Future<List<Json>> _appendBatch(List<Json> events, Json metadata) async =>
      (await callIsolate(writer, 'append_batch', {'events': events, 'metadata': metadata}) as List)
        .map((entry) => _record(jsonObject(entry))).toList();

  Future<void> turn(
    String prompt,
    void Function(Json) emit, {
    bool compact = false,
    bool prepareOnly = false,
    Json settings = const {},
  }) async {
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    _accepting = !compact;
    final telemetry = Telemetry(enabled: config['telemetry'] != false);
    final total = Stopwatch()..start();
    final interface = toolInterface(config['tool_interface'] as String, settings: jsonObject(config['provider_settings']));
    ToolRuntime? host;
    final turnId = newId();
    void event(Json value) =>
        emit({'task_id': taskId, 'turn_id': turnId, ...value});
    try {
      await _restore().asCancellable(cancellation);
      if (settings['model'] != null && settings['model'] != config['model'] ||
          settings['provider'] != null &&
              settings['provider'] != config['provider']) {
        throw ArgumentError('The model and provider are fixed for this task');
      }
      final baseline = jsonObject(config['provider_settings']);
      final previousEffort = effort;
      final selectedEffort = settings['reasoning'] as String? ?? previousEffort;
      if (selectedEffort != previousEffort && config['reasoning_updates'] != true) {
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
        'settings': {...baseline, 'reasoning': selectedEffort},
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
        }
      }

      var mcpSnapshot = jsonObject(await _metadata('mcp_snapshot') ?? {});
      var clientSnapshot = jsonObject(await _metadata('client_tools_snapshot') ?? {'tools': []});
      var persistedMcp = mcpSnapshot, persistedClient = clientSnapshot;
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
        final current = clientTools == null ? const <String, dynamic>{'tools': []}
          : jsonObject(await callIsolate(clientTools, 'catalog', {
            'task_id': taskId, 'revision': clientCatalog['revision'],
          }, cancellation: token ?? cancellation));
        if (current['unchanged'] != true) clientCatalog = current;
        return clientCatalog;
      }
      // Cache rendering for this turn's immutable snapshots, not availability.
      // Every access still checks live revisions; a revision invalidates both
      // the deferred list and the rendered runtime catalog.
      Json? describedMcp, describedClient;
      var deferredTools = <Json>[];
      List<Json>? runtimeCatalog;
      Future<List<Json>> currentDeferredCatalog(CancellationToken token) async {
        await Future.wait([readMcpCatalog(token), readClientCatalog(token)]);
        if (!identical(describedMcp, mcpCatalog) || !identical(describedClient, clientCatalog)) {
          deferredTools = deferredCatalog(mcpCatalog, clientCatalog);
          describedMcp = mcpCatalog; describedClient = clientCatalog;
          runtimeCatalog = null;
        }
        return deferredTools;
      }
      Future<List<Json>> currentRuntimeCatalog(CancellationToken token) async {
        final deferred = await currentDeferredCatalog(token);
        return runtimeCatalog ??= [...interface.hostCatalogFor(deferred), ...interface.externalCatalog(deferred)];
      }
      await currentDeferredCatalog(cancellation);
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
      }

      Future<Json> readInstructions() async => loadAgentsMd(
        jsonObject(await callIsolate(network, 'agents.repository', {
          'task_id': taskId, 'cwd': cwd,
        }, cancellation: cancellation)),
        config['global_directory'] as String, cancellation,
      );
      if (interface.developerContextFirst) await refreshSkills();
      var snapshot = await readInstructions();
      final previousSnapshot = await _metadata('agents_snapshot');
      final updates = <Json>[];
      void update(String type, ConversationItem item, [Json data = const {}]) =>
          updates.add({
            'type': type,
            'data': {...data, 'item': item.toJson()},
          });
      if (instructionUpdate(interface, snapshot, previousSnapshot is Map ? jsonObject(previousSnapshot) : null)
          case final ConversationItem item) {
        update('agents.updated', item, {'snapshot': snapshot});
      }
      final environment = interface.environmentContext(cwd, replacement: savedCwd != null);
      final previousEnvironment = input.where((item) => item.native['harness']?['context'] == 'environment').lastOrNull;
      if (savedCwd == null || previousCwd != cwd || interface.developerContextFirst && previousEnvironment?.text != environment.text) {
        update('environment.updated', environment, {'cwd': cwd});
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
      if (selectedEffort != previousEffort) {
        update(
          'configuration.updated',
          ConversationItem(
            kind: 'configuration',
            settings: {'reasoning': selectedEffort},
          ),
          {'effort': selectedEffort},
        );
      }
      Json? pendingInput;
      if (!compact && (!prepareOnly || prompt.isNotEmpty)) {
        pendingInput = {
          'item': ConversationItem.user(prompt, attachments: settings['attachments']).toJson(),
          if (settings['message_id'] != null)
            'message_id': settings['message_id'],
          if (settings['sent_at'] != null) 'sent_at': settings['sent_at'],
        };
      } else if (selectedEffort != previousEffort) {
        pendingInput = {
          'item': ConversationItem.text(
            'user',
            'Apply the updated settings and compact the current context.',
          ).toJson(),
        };
      }

      Future<void> refreshInstructions() async {
        final current = await readInstructions();
        if (contextFingerprint(current) == contextFingerprint(snapshot)) return;
        final item = instructionUpdate(interface, current, snapshot);
        cancellation.throwIfCancelled();
        if (item != null) {
          event(await _append('agents.updated', {'snapshot': current, 'item': item.toJson()},
            metadata: {'agents_snapshot': current}));
        }
        snapshot = current;
      }

      var usageTokens = await _metadata('context_usage') as int? ?? 0;
      Future<bool> takeSteering() async {
        cancellation.throwIfCancelled();
        if (_steering.isEmpty) return false;
        final messages = _steering.toList();
        _steering.clear();
        final updates = <Json>[];
        var nextEffort = effort;
        for (final message in messages) {
          if (message['reasoning'] case final String selected when selected != nextEffort) {
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
            nextEffort = selected;
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
        final entries = await _appendBatch(updates, {'effective_reasoning': nextEffort});
        for (final raw in entries) {
          final entry = jsonObject(raw);
          event(entry);
        }
        return true;
      }

      var usageItems = await _metadata('context_usage_items') as int? ?? 0;
      final nestedDiscovery = interface.nestedDiscovery;
      List<Json>? declaredCatalog;
      Future<void> refreshTools() async {
        final deferred = await currentDeferredCatalog(cancellation);
        if (!identical(declaredCatalog, deferred)) {
          final serialized = interface.definitionsFor(deferred).map((tool) => tool.toJson()).toList();
          if (_tools == null || contextFingerprint(_tools!.map((tool) => tool.toJson()).toList()) != contextFingerprint(serialized)) {
            event(await _append('tools.updated', {'tools': serialized}, metadata: {'request_tools': serialized}));
          }
          declaredCatalog = deferred;
        }
        final mcpChanged = !identical(mcpCatalog, mcpSnapshot) && contextFingerprint(mcpCatalog) != contextFingerprint(mcpSnapshot);
        final clientChanged = !identical(clientCatalog, clientSnapshot) && contextFingerprint(clientCatalog) != contextFingerprint(clientSnapshot);
        final hasContext = input.any((item) => ['mcp', 'client_tools', 'tool_catalog'].contains(item.native['harness']?['context']));
        if (!mcpChanged && !clientChanged && hasContext) return;
        final text = interface.catalogContext(deferred,
          hasContext ? deferredCatalog(mcpSnapshot, clientSnapshot) : null);
        final updates = <ConversationItem>[
          if (text != null) ConversationItem(role: 'developer', content: [{'type': 'text', 'text': text}],
            native: {'harness': {'context': 'tool_catalog'}}),
        ];
        if (updates.isNotEmpty) {
          cancellation.throwIfCancelled();
          final entries = await _appendBatch([for (final item in updates) {
              'type': mcpChanged ? 'mcp.updated' : 'client_tools.updated',
              'data': {'item': item.toJson(), 'snapshot': mcpChanged ? mcpCatalog : clientCatalog},
            }], {'mcp_snapshot': mcpCatalog, 'client_tools_snapshot': clientCatalog});
          for (final entry in entries) { event(jsonObject(entry)); }
          persistedMcp = mcpCatalog; persistedClient = clientCatalog;
        }
        mcpSnapshot = mcpCatalog; clientSnapshot = clientCatalog;
      }

      if (interface.developerContextFirst) await refreshTools();
      if (updates.isNotEmpty) {
        cancellation.throwIfCancelled();
        final committed = await _appendBatch(updates, {
          'effective_reasoning': selectedEffort, 'current_cwd': cwd, 'agents_snapshot': snapshot,
        });
        for (final entry in committed) { event(entry); }
      }

      Future<void> refreshContext() async {
        await refreshInstructions();
        await refreshSkills();
        await refreshTools();
        if (pendingInput case final Json data) {
          event(await _append('input.committed', data));
          pendingInput = null;
        }
      }
      String? assistantMessageID;
      Future<Json> networkCall(String method, [CancellationToken? token]) async {
        final active = token ?? cancellation;
        active.throwIfCancelled();
        if (method == 'respond') {
          assistantMessageID = 'msg_${newId()}';
          event(await _append('model.started', {
            'assistantMessageID': assistantMessageID,
            'instructions': request().instructions,
            'tools': request().tools.map((tool) => tool.toJson()).toList(),
          }));
        }
        return jsonObject(
          await callIsolate(
            network,
            method,
            {'provider': config['provider'], ...request().toJson()},
            onEvent: (value) {
              if (!active.isCancelled) { event({...value,
                if (method == 'respond') 'assistantMessageID': assistantMessageID,
                if (method == 'compact' && value['type'] == 'text.delta') 'type': 'compaction.delta',
              }); }
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
          catalogContext: interface.catalogContext,
          instructionContext: interface.instructionContext,
          environmentContext: interface.environmentContext,
          developerContextFirst: interface.developerContextFirst,
          skills: freshSkills.item,
        );
        final size =
            estimateTokens(restored) +
            request().instructions.length ~/ 3;
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
              'agents_snapshot': snapshot,
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
        }
        return notices.isNotEmpty;
      }

      if (prepareOnly) {
        await refreshContext();
        return;
      }
      if (compact) {
        await refreshContext();
        await compactContext('manual');
        await finish('Context compacted. Full history remains available.');
        return;
      }

      var overflowRecovered = false;
      while (true) {
        cancellation.throwIfCancelled();
        await refreshContext();
        await takeSteering();
        await takeNotifications();
        final estimate = usageTokens > 0 && usageItems <= input.length
            ? usageTokens + estimateTokens(input.skip(usageItems))
            : estimateTokens(input) +
                  request().instructions.length ~/ 3;
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
        final nextUsage = reply.usage.contextTokens;
        final nextItems = input.length + reply.output.length;
        event(
          await _append(
            'model.completed',
            {...reply.toJson(), 'assistantMessageID': assistantMessageID},
            metadata: {
              'context_usage': nextUsage,
              'context_usage_items': nextItems,
            },
          ),
        );
        usageTokens = nextUsage;
        usageItems = nextItems;
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
          final cellCancellation = CodeCancellationToken.shared(config['code_interrupt'] as int);
          _toolCancellation = cellCancellation;
          final preemption = _toolPreemption = Completer<void>();
          final link = CancellationHook(cancellation, cellCancellation.cancel);
          try {
            if (_steering.isNotEmpty) throw const CancelledException();
            result = await host.execute(call, ToolExecution(
              catalog: currentRuntimeCatalog,
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
                  if (nestedDiscovery != null && name == nestedDiscovery.name) {
                    output = interface.search(
                      await currentDeferredCatalog(cancellation), jsonObject(arguments),
                    );
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
          final item = interface.resultItem(call, result, images: images);
          event(
            await _append(
              'tool.completed',
              {'item': item.toJson(), 'values': values},
              metadata: {'values': values},
            ),
          );
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
