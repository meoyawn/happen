import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'records.dart';
import 'responses.dart';
import 'catalog.dart';
import 'web_search.dart';
import 'task_id.dart';

class OpenAIProvider implements ModelProvider {
  OpenAIProvider(this.client);
  final ResponsesClient client;
  @override
  String get id => 'openai';
  @override
  String newTaskId() => taskIds.create();

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
    final summary = selected['reasoning_summary'] ?? info.reasoningSummary;
    if (!{'none', 'concise', 'detailed', 'auto'}.contains(summary)) {
      throw ArgumentError('Unsupported GPT reasoning summary');
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
    };
  }

  void _validate(ModelRequest request) {
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
    void Function(Json)? onEvent,
  ) {
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
          request.settings['reasoning_summary'] as String? ?? 'none',
      onEvent: onEvent,
    );
  }

  @override
  Future<ModelReply> respond(
    ModelRequest request, {
    required CancellationToken cancellation,
    void Function(Json)? onEvent,
  }) async {
    final reply = await _respond(
      request,
      gptInput(request.input),
      cancellation,
      onEvent,
    );
    return ModelReply(
      reply.output.map(gptItemFromNative).toList(),
      _usage(reply.usage),
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
    ], _usage(reply.usage));
  }

  static ModelUsage _usage(Json usage) => ModelUsage(
    inputTokens: (usage['input_tokens'] as num? ?? 0).toInt(),
    outputTokens: (usage['output_tokens'] as num? ?? 0).toInt(),
    cachedInputTokens:
        (usage['input_tokens_details']?['cached_tokens'] as num? ?? 0).toInt(),
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
