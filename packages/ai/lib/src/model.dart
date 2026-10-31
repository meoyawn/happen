import 'dart:convert';

import 'package:protocol/protocol.dart';

/// Durable, provider-independent conversation content. Provider state belongs
/// in [native], or the native field of the corresponding content part.
class ConversationItem {
  ConversationItem({
    String? id,
    this.kind = 'message',
    this.role,
    this.content = const [],
    this.settings = const {},
    this.tools = const [],
    this.native = const {},
  }) : id = id ?? newId();

  final String id, kind;
  final String? role;
  final List<Json> content;
  final Json settings, native;
  final List<ToolDefinition> tools;

  factory ConversationItem.text(String role, String text, {String? id}) =>
      ConversationItem(
        id: id,
        role: role,
        content: [
          {'type': 'text', 'text': text},
        ],
      );

  factory ConversationItem.toolResult(
    ToolCall call,
    String output, {
    bool isError = false,
    List<ToolDefinition> tools = const [],
  }) => ConversationItem(
    role: 'tool',
    tools: tools,
    content: [
      {
        'type': 'tool_result',
        'call_id': call.id,
        'name': call.name,
        if (call.namespace != null) 'namespace': call.namespace,
        'format': call.format,
        'output': output,
        'is_error': isError,
      },
    ],
  );

  factory ConversationItem.user(String text, {Object? attachments}) {
    final parts = inputAttachments(attachments);
    validateUserInput(text, parts);
    return ConversationItem(role: 'user', content: [
      if (text.isNotEmpty) {'type': 'text', 'text': text},
      ...parts,
    ]);
  }

  factory ConversationItem.fromJson(Json json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported conversation record version');
    }
    final kind = requiredString(json, 'kind');
    if (!{'message', 'configuration', 'tools', 'compaction'}.contains(kind)) {
      throw FormatException('Unsupported conversation record kind: $kind');
    }
    final role = json['role'] as String?;
    if (kind == 'message' &&
        !{'system', 'developer', 'user', 'assistant', 'tool'}.contains(role)) {
      throw const FormatException('Invalid message role');
    }
    final content = (json['content'] as List? ?? []).map(jsonObject).toList();
    for (final part in content) {
      switch (part['type']) {
        case 'text':
        case 'reasoning':
          if (part['text'] is! String) {
            throw const FormatException('Invalid text content');
          }
        case 'tool_call':
          ToolCall.fromJson(part);
        case 'tool_result':
          requiredString(part, 'call_id');
          if (part['output'] is! String) {
            throw const FormatException('Invalid tool output');
          }
        case 'image':
          if (part['path'] != null) throw const FormatException('Saved images must contain their bytes');
          if (role != 'user') throw const FormatException('Attachments require a user message');
          inputAttachments([part]);
        case 'file':
          if (role != 'user') throw const FormatException('Attachments require a user message');
          inputAttachments([part]);
        default:
          throw FormatException('Unsupported content part: ${part['type']}');
      }
    }
    return ConversationItem(
      id: requiredString(json, 'id'),
      kind: kind,
      role: role,
      content: content,
      settings: jsonObject(json['settings'] ?? {}),
      tools: (json['tools'] as List? ?? [])
          .map((v) => ToolDefinition.fromJson(jsonObject(v)))
          .toList(),
      native: jsonObject(json['native'] ?? {}),
    );
  }

  Json toJson() => {
    'version': 1,
    'id': id,
    'kind': kind,
    if (role != null) 'role': role,
    if (content.isNotEmpty) 'content': content,
    if (settings.isNotEmpty) 'settings': settings,
    if (tools.isNotEmpty) 'tools': tools.map((v) => v.toJson()).toList(),
    if (native.isNotEmpty) 'native': native,
  };

  String get text => content
      .where((p) => p['type'] == 'text')
      .map((p) => p['text'] as String)
      .join('\n');
  List<ToolCall> get calls => content
      .where((p) => p['type'] == 'tool_call')
      .map(ToolCall.fromJson)
      .toList();
}

class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.input,
    this.namespace,
    this.format = 'text',
    this.native = const {},
  });
  final String id, name, input, format;
  final String? namespace;
  final Json native;
  factory ToolCall.fromJson(Json json) {
    final format = json['format'] as String? ?? 'text';
    if (!{'text', 'json', 'search'}.contains(format) || json['input'] is! String) {
      throw const FormatException('Invalid tool input');
    }
    return ToolCall(
      id: requiredString(json, 'id'),
      name: requiredString(json, 'name'),
      input: json['input'] as String,
      namespace: json['namespace'] as String?,
      format: format,
      native: jsonObject(json['native'] ?? {}),
    );
  }
  Json toJson() => {
    'type': 'tool_call',
    'id': id,
    'name': name,
    'input': input,
    'format': format,
    if (namespace != null) 'namespace': namespace,
    if (native.isNotEmpty) 'native': native,
  };
}

class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    this.namespace,
    this.namespaceDescription,
    this.format = 'json',
    this.parameters = const {},
    this.grammar,
  });
  final String name, description, format;
  final String? namespace, namespaceDescription, grammar;
  final Json parameters;
  factory ToolDefinition.fromJson(Json json) => ToolDefinition(
    name: requiredString(json, 'name'),
    description: json['description'] as String? ?? '',
    namespace: json['namespace'] as String?,
    namespaceDescription: json['namespace_description'] as String?,
    format: json['format'] as String? ?? 'json',
    parameters: jsonObject(json['parameters'] ?? {}),
    grammar: json['grammar'] as String?,
  );
  Json toJson() => {
    'name': name,
    'description': description,
    'format': format,
    if (namespace != null) 'namespace': namespace,
    if (namespaceDescription != null) 'namespace_description': namespaceDescription,
    if (parameters.isNotEmpty) 'parameters': parameters,
    if (grammar != null) 'grammar': grammar,
  };
}

