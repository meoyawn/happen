import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:code_mode/code_mode.dart' show truncateTokenText;
import 'package:protocol/protocol.dart';

import 'records.dart';
import 'responses.dart';
import 'catalog.dart';
import 'model_catalog.dart';
import 'web_search.dart';
import 'image_generation.dart' as image_generation;

class OpenAIProvider implements ModelProvider {
  OpenAIProvider(this.client, {this.catalog});
  final ResponsesClient client;
  final GptCatalog? catalog;
  GptModel modelInfo(String id) => catalog?.model(id) ?? GptModel(id);
  String get defaultModel => catalog?.defaultModel ?? defaultGptModel;
  @override
  String get id => 'openai';
  @override
  String newTaskId() => newUuidV7();
  @override
  List<String> get additionalUserSkillRoots => const ['.codex/skills/.system'];

  Future<Json> generateImage(ModelRequest request, Json arguments, {
    required String outputRoot, required String callId, required String turnId, required CancellationToken cancellation,
    ToolItemEvent? onItem,
  }) {
    _validate(request);
    if (request.settings['image_generation'] != true) throw const ModelFailure('image_generation_disabled', 'Image generation is not enabled for this provider');
    return image_generation.generateImage(request, arguments, send: client.image, outputRoot: outputRoot,
      callId: callId, turnId: turnId, cancellation: cancellation, onItem: onItem);
  }

  @override
  Future<String> webSearch(
    ModelRequest request,
    Json commands, {
    required CancellationToken cancellation,
    String? callId,
    ToolItemEvent? onItem,
  }) async {
    _validate(request);
    cancellation.throwIfCancelled();
    final parsed = webSearchCommands(commands);
    final action = webSearchAction(parsed);
    final item = <String, dynamic>{'type': 'Extension', 'kind': 'web.search',
      'id': callId ?? newUuidV7(), 'query': '', 'action': null, 'results': null};
    await onItem?.call('started', item);
    List<Object?>? results;
    try {
      return await client.search(
        model: request.model, sessionId: request.taskId, commands: parsed,
        input: _searchInput(request.input), cancellation: cancellation,
        onResults: (value) => results = value,
      );
    } finally {
      await onItem?.call('completed', {...item, 'query': webSearchActionDetail(action), 'action': action, 'results': results});
    }
  }

  // Ultra requires delegation this runtime lacks.
  static const models = supportedGptModels;
  static const efforts = {'low', 'medium', 'high', 'xhigh', 'max'};

  @override
  Json resolveSettings(Json selected, {String? model, Json? modelInfo}) {
    final info = GptModel(model ?? defaultModel, metadata: modelInfo ?? catalog?.model(model ?? defaultModel).data);
    const allowed = {
      'reasoning',
      'verbosity',
      'transport',
      'context_limit',
      'compaction_headroom',
      'reasoning_summary',
      'web_search',
      'image_generation',
      'sleep_tool',
      'goals',
      'request_user_input',
      'default_mode_request_user_input',
      'code_mode_tool_search',
    };
    final unsupported = selected.keys.where((key) => !allowed.contains(key)).toList()..sort();
    if (unsupported.isNotEmpty) {
      throw ArgumentError('Unsupported GPT setting${unsupported.length == 1 ? '' : 's'}: ${unsupported.join(', ')}');
    }
    final reasoning = selected['reasoning'] ?? info.defaultReasoning;
    if (!info.reasoningLevels.contains(reasoning)) {
      throw ArgumentError('Unsupported single-agent GPT reasoning effort');
    }
    final verbosity = selected['verbosity'] ?? info.verbosity;
    if (!{'low', 'medium', 'high'}.contains(verbosity)) {
      throw ArgumentError('Unsupported GPT verbosity');
    }
    final transport = selected['transport'] ?? client.defaultTransport;
    if (!{'http', 'websocket'}.contains(transport)) {
      throw ArgumentError('Unsupported GPT transport');
    }
    final summary = selected['reasoning_summary'] ?? info.data['default_reasoning_summary'] ?? 'none';
    if (!{'none', 'concise', 'detailed', 'auto'}.contains(summary)) {
      throw ArgumentError('Unsupported GPT reasoning summary');
    }
    final webSearch = selected['web_search'] ?? 'live';
    if (!{'live', 'disabled'}.contains(webSearch)) throw ArgumentError('GPT web_search must be live or disabled');
    final imageGeneration = selected['image_generation'] ?? client.endpoint.path.endsWith('/backend-api/codex/responses');
    if (imageGeneration is! bool) throw ArgumentError('GPT image_generation must be a boolean');
    for (final key in ['sleep_tool', 'goals', 'request_user_input', 'default_mode_request_user_input', 'code_mode_tool_search']) {
      if (selected[key] != null && selected[key] is! bool) throw ArgumentError('GPT $key must be a boolean');
    }
    final context = selected['context_limit'] ?? info.contextWindow;
    if (context is! int || context <= 1 || context > info.maxContextWindow) {
      throw ArgumentError('Context limit must be positive and within the model context cap');
    }
    final autoCompactLimit = context * 9 ~/ 10;
    final headroom = selected['compaction_headroom'] ?? context -
      (info.data['auto_compact_token_limit'] as int? ?? autoCompactLimit).clamp(1, autoCompactLimit);
    if (headroom is! int ||
        headroom <= 0 ||
        headroom >= context) {
      throw ArgumentError(
        'Compaction headroom must be positive and below the context limit',
      );
    }
    return {
      'reasoning': reasoning,
      'verbosity': verbosity,
      'transport': transport,
      'context_limit': context,
      'compaction_headroom': headroom.clamp(context - autoCompactLimit, context - 1),
      'reasoning_summary': summary,
      'web_search': webSearch,
      'image_generation': imageGeneration && (info.data['input_modalities'] as List? ?? []).contains('image'),
      'sleep_tool': selected['sleep_tool'] != false && (info.data['experimental_supported_tools'] as List? ?? []).contains('clock'),
      'goals': selected['goals'] ?? true,
      'request_user_input': selected['request_user_input'] ?? true,
      'default_mode_request_user_input': selected['default_mode_request_user_input'] ?? false,
      'code_mode_tool_search': selected['code_mode_tool_search'] == true && info.data['supports_search_tool'] == true,
    };
  }

