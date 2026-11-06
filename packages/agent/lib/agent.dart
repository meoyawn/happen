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
import 'src/goal_context.dart';

export 'src/config.dart' show initialConfiguration;
export 'src/goals.dart' show GoalRuntime;

Future<IsolateOwner> startAgent({
  required String taskId,
  required Json config,
  required SendPort writer,
  required SendPort network,
  SendPort? clientTools,
  SendPort? goals,
  required SendPort taskTools,
  required SendPort questions,
  required int codeInterrupt,
}) => IsolateOwner.start(_agentMain, {
  ...config,
  'task_id': taskId,
  'writer': writer,
  'network': network,
  'client_tools': clientTools,
  'goals': goals,
  'task_tools': taskTools,
  'questions': questions,
  'code_interrupt': codeInterrupt,
}, service: 'agent');

Future<void> _agentMain(List<Object?> args) async {
  final actor = _Agent(jsonObject(args[1]));
  final port = ReceivePort();
  (args[0] as SendPort).send(port.sendPort);
  Future<void>? running;
  String? turnOperation;
  final reads = <String, CancellationToken>{};
  port.listen((raw) => traceIncoming(jsonObject(raw), () async {
    final request = jsonObject(raw),
        params = jsonObject(jsonObject(raw)['params']);
    final reply = request['reply'] as SendPort?;
    try {
      switch (request['method']) {
        case 'turn':
          if (running != null) {
            throw StateError('Task already has an active turn');
          }
          turnOperation = request['operation_id'] as String?;
          running = actor.turn(
            params['prompt'] as String? ?? '',
            (event) => reply?.send({'event': event}),
            compact: params['compact'] == true,
            retry: params['retry'] == true,
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
        case 'inject':
          await actor.inject(params);
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
      traceError(error);
      reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
    }
  }, service: 'agent'));
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
    if (saved['requestTools'] case final List<Object?> tools) {
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
      input.addAll(type == 'context.injected' ? items.where((item) => !input.any((existing) => existing.id == item.id)) : items);
    }
    if (type == 'model.completed') _contextState['tokens'] = sessionTokens(jsonObject(data['usage'] ?? {}));
    if (type == 'tools.updated' && data['tools'] is List) {
      _tools = (data['tools'] as List).map((tool) => ToolDefinition.fromJson(jsonObject(tool))).toList();
    }
    if (type == 'configuration.updated' && data['effort'] is String) effort = data['effort'] as String;
    final time = DateTime.parse(entry['created_at'] as String).millisecondsSinceEpoch;
    _contextState['created'] ??= time;
    _contextState['updated'] = time;
    final previousSeq = _contextState['sourceThrough'] as int? ?? 0;
    _contextState['sourceThrough'] = (entry['seq'] as int).clamp(previousSeq, 0x7fffffffffffffff);
    _contextState['windowID'] = entry['window_id'];
    for (final event in entry['session_events'] as List? ?? []) {
      _contextState['through'] = event['durable']['seq'];
    }
    return entry;
  }

  CancellationToken? _cancellation;
  CancellationToken? _workCancellation;
  Completer<void>? _toolPreemption;
  bool _accepting = false;
  final _steering = <Json>[];
  Future<void> inject(Json record) async {
    await _restore();
    _record(record);
  }
  void steer(Json message) {
    if (_accepting && _cancellation?.isCancelled == false) {
      _steering.add(message);
      _workCancellation?.cancel();
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
      '_trace': ?traceIsolateCarrier('cancel'),
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
    bool retry = false,
    Json settings = const {},
  }) async {
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    var work = _workCancellation = CancellationToken();
    final workLink = CancellationHook(cancellation, () => _workCancellation?.cancel());
    _accepting = true;
    final telemetry = Telemetry(enabled: config['telemetry'] != false);
    final total = Stopwatch()..start();
    final interface = toolInterface(config['tool_interface'] as String, settings: jsonObject(config['provider_settings']));
    ToolRuntime? host;
    var goalsEnabled = false;
    var uncachedTokensUsed = 0;
    Json? incompleteUsage;
    final turnId = settings['turnId'] as String? ?? (interface.id == 'openai' ? newUuidV7() : newId());
    void event(Json value) =>
        emit({'task_id': taskId, 'turn_id': turnId, ...value});
    Future<Json> goal(String method, [Json arguments = const {}, CancellationToken? token]) async =>
      !goalsEnabled ? <String, dynamic>{} : jsonObject(await callIsolate(config['goals'] as SendPort, method,
        {'task_id': taskId, 'arguments': {'turnId': turnId, ...arguments}}, cancellation: token ?? cancellation));
    try {
      await _restore().asCancellable(cancellation);
      if (settings['model'] != null && settings['model'] != config['model'] ||
          settings['provider'] != null &&
              settings['provider'] != config['provider']) {
        throw ArgumentError('The model and provider are fixed for this task');
      }
      final baseline = jsonObject(config['provider_settings']);
      uncachedTokensUsed = await _metadata('uncached_tokens_used') as int? ?? 0;
      goalsEnabled = config['goals'] != null && interface.id == 'openai' && baseline['goals'] != false;
      await goal('begin', {'usage': {'input_tokens': uncachedTokensUsed}, 'plan': settings['mode'] == 'plan',
        'automatic': settings['goalContinuation'] == true});
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
      host = interface.createRuntime(cwd, work);
      final persisted = await _metadata('config');
      if (persisted == null) {
        final effective = {...config}
          ..remove('writer')
          ..remove('network')
            ..remove('client_tools')
            ..remove('goals')
          ..remove('task_tools')
          ..remove('questions')
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
      var mcpSnapshot = jsonObject(await _metadata('mcp_snapshot') ?? {});
      var clientSnapshot = jsonObject(await _metadata('client_tools_snapshot') ?? {'tools': <Object?>[]});
      var persistedMcp = mcpSnapshot, persistedClient = clientSnapshot;
      final clientTools = config['client_tools'] as SendPort?;
      var mcpCatalog = mcpSnapshot, clientCatalog = clientSnapshot;
      Future<Json> readMcpCatalog([CancellationToken? token, bool revalidate = true]) async {
        final current = jsonObject(await callIsolate(network, 'mcp.catalog', {
          'task_id': taskId, 'cwd': cwd, 'revision': mcpCatalog['revision'], 'revalidate': revalidate,
        }, cancellation: token ?? work));
        if (current['unchanged'] != true) mcpCatalog = current;
        return mcpCatalog;
      }
      Future<Json> readClientCatalog([CancellationToken? token]) async {
        final current = clientTools == null ? const <String, dynamic>{'tools': <Object?>[]}
          : jsonObject(await callIsolate(clientTools, 'catalog', {
            'task_id': taskId, 'revision': clientCatalog['revision'],
          }, cancellation: token ?? work));
        if (current['unchanged'] != true) clientCatalog = current;
        return clientCatalog;
      }
      // Cache rendering for this turn's immutable snapshots, not availability.
      // Every access still checks live revisions; a revision invalidates both
      // the deferred list and the rendered runtime catalog.
      Json? describedMcp, describedClient;
      var deferredTools = <Json>[];
      List<Json>? runtimeCatalog;
      Future<List<Json>> currentDeferredCatalog(CancellationToken token, {bool revalidate = true}) async {
        await Future.wait([readMcpCatalog(token, revalidate), readClientCatalog(token)]);
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
      var skillsSnapshot = jsonObject(await _metadata('skills_state') ?? {});
      var skillsCatalog = <String, dynamic>{'skills': <Object?>[]};
      Future<Json> readSkills() async => jsonObject(await callIsolate(network, 'skills.catalog', {
          'task_id': taskId, 'cwd': cwd,
        }, cancellation: work));
      Future<void> refreshSkills([Json? current]) async {
        if (identical(current, skillsCatalog)) return;
        skillsCatalog = current ?? await readSkills();
        final next = skillContext(skillsCatalog, previous: skillsSnapshot,
          contextWindow: baseline['context_limit'] as int?);
        if (contextFingerprint(next.snapshot) == contextFingerprint(skillsSnapshot)) return;
        work.throwIfCancelled();
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
        }, cancellation: work)),
        config['global_directory'] as String, work,
      );
      final previousSnapshot = await _metadata('agents_snapshot');
      Json? snapshot = previousSnapshot is Map ? jsonObject(previousSnapshot) : null;
      final updates = <Json>[];
      void update(String type, ConversationItem item, [Json data = const {}]) =>
          updates.add({
            'type': type,
            'data': {...data, 'item': item.toJson()},
          });
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
      Json? pendingInput;
      if (settings['goalContinuation'] == true) {
        event(await _append('context.injected', {'item': settings['goalItem']}));
      } else if (!compact && !retry) {
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

      Future<void> refreshInstructions([Json? loaded]) async {
        final current = loaded ?? await readInstructions();
        if (identical(current, snapshot) || contextFingerprint(current) == contextFingerprint(snapshot)) return;
        final item = instructionUpdate(interface, current, snapshot);
        work.throwIfCancelled();
        if (item != null) {
          event(await _append('agents.updated', {'snapshot': current, 'item': item.toJson()},
            metadata: {'agents_snapshot': current}));
        }
        snapshot = current;
      }

      var usageTokens = await _metadata('context_usage') as int? ?? 0;
      var selectionRecorded = false;
      Future<void> recordSelection() async {
        if (selectionRecorded) return;
        final restoreSelection = settings['reasoningPinned'] != true && !compact && config['reasoning_updates'] == true &&
          input.any((item) => item.kind == 'configuration') &&
          !(input.lastOrNull?.kind == 'configuration' && input.last.settings['reasoning'] == selectedEffort);
        if (selectedEffort != effort || restoreSelection) {
          event(await _append('configuration.updated', {
            'effort': selectedEffort,
            'item': ConversationItem(kind: 'configuration', settings: {'reasoning': selectedEffort}).toJson(),
          }, metadata: {'effective_reasoning': selectedEffort}));
        }
        selectionRecorded = true;
      }
      Future<bool> takeSteering() async {
        cancellation.throwIfCancelled();
        if (_steering.isEmpty) return false;
        final messages = _steering.toList();
        _steering.clear();
        // Preserve input order even when steering interrupts the first refresh.
        if (pendingInput case final Json data) {
          event(await _append('input.committed', data));
          pendingInput = null;
        }
        await recordSelection();
        final entries = await callIsolate(writer, 'session.inbox.commit', {
          'ids': [for (final message in messages) message['id']],
          'effort': effort, 'reasoningUpdates': config['reasoning_updates'] == true,
        }, cancellation: cancellation) as List;
        for (final raw in entries) {
          event(_record(jsonObject(raw)));
        }
        return entries.isNotEmpty;
      }

      var usageItems = await _metadata('context_usage_items') as int? ?? 0;
      final nestedDiscovery = interface.nestedDiscovery;
      List<Json>? declaredCatalog;
      Future<void> refreshTools([List<Json>? loaded]) async {
        final deferred = loaded ?? await currentDeferredCatalog(work);
        final definitions = interface.definitionsFor(deferred);
        final modelContext = interface.modelContext(config['instructions'] as String, definitions, input);
        if (!identical(declaredCatalog, deferred)) {
          final serialized = definitions.map((tool) => tool.toJson()).toList();
          if (_tools == null || contextFingerprint(_tools!.map((tool) => tool.toJson()).toList()) != contextFingerprint(serialized)) {
            event(await _append('tools.updated', {'tools': serialized}, metadata: {'request_tools': serialized}));
          }
          declaredCatalog = deferred;
        }
        if (modelContext.isNotEmpty) {
          for (final entry in await _appendBatch([for (final item in modelContext) {
            'type': 'context.injected', 'data': {'item': item.toJson()},
          }], const {})) { event(entry); }
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
          work.throwIfCancelled();
          final entries = await _appendBatch([for (final item in updates) {
              'type': mcpChanged ? 'mcp.updated' : 'client_tools.updated',
              'data': {'item': item.toJson(), 'snapshot': mcpChanged ? mcpCatalog : clientCatalog},
            }], {'mcp_snapshot': mcpCatalog, 'client_tools_snapshot': clientCatalog});
          for (final entry in entries) { event(jsonObject(entry)); }
          persistedMcp = mcpCatalog; persistedClient = clientCatalog;
        }
        mcpSnapshot = mcpCatalog; clientSnapshot = clientCatalog;
      }

      var initialContext = true;
      Future<List<Object>> readContext({bool pureContinuation = false}) =>
          Future.wait<Object>([
            pureContinuation ? Future.value(snapshot!) : readInstructions(),
            pureContinuation ? Future.value(skillsCatalog) : readSkills(),
            currentDeferredCatalog(work, revalidate: !pureContinuation),
          ]);
      Future<void> refreshContext([List<Object>? loaded]) async {
        // Independent live reads overlap; commits retain their protocol order.
        // No debounce/TTL: edits made by the preceding tool are visible now.
        final current = loaded ?? await readContext();
        work.throwIfCancelled();
        if (initialContext) {
          if (interface.developerContextFirst) {
            await refreshTools(current[2] as List<Json>);
            await refreshSkills(current[1] as Json);
          }
          final next = current[0] as Json;
          final instructions = instructionUpdate(interface, next, snapshot);
          final initial = [
            if (instructions != null) {'type': 'agents.updated', 'data': {'snapshot': next, 'item': instructions.toJson()}},
            ...updates,
          ];
          if (initial.isNotEmpty) {
            work.throwIfCancelled();
            for (final entry in await _appendBatch(initial, {
              'effective_reasoning': effort, 'current_cwd': cwd, 'agents_snapshot': next,
            })) { event(entry); }
          }
          snapshot = next;
          initialContext = false;
        }
        await refreshInstructions(current[0] as Json);
        await refreshSkills(current[1] as Json);
        await refreshTools(current[2] as List<Json>);
        if (pendingInput case final Json data) {
          event(await _append('input.committed', data));
          pendingInput = null;
        }
        await recordSelection();
      }
      String? assistantMessageID;
      final committedOutputIDs = <String>{};
      var outputOrdinal = 0;
      Future<void> countUsage(ModelUsage usage, {CancellationToken? token}) async {
        uncachedTokensUsed += (usage.inputTokens - usage.cachedInputTokens).clamp(0, 0x7fffffffffffffff) + usage.outputTokens;
        telemetry.add('input_tokens', usage.inputTokens);
        telemetry.add('cached_input_tokens', usage.cachedInputTokens);
        telemetry.add('cache_write_tokens', usage.cacheWriteTokens);
        telemetry.add('output_tokens', usage.outputTokens);
        await goal('usage', {'usage': {'input_tokens': uncachedTokensUsed}, 'lastUsage': usage.toJson()}, token);
      }
      // Tool changes already have their own durable snapshot. The system
      // baseline is constant during this turn; record it on the first request.
      var instructionsRecorded = false;
      Future<Json> networkCall(String method, [CancellationToken? token]) async {
        final active = token ?? work;
        active.throwIfCancelled();
        Object? receiveFailure;
        StackTrace? receiveStack;
        void fail(Object error, StackTrace stack) {
          receiveFailure = error;
          receiveStack = stack;
          active.cancel();
        }
        var received = Future<void>.value();
        if (method == 'respond') {
          committedOutputIDs.clear();
          outputOrdinal = 0;
          assistantMessageID = 'msg_${interface.id == 'openai' ? newUuidV7() : newId()}';
          // Persist the baseline before the first request. Later starts can
          // commit while the request travels; stream events and executable
          // calls still wait for their durable admission.
          received = _append('model.started', {
            'assistantMessageID': assistantMessageID,
            if (!instructionsRecorded) 'instructions': request().instructions,
          }).then<void>(event).catchError(fail);
          if (!instructionsRecorded) await received;
          instructionsRecorded = true;
        }
        try {
          return jsonObject(await callIsolate(
            network,
            method,
            {'provider': config['provider'], ...request().toJson()},
            onEvent: (value) {
              if (active.isCancelled && value['type'] != 'model.incomplete' || method != 'respond' && value['type'] == 'model.output') return;
              received = received.then((_) async {
                if (receiveFailure != null) return;
                try {
                  if (value['type'] == 'model.incomplete') {
                    incompleteUsage = jsonObject(value['incompleteUsage']);
                    // Accepted terminal usage drains before turn settlement, even
                    // when an interrupt races the received provider failure.
                    await countUsage(ModelUsage.fromJson(jsonObject(value['usage'])), token: _lifetime);
                  } else if (value['type'] == 'model.recovery') {
                    final acknowledgement = value['ack'] as SendPort;
                    try {
                      active.throwIfCancelled();
                      event(await _append('context.injected', {'item': value['item']}));
                      acknowledgement.send({'result': null});
                    } catch (error) {
                      acknowledgement.send({'error': 'Unable to persist recovery context'});
                      rethrow;
                    }
                  } else if (value['type'] == 'model.output') {
                    final item = jsonObject(value['item']);
                    if (!committedOutputIDs.add(requiredString(item, 'id'))) return;
                    event(await _append('model.output', {
                      'assistantMessageID': assistantMessageID, 'ordinal': outputOrdinal, 'item': item,
                    }));
                    outputOrdinal += (item['content'] as List? ?? []).length;
                  } else {
                    event({...value,
                      if (method == 'respond') 'assistantMessageID': assistantMessageID,
                      if (method == 'compact' && value['type'] == 'text.delta') 'type': 'compaction.delta',
                    });
                  }
                } catch (error, stack) {
                  fail(error, stack);
                }
              });
            },
            timeout: null,
            cancellation: active,
          ));
        } finally {
          // Finish accepted item commits before admitting steering or ending the turn.
          await received;
          if (receiveFailure != null) Error.throwWithStackTrace(receiveFailure!, receiveStack!);
        }
      }

      Future<String> searchWeb(Object? commands, CancellationToken token) async =>
          await callIsolate(network, 'web.search', {
            'provider': config['provider'],
            ...request().toJson(),
            'commands': commands,
          }, timeout: null, cancellation: token) as String;

      Future<void> compactContext(String reason) async {
        work.throwIfCancelled();
        event(await _append('compaction.started', {'reason': reason}));
        final inputGoalIds = input.where(isUserGoalInstruction).map((item) => item.id).toSet();
        final CompactionResult result;
        try {
          result = CompactionResult.fromJson(await networkCall('compact'));
          work.throwIfCancelled();
        } on CancelledException {
          event(await _append('compaction.cancelled', {'reason': reason}));
          rethrow;
        }
        await countUsage(result.usage);
        final freshSkills = skillContext(skillsCatalog,
          contextWindow: baseline['context_limit'] as int?);
        final restored = restoreContext(
          result.context,
          input,
          snapshot!,
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
          prefix: interface.modelContext(config['instructions'] as String, request().tools, const []),
          skills: freshSkills.item,
        );
        final replacementIds = restored.map((item) => item.id).toSet();
        restored.addAll(input.where((item) => isUserGoalInstruction(item) &&
          !inputGoalIds.contains(item.id) && !replacementIds.contains(item.id)));
        final size = estimateTokens(restored) +
          (restored.any((item) => item.native['harness']?['context'] == 'model') ? 0 : request().instructions.length ~/ 3);
        final entry = await _append(
          'context.compacted',
          {
            'input': restored.map((v) => v.toJson()).toList(),
            'summary': result.summary,
            'usage': result.usage.toJson(),
            'observed_usage': ?result.observedUsage,
            'reason': reason,
            'skills_state': freshSkills.snapshot,
          },
          metadata: {
            'context_usage': size,
            'context_usage_items': restored.length,
            'skills_state': freshSkills.snapshot,
            'uncached_tokens_used': uncachedTokensUsed,
          },
        );
        skillsSnapshot = freshSkills.snapshot;
        usageTokens = size;
        usageItems = input.length;
        telemetry.add('compactions');
        event(entry);
      }

      Future<void> finish(String text) async {
        await goal('end');
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

      var manualCompaction = compact;
      var overflowRecovered = false;
      List<Object>? prefetchedContext;
      while (true) {
        try {
          cancellation.throwIfCancelled();
          work.throwIfCancelled();
          await takeSteering();
          final loaded = prefetchedContext;
          prefetchedContext = null;
          await refreshContext(loaded);
          work.throwIfCancelled();
          await takeNotifications();
          if (manualCompaction) {
            await compactContext('manual');
            await finish('Context compacted. Full history remains available.');
            return;
          }
          final estimate = usageTokens > 0 && usageItems <= input.length
              ? usageTokens + estimateTokens(input.skip(usageItems))
              : estimateTokens(input) +
                  (input.any((item) => item.native['harness']?['context'] == 'model') ? 0 : request().instructions.length ~/ 3);
          if (estimate >=
              (baseline['context_limit'] as int) -
                  (baseline['compaction_headroom'] as int)) {
            await compactContext('threshold');
          }
          final inferenceTools = deferredTools;
          final modelTime = Stopwatch()..start();
          final ModelReply reply;
          try {
            reply = ModelReply.fromJson(await networkCall('respond'));
          } on RemoteFailure catch (error) {
            if (error.code == 'context_overflow' && !overflowRecovered) {
              overflowRecovered = true;
              await compactContext('overflow');
              continue;
            }
            rethrow;
          }
          work.throwIfCancelled();
          telemetry.observe('model', modelTime.elapsed);
          telemetry.add('model_requests');
          await countUsage(reply.usage);
          for (final item in reply.output) {
            for (final part in item.content) {
              if (part['type'] == 'reasoning') await goal('item', {'item': {'type': 'reasoning', 'summary': [part['text'] ?? '']}});
              if (part['type'] == 'text') await goal('item', {'item': {'type': 'agentMessage', 'text': part['text'] ?? '',
                'phase': reply.calls.isEmpty ? 'final_answer' : 'commentary'}});
            }
          }
          if (reply.output.isEmpty && reply.endTurn) await goal('item', {'item': {'type': 'agentMessage', 'text': '', 'phase': 'final_answer'}});
          final nextUsage = reply.usage.contextTokens;
          final nextItems = input.length + reply.output.where((item) => !committedOutputIDs.contains(item.id)).length;
          final calls = reply.calls;
          Json toolStarted(ToolCall call) => {
            'type': 'tool.started', 'data': {
              'call_id': call.id, 'name': call.name,
              if (call.namespace != null) 'namespace': call.namespace,
              'input': call.input,
            },
          };
          final nativeSearch = calls.isNotEmpty && nestedDiscovery != null &&
            calls.every((call) => call.format == 'search' && call.name == nestedDiscovery.name);
          final searchEvents = <Json>[];
          if (nativeSearch) {
            // Searching the prepared router is pure. Commit its result with
            // the model response instead of crossing the writer twice.
            for (final call in calls) {
              work.throwIfCancelled();
              final watch = Stopwatch()..start();
              Json result;
              try {
                result = interface.search(inferenceTools, jsonObject(jsonDecode(call.input)), native: true);
              } catch (error) {
                result = {'error': error.toString()};
              }
              telemetry.observe('code', watch.elapsed);
              telemetry.add('code_cells');
              searchEvents.addAll([
                toolStarted(call),
                {'type': 'tool.completed', 'data': {'item': interface.resultItem(call, result).toJson(), 'values': values}},
              ]);
            }
          }
          // Admit the first call atomically with the model output. Host side
          // effects still start only after this transaction is durable.
          final committed = _appendBatch([
            {'type': 'model.completed', 'data': {...reply.toJson(), 'assistantMessageID': assistantMessageID,
              if (committedOutputIDs.isNotEmpty) ...{
                'committed_output_ids': committedOutputIDs.toList(), 'ordinal': outputOrdinal,
              }}},
            if (nativeSearch) ...searchEvents
            else if (calls.isNotEmpty) toolStarted(calls.first),
          ], {'context_usage': nextUsage, 'context_usage_items': nextItems, 'uncached_tokens_used': uncachedTokensUsed,
            if (nativeSearch) 'values': values}).then((entries) {
              for (final entry in entries) { event(entry); }
              return entries;
            });
          if (nativeSearch) {
            // Pure discovery keeps the instruction/skill snapshot. MCP watches
            // and server notifications still update the live router; host calls
            // force filesystem revalidation at the next model boundary.
            final ready = await Future.wait<Object>([committed, readContext(pureContinuation: true)]);
            prefetchedContext = ready[1] as List<Object>;
          } else {
            await committed;
          }
          usageTokens = nextUsage;
          usageItems = nextItems;
          if (nativeSearch) {
            await goal('account');
            continue;
          }
          if (calls.isEmpty) {
            if (_steering.isNotEmpty) continue;
            if (await takeNotifications()) continue;
            if (!reply.endTurn) continue;
            await finish(reply.text);
            return;
          }
          for (final call in calls) {
            cancellation.throwIfCancelled();
            if (call.id != calls.first.id) {
              final started = toolStarted(call);
              event(await _append('tool.started', jsonObject(started['data'])));
            }
            final watch = Stopwatch()..start();
            Json result;
            var images = <Json>[];
            var executionFailed = false;
            final cellCancellation = CodeCancellationToken.shared(config['code_interrupt'] as int);
            final preemption = _toolPreemption = Completer<void>();
            final link = CancellationHook(work, cellCancellation.cancel);
            try {
              if (_steering.isNotEmpty) throw const CancelledException();
              result = await host!.execute(call, ToolExecution(
                catalog: currentRuntimeCatalog,
                cancellation: cellCancellation,
                values: values,
                notify: (result) async {
                  cellCancellation.throwIfCancelled();
                  final item = interface.resultItem(call, result);
                  event(await _append('tool.notified', {'item': item.toJson()}));
                },
                call: (name, arguments, {required cancellation}) async {
                  cancellation.throwIfCancelled();
                  final nested = interface.isCodeCall(call);
                  final id = nested ? newId() : call.id;
                  if (nested) {
                    event(await _append('host_tool.started', {
                      'id': id, 'parent_call_id': call.id, 'name': name, 'arguments': arguments,
                    }));
                  }
                  try {
                    cancellation.throwIfCancelled();
                    final Object? output;
                    final service = interface.services[name];
                    if (nestedDiscovery != null && name == nestedDiscovery.name) {
                      output = interface.search(
                        // Native search uses the router snapshot prepared for
                        // this inference, as in Codex. Nested discovery can run
                        // after another host call and must refresh live tools.
                        call.format == 'search' ? inferenceTools : await currentDeferredCatalog(cancellation),
                        jsonObject(arguments),
                        native: call.format == 'search',
                      );
                    } else if (service == 'question.ask' || service == 'question.ask_async') {
                      output = await callIsolate(config['questions'] as SendPort, service!.substring(9), {
                        'task_id': taskId, 'call_id': id, 'arguments': arguments,
                      }, timeout: null, cancellation: cancellation);
                      if (jsonObject(output)['rejected'] == true) {
                        cancel();
                        cancellation.throwIfCancelled();
                      }
                    } else if (service == 'skills.read') {
                      output = await callIsolate(network, 'skills.read', {
                        ...jsonObject(arguments), 'task_id': taskId, 'cwd': cwd,
                      }, cancellation: cancellation);
                    } else if (service == 'web.search') {
                      output = await searchWeb(arguments, cancellation);
                    } else if (service == 'image.generate') {
                      Json? started;
                      var completed = false;
                      Future<void> notifications = Future.value();
                      try {
                      output = await callIsolate(network, 'image.generate', {
                        'provider': config['provider'], ...request().toJson(),
                        'arguments': arguments, 'call_id': id, 'turn_id': turnId,
                      }, timeout: null, cancellation: cancellation, onEvent: (notification) {
                        final data = jsonObject(notification['data']);
                        if (notification['type'] == 'native.item.started') started = data;
                        if (notification['type'] == 'native.item.completed') completed = true;
                        notifications = notifications.then((_) async {
                          if (notification['type'] == 'native.item.completed') await callIsolate(writer, 'native.item.queue', data);
                          else event(await _append('native.item.started', data));
                        });
                        unawaited(notifications.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
                      });
                      } finally {
                        await notifications;
                        // Cancellation closes the request mailbox before the
                        // network worker can reply. Close only the item actually
                        // announced to this caller, before its terminal commit.
                        if (started != null && !completed) await callIsolate(writer, 'native.item.queue', {
                          ...started!, 'item': {...jsonObject(started!['item']), 'status': 'failed'},
                          'canonicalItem': {...jsonObject(started!['canonicalItem']), 'status': 'failed'},
                          'completedAtMs': DateTime.now().millisecondsSinceEpoch,
                        });
                      }
                    } else if (service?.startsWith('goal.') == true) {
                      output = await goal(service!.substring(5), jsonObject(arguments), cancellation);
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
                          'task_id': taskId, 'cwd': cwd,
                          'name': name,
                          'arguments': arguments,
                        }, cancellation: cancellation),
                      )..remove('_meta');
                    } else if (service != null) {
                      output = await callIsolate(network, 'mcp.resources', {
                        'task_id': taskId, 'cwd': cwd,
                        'method': service,
                        'arguments': arguments,
                      }, cancellation: cancellation);
                    } else {
                      output = await callIsolate(config['task_tools'] as SendPort, 'call', {
                        'task_id': taskId, 'provider': interface.id, 'cwd': cwd,
                        'name': name, 'arguments': arguments, 'call_id': id, 'turn_id': turnId,
                      }, timeout: null, cancellation: cancellation);
                    }
                    await goal('toolFinished', {'name': name, 'outcome': output is Map && output['isError'] == true ? 'unsuccessful' : 'success'}, cancellation);
                    if (nested) {
                      event(await _append('host_tool.completed', {
                        'id': id, 'parent_call_id': call.id, 'name': name, 'output': output,
                      }));
                    }
                    return output;
                  } catch (error) {
                    if (nested) {
                      event(await _append('host_tool.completed', {
                        'id': id, 'parent_call_id': call.id, 'name': name,
                        if (error is CancelledException) 'cancelled': true,
                        'error': error.toString(),
                      }));
                    }
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
                final preparationLink = CancellationHook(work, preparation.cancel);
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
              result = interface.id == 'openai' && call.namespace == 'clock' && call.name == 'sleep'
                ? {'output': 'Wall time: ${(watch.elapsedMicroseconds / 1000000).toStringAsFixed(4)} seconds\nSleep interrupted by new input.'}
                : {'error': 'Tool call cancelled by steering. Side effects may have occurred; inspect state before retrying.'};
            } catch (error) {
              // A returned script error is Completed { success: false } in
              // Codex; an exception escaping the invoked handler is Failed.
              executionFailed = true;
              result = {'error': error.toString()};
            } finally {
              if (!host!.hasRunningCells) cellCancellation.cancel();
              _toolPreemption = null;
              link.dispose();
            }
            telemetry.observe('code', watch.elapsed);
            await goal('toolFinished', {'name': call.name, 'outcome': executionFailed ? 'executionFailed' : result['error'] == null ? 'success' : 'unsuccessful'});
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
        } on CancelledException {
          cancellation.throwIfCancelled();
          if (_steering.isEmpty) rethrow;
          await host?.close();
          prefetchedContext = null;
          work = _workCancellation = CancellationToken();
          host = interface.createRuntime(cwd, work);
          manualCompaction = false;
        }
      }
    } catch (error) {
      telemetry.observe('turn', total.elapsed);
      final code = switch (error) {RemoteFailure(:final code) => code, ModelFailure(:final code) => code, _ => null};
      await goal('end', {'reason': cancellation.isCancelled ? 'cancelled'
        : {'usage_limit', 'usage_limit_reached'}.contains(code) ? 'usageLimit' : 'error'}, _lifetime);
      event(
        await _append(
          cancellation.isCancelled ? 'turn.cancelled' : 'turn.failed',
          {'error': error.toString(), 'telemetry': telemetry.snapshot(), 'incompleteUsage': ?incompleteUsage},
          metadata: {'status': 'idle', if (incompleteUsage != null) 'uncached_tokens_used': uncachedTokensUsed},
        ),
      );
    } finally {
      _accepting = false;
      _steering.clear();
      cancellation.cancel();
      await host?.close();
      workLink.dispose();
      _workCancellation = null;
      _cancellation = null;
    }
  }
}