class ModelUsage {
  const ModelUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.cacheWriteTokens = 0,
  });
  final int inputTokens, outputTokens, cachedInputTokens, cacheWriteTokens;
  int get contextTokens => inputTokens + outputTokens;
  factory ModelUsage.fromJson(Json json) => ModelUsage(
    inputTokens: (json['input_tokens'] as num? ?? 0).toInt(),
    outputTokens: (json['output_tokens'] as num? ?? 0).toInt(),
    cachedInputTokens: (json['cached_input_tokens'] as num? ?? 0).toInt(),
    cacheWriteTokens: (json['cache_write_tokens'] as num? ?? 0).toInt(),
  );
  Json toJson() => {
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'cached_input_tokens': cachedInputTokens,
    'cache_write_tokens': cacheWriteTokens,
  };
}

class ModelReply {
  const ModelReply(this.output, this.usage);
  final List<ConversationItem> output;
  final ModelUsage usage;
  List<ToolCall> get calls => output.expand((item) => item.calls).toList();
  String get text => output
      .where((item) => item.role == 'assistant')
      .map((item) => item.text)
      .where((text) => text.isNotEmpty)
      .join('\n');
  factory ModelReply.fromJson(Json json) => ModelReply(
    (json['output'] as List)
        .map((item) => ConversationItem.fromJson(jsonObject(item)))
        .toList(),
    ModelUsage.fromJson(jsonObject(json['usage'])),
  );
  Json toJson() => {
    'output': output.map((item) => item.toJson()).toList(),
    'usage': usage.toJson(),
  };
}

class ModelRequest {
  const ModelRequest({
    required this.taskId,
    required this.model,
    required this.instructions,
    required this.input,
    required this.tools,
    required this.settings,
    required this.effectiveReasoning,
    this.toolChoice = 'auto',
  });
  final String taskId, model, instructions, effectiveReasoning, toolChoice;
  final List<ConversationItem> input;
  final List<ToolDefinition> tools;

  /// Frozen initial provider settings. Effort changes remain ordered history items.
  final Json settings;
  factory ModelRequest.fromJson(Json json) => ModelRequest(
    taskId: requiredString(json, 'task_id'),
    model: requiredString(json, 'model'),
    instructions: json['instructions'] as String? ?? '',
    input: (json['input'] as List)
        .map((v) => ConversationItem.fromJson(jsonObject(v)))
        .toList(),
    tools: (json['tools'] as List)
        .map((v) => ToolDefinition.fromJson(jsonObject(v)))
        .toList(),
    settings: jsonObject(json['settings']),
    effectiveReasoning: requiredString(json, 'effective_reasoning'),
    toolChoice: json['tool_choice'] as String? ?? 'auto',
  );
  Json toJson() => {
    'task_id': taskId,
    'model': model,
    'instructions': instructions,
    'input': input.map((v) => v.toJson()).toList(),
    'tools': tools.map((v) => v.toJson()).toList(),
    'settings': settings,
    'effective_reasoning': effectiveReasoning,
    'tool_choice': toolChoice,
  };
}

class CompactionResult {
  const CompactionResult(this.context, this.usage, {this.summary = ''});
  final List<ConversationItem> context;
  final ModelUsage usage;
  final String summary;
  factory CompactionResult.fromJson(Json json) => CompactionResult(
    (json['context'] as List)
        .map((v) => ConversationItem.fromJson(jsonObject(v)))
        .toList(),
    ModelUsage.fromJson(jsonObject(json['usage'])),
    summary: json['summary'] as String? ?? '',
  );
  Json toJson() => {
    'context': context.map((v) => v.toJson()).toList(),
    'usage': usage.toJson(),
    'summary': summary,
  };
}

abstract interface class ModelProvider {
  String get id;
  String newTaskId();
  Json resolveSettings(Json selected, {String? model});
  Future<String> webSearch(
    ModelRequest request,
    Json commands, {
    required CancellationToken cancellation,
  });
  Future<ModelReply> respond(
    ModelRequest request, {
    required CancellationToken cancellation,
    void Function(Json)? onEvent,
  });
  Future<CompactionResult> compact(
    ModelRequest request, {
    required CancellationToken cancellation,
    void Function(Json)? onEvent,
  });
}

class ModelFailure implements Exception {
  const ModelFailure(this.code, this.message);
  final String code, message;
  @override
  String toString() => '$code: $message';
}

/// Conservative estimate for newly appended data; reported usage remains primary.
int estimateTokens(Iterable<ConversationItem> items) {
  var images = 0;
  final visible = <Json>[];
  for (final item in items) {
    visible.add({...item.toJson(), 'content': [
      for (final part in item.content)
        if (part['type'] != 'image') part,
    ]});
    for (final part in item.content.where((part) => part['type'] == 'image')) {
      // Codex counts image tokens independently of base64 length. Its high-
      // detail heuristic is 7,373 estimated bytes at four bytes per token.
      if (part['detail'] == 'original') {
        final width = part['width'] as int?, height = part['height'] as int?;
        images += width == null || height == null ? 10000
            : (((width + 31) ~/ 32) * ((height + 31) ~/ 32)).clamp(1, 10000);
      } else {
        images += 1844;
      }
    }
  }
  return (utf8.encode(jsonEncode(visible)).length / 3).ceil() + images;
}