  void _validate(ModelRequest request) {
    if (!models.contains(request.model)) {
      throw ArgumentError('Unsupported GPT model');
    }
    if (!efforts.contains(request.effectiveReasoning)) {
      throw ArgumentError('Unsupported GPT reasoning effort');
    }
    final info = GptModel(request.model, metadata: request.modelInfo);
    resolveSettings(request.settings, model: request.model, modelInfo: info.data);
    if (!info.reasoningUpdates &&
        request.effectiveReasoning != request.settings['reasoning']) {
      throw ArgumentError(
        'This GPT model does not advertise reasoning updates',
      );
    }
    for (var i = 0; i < request.input.length; i++) {
      final item = request.input[i];
      if (item.kind == 'configuration') {
        if (!efforts.contains(item.settings['reasoning']) ||
            i + 1 < request.input.length && request.input[i + 1].kind == 'configuration') {
          throw ArgumentError(
            'GPT effort updates require supported effort and distinct input boundaries',
          );
        }
      }
    }
  }

  Future<ResponsesReply> _respond(
    ModelRequest request,
    List<Json> input,
    CancellationToken cancellation,
    void Function(Json)? onEvent, {
    Future<void> Function(ConversationItem)? onRecovery,
  }) {
    _validate(request);
    return client.respond(
      model: request.model,
      modelInfo: request.modelInfo,
      instructions: request.instructions,
      input: input,
      tools: gptTools(request.tools),
      sessionId: request.taskId,
      reasoning: request.settings['reasoning'] as String,
      cancellation: cancellation,
      toolChoice: request.toolChoice,
      transport: request.settings['transport'] as String? ?? client.defaultTransport,
      verbosity: request.settings['verbosity'] as String? ?? 'low',
      reasoningSummary:
          request.settings['reasoning_summary'] as String? ?? 'auto',
      onEvent: (event) {
        if (event['type'] != 'model.incomplete') { onEvent?.call(event); return; }
        final usage = jsonObject(event['usage']);
        onEvent?.call({'type': 'model.incomplete',
          'usage': ModelUsage.fromJson({...usage, 'cache_write_tokens': usage['cache_write_input_tokens'],
            'reasoning_tokens': usage['reasoning_output_tokens']}).toJson(),
          'incompleteUsage': {'response_id': event['response_id'], 'usage': usage}});
      },
      onRecovery: (wire) async {
        final item = gptItemFromNative(wire);
        if (onRecovery != null) {
          await onRecovery(item);
        } else {
          onEvent?.call({'type': 'model.recovery', 'item': item.toJson()});
        }
      },
    );
  }

