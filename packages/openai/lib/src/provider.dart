import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'records.dart';
import 'responses.dart';
import 'catalog.dart';
import 'web_search.dart';
import 'image_generation.dart' as image_generation;

class OpenAIProvider implements ModelProvider {
  OpenAIProvider(this.client);
  final ResponsesClient client;
  @override
  String get id => 'openai';
  @override
  String newTaskId() => newUuidV7();

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
  }) {
    _validate(request);
    return client.search(
      model: request.model,
      sessionId: request.taskId,
      commands: webSearchCommands(commands),
      input: _searchInput(request.input),
      cancellation: cancellation,
    );
  }

  // Pinned Codex model catalog; ultra requires delegation this runtime lacks.
  static const models = {
    'gpt-6.1-sol',
    'gpt-6-astra',
    'gpt-6.1-terra',
    'gpt-6-sol',
    'gpt-6-luna',
  };
  static const efforts = {'low', 'medium', 'high', 'xhigh', 'max'};

  @override
  Json resolveSettings(Json selected, {String? model}) {
    final info = GptModel(model ?? 'gpt-6.1-sol');
    const allowed = {
      'reasoning',
      'verbosity',
      'transport',
      'context_limit',
      'compaction_headroom',
      'reasoning_summary',
      'web_search',
      'image_generation',
      'standalone_web_search',
      'sleep_tool',
      'goals',
      'code_mode_only',
      'request_user_input',
    };
    if (selected.keys.any((key) => !allowed.contains(key))) {
      throw ArgumentError('Unsupported GPT setting');
    }
    final reasoning = selected['reasoning'] ?? info.defaultReasoning;
    if (!info.reasoningLevels.contains(reasoning)) {
      throw ArgumentError('Unsupported single-agent GPT reasoning effort');
    }
    final verbosity = selected['verbosity'] ?? info.verbosity;
    if (!{'low', 'medium', 'high'}.contains(verbosity)) {
      throw ArgumentError('Unsupported GPT verbosity');
    }
    final transport = selected['transport'] ?? 'http';
    if (!{'http', 'websocket'}.contains(transport)) {
      throw ArgumentError('Unsupported GPT transport');
    }
    // OpenCode requests visible summaries alongside encrypted replay state.
    final summary = selected['reasoning_summary'] ??
        (info.data['supports_reasoning_summaries'] == true ? 'auto' : 'none');
    if (!{'none', 'concise', 'detailed', 'auto'}.contains(summary)) {
      throw ArgumentError('Unsupported GPT reasoning summary');
    }
    final webSearch = selected['web_search'] ?? 'live';
    if (!{'live', 'disabled'}.contains(webSearch)) throw ArgumentError('GPT web_search must be live or disabled');
    final imageGeneration = selected['image_generation'] ?? (client.endpoint.host == 'chatgpt.com' && client.endpoint.path.startsWith('/backend-api/codex/'));
    if (imageGeneration is! bool) throw ArgumentError('GPT image_generation must be a boolean');
    for (final key in ['standalone_web_search', 'sleep_tool', 'goals', 'code_mode_only', 'request_user_input']) {
      if (selected[key] != null && selected[key] is! bool) throw ArgumentError('GPT $key must be a boolean');
    }
    final context = selected['context_limit'] ?? info.contextWindow;
    final headroom = selected['compaction_headroom'] ?? 32000;
    if (context is! int ||
        headroom is! int ||
        context <= 0 ||
        headroom <= 0 ||
        headroom >= context ||
        context > info.maxContextWindow) {
      throw ArgumentError(
        'Compaction headroom must be positive and below the context limit',
      );
    }
    return {
      'reasoning': reasoning,
      'verbosity': verbosity,
      'transport': transport,
      'context_limit': context,
      'compaction_headroom': headroom,
      'reasoning_summary': summary,
      'web_search': webSearch,
      'image_generation': imageGeneration && (info.data['input_modalities'] as List? ?? []).contains('image'),
      'standalone_web_search': selected['standalone_web_search'] ?? false,
      'sleep_tool': selected['sleep_tool'] != false && (info.data['experimental_supported_tools'] as List? ?? []).contains('clock'),
      'goals': selected['goals'] ?? true,
      'code_mode_only': selected['code_mode_only'] ?? true,
      // Interactive connections enable questions for their subscribed sessions.
      // Headless agents must opt in explicitly.
      'request_user_input': selected['request_user_input'] ?? false,
    };
  }

  void _validate(ModelRequest request) {
    if (request.input.any((item) => item.kind == 'tools' || item.native['harness']?['context'] == 'model')) {
      throw const ModelFailure('obsolete_context', 'This task contains an obsolete incremental-tools prefix. Start a new Standard Responses task.');
    }
    if (!models.contains(request.model)) {
      throw ArgumentError('Unsupported GPT model');
    }
    if (!efforts.contains(request.effectiveReasoning)) {
      throw ArgumentError('Unsupported GPT reasoning effort');
    }
    final info = GptModel(request.model);
    resolveSettings(request.settings, model: request.model);
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
            i + 1 == request.input.length ||
            request.input[i + 1].kind == 'configuration') {
          throw ArgumentError(
            'GPT effort updates require a following input item and supported effort',
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
      instructions: request.instructions,
      input: input,
      tools: gptTools(request.tools),
      sessionId: request.taskId,
      reasoning: request.settings['reasoning'] as String,
      cancellation: cancellation,
      toolChoice: request.toolChoice,
      transport: request.settings['transport'] as String? ?? 'http',
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
        if (onRecovery != null) await onRecovery(item);
        else onEvent?.call({'type': 'model.recovery', 'item': item.toJson()});
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
  final visible = input.where((item) => item.kind == 'message' &&
      {'user', 'assistant'}.contains(item.role) && item.text.isNotEmpty &&
      !item.native.containsKey('harness')).toList();
  final users = [for (var i = 0; i < visible.length; i++) if (visible[i].role == 'user') i];
  if (users.isEmpty) return [];
  final start = users.length > 1 ? users[users.length - 2] : users.last;
  var assistantBudget = 4000;
  final messages = <Json>[];
  for (final item in visible.sublist(start, users.last + 1).reversed) {
    var text = item.text;
    if (item.role == 'assistant') {
      if (assistantBudget == 0) continue;
      if (text.length > assistantBudget) text = text.substring(text.length - assistantBudget);
      assistantBudget -= text.length;
    }
    messages.add({'type': 'message', 'role': item.role, 'content': [
      {'type': item.role == 'user' ? 'input_text' : 'output_text', 'text': text},
    ]});
  }
  return messages.reversed.toList();
}