  @override
  Future<ModelReply> respond(
    ModelRequest request, {
    required CancellationToken cancellation,
    void Function(Json)? onEvent,
    Future<void> Function(ConversationItem)? onRecovery,
  }) async {
    final completed = <Object, ConversationItem>{};
    Object key(Json item) => item['id'] as String? ?? item;
    var deferred = false;
    final reply = await _respond(
      request,
      gptInput(request.input),
      cancellation,
      (event) {
        if (event['type'] == 'model.retrying') deferred = false;
        if (event['type'] != 'model.output') {
          onEvent?.call(event);
          return;
        }
        if (deferred) return;
        final wire = event['item'] as Json;
        final item = gptItemFromNative(wire,
          reasoningTimes: Map<String, Json>.from(event['reasoning_times'] as Map));
        // Client calls are admitted with their executable response below.
        if (item.kind != 'message' || item.calls.isNotEmpty) {
          deferred = true;
          return;
        }
        final id = key(wire);
        if (completed.containsKey(id)) return;
        completed[id] = item;
        onEvent?.call({'type': 'model.output', 'item': item.toJson()});
      }, onRecovery: onRecovery,
    );
    return ModelReply(
      reply.output.map((item) => completed[key(item)] ??
        gptItemFromNative(item, reasoningTimes: reply.reasoningTimes)).toList(),
      _usage(reply.usage),
      endTurn: reply.endTurn,
      observedUsage: reply.observedUsage,
    );
  }

  @override
  Future<CompactionResult> compact(
    ModelRequest request, {
    required CancellationToken cancellation,
    void Function(Json)? onEvent,
  }) async {
    final reply = await _respond(
      request,
      [
        ...gptInput(request.input),
        {'type': 'compaction_trigger'},
      ],
      cancellation,
      onEvent,
    );
    cancellation.throwIfCancelled();
    final checkpoints = reply.output
        .where((item) => item['type'] == 'compaction')
        .toList();
    if (checkpoints.length != 1 ||
        checkpoints.single['encrypted_content'] is! String) {
      throw const ModelFailure(
        'compaction_failed',
        'GPT did not return one native compaction checkpoint',
      );
    }
    // Codex retains the newest real user messages within a 64k-token budget.
    // Shared context notices are restored by the agent at installation time.
    var remaining = 64000;
    final retained = <ConversationItem>[];
    for (final item in request.input.reversed) {
      if (item.kind != 'message' ||
          item.role != 'user' ||
          item.native.containsKey('harness')) {
        continue;
      }
      final size = estimateTokens([item]);
      if (size > remaining) break;
      retained.add(item);
      remaining -= size;
    }
    return CompactionResult([
      ...retained.reversed,
      gptItemFromNative(checkpoints.single),
    ], _usage(reply.usage), observedUsage: reply.observedUsage);
  }

  static ModelUsage _usage(Json usage) => ModelUsage(
    inputTokens: (usage['input_tokens'] as num? ?? 0).toInt(),
    outputTokens: (usage['output_tokens'] as num? ?? 0).toInt(),
    cachedInputTokens:
        (usage['input_tokens_details']?['cached_tokens'] as num? ?? 0).toInt(),
    cacheWriteTokens: (usage['input_tokens_details']?['cache_write_tokens'] as num? ?? 0).toInt(),
    reasoningTokens: (usage['output_tokens_details']?['reasoning_tokens'] as num?)?.toInt(),
    totalTokens: (usage['total_tokens'] as num?)?.toInt(),
  );
}

List<Json> _searchInput(List<ConversationItem> input) {
  final visible = <Json>[];
  for (final source in input.where((item) => item.kind == 'message' &&
      {'user', 'assistant'}.contains(item.role) && !item.native.containsKey('harness'))) {
    for (final wire in gptInput([source]).where((item) => item['type'] == 'message')) {
      final item = {...wire}..remove('id');
      if (item['role'] == 'user') {
        item.remove('status');
        item.remove('encrypted_content');
        item['content'] = (item['content'] as List).where((part) => part['type'] == 'input_text').toList();
      }
      if ((item['content'] as List).isNotEmpty) visible.add(item);
    }
  }
  final users = [for (var i = 0; i < visible.length; i++) if (visible[i]['role'] == 'user') i];
  if (users.isEmpty) return [];
  final start = users.length > 1 ? users[users.length - 2] : users.last;
  var assistantBudget = 1000;
  final messages = <Json>[];
  for (final item in visible.sublist(start, users.last + 1)) {
    if (item['role'] == 'assistant') {
      final content = <Json>[];
      for (final part in (item['content'] as List).map(jsonObject)) {
        if (part['type'] != 'output_text') { content.add(part); continue; }
        if (assistantBudget == 0) continue;
        final text = part['text'] as String;
        content.add({...part, 'text': truncateTokenText(text, maxTokens: assistantBudget)});
        assistantBudget = (assistantBudget - (utf8.encode(text).length + 3) ~/ 4).clamp(0, 1000);
      }
      if (content.isEmpty) continue;
      item['content'] = content;
    }
    messages.add(item);
  }
  return messages;
}
