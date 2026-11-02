import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

/// Converts provider output into durable conversation items.
ConversationItem gptItemFromNative(Json wire) {
  final type = wire['type'];
  final state = {...wire};
  switch (type) {
    case 'compaction':
      return ConversationItem(
        kind: 'compaction',
        native: {'gpt': state},
      );
    case 'reasoning':
      final summary = (state.remove('summary') as List? ?? [])
          .map(jsonObject)
          .toList();
      final content = (state.remove('content') as List? ?? [])
          .map(jsonObject)
          .toList();
      return ConversationItem(
        role: 'assistant',
        native: {'gpt': state},
        content: [
          for (final part in summary)
            {
              'type': 'reasoning',
              'text': part['text'] ?? '',
              'native': {
                'gpt': {'channel': 'summary', ...part..remove('text')},
              },
            },
          for (final part in content)
            {
              'type': 'reasoning',
              'text': part['text'] ?? '',
              'native': {
                'gpt': {'channel': 'content', ...part..remove('text')},
              },
            },
        ],
      );
    case 'function_call':
    case 'custom_tool_call':
      final call = ToolCall(
        id: requiredString(wire, 'call_id'),
        name: requiredString(wire, 'name'),
        namespace: wire['namespace'] as String?,
        input:
            (wire[type == 'custom_tool_call' ? 'input' : 'arguments']
                as String?) ??
            '',
        format: type == 'custom_tool_call' ? 'text' : 'json',
        native: {
          'gpt': {
            ...state
              ..remove('call_id')
              ..remove('name')
              ..remove('namespace')
              ..remove('input')
              ..remove('arguments'),
          },
        },
      );
      return ConversationItem(
        role: 'assistant',
        content: [call.toJson()],
      );
    case 'message':
      final role = requiredString(wire, 'role');
      state.remove('role');
      final source = state.remove('content');
      return ConversationItem(
        role: role,
        native: state.isEmpty ? {} : {'gpt': state},
        content: source is String
            ? [
                {'type': 'text', 'text': source},
              ]
            : (source as List? ?? []).map((value) {
                final part = jsonObject(value);
                final text = part.remove(
                  part['type'] == 'refusal' ? 'refusal' : 'text',
                );
                if (text is! String) {
                  throw const ModelFailure(
                    'unsupported_content',
                    'GPT returned unsupported message content',
                  );
                }
                return <String, dynamic>{
                  'type': 'text',
                  'text': text,
                  'native': {'gpt': part},
                };
              }).toList(),
      );
    default:
      throw ModelFailure(
        'unsupported_item',
        'Unsupported GPT conversation item: $type',
      );
  }
}

List<Json> withGptInstructions(String instructions, List<Json> input) => [
  if (instructions.isNotEmpty) {'role': 'developer', 'content': instructions},
  ...input,
];

List<Json> gptPromptInput(String instructions, Iterable<ConversationItem> items) =>
  withGptInstructions(instructions, gptInput(items));

List<Json> gptInput(Iterable<ConversationItem> items) {
  final output = <Json>[];
  ConversationItem? previous;
  bool context(ConversationItem? item) => item?.kind == 'message' &&
    {'agents_md', 'environment', 'skills', 'tool_catalog'}.contains(item?.native['harness']?['context']);
  List<Json> parts(Json item) => item['content'] is String
    ? [{'type': 'input_text', 'text': item['content']}] : (item['content'] as List).map(jsonObject).toList();
  for (final item in items) {
    for (final wire in _gptItems(item)) {
      if (context(item) && context(previous) && output.isNotEmpty &&
          output.last['role'] == wire['role'] && output.last.containsKey('content') && wire.containsKey('content')) {
        output.last['content'] = [...parts(output.last), ...parts(wire)];
      } else { output.add(wire); }
    }
    previous = item;
  }
  return output;
}

List<Json> _gptItems(ConversationItem item) {
  final native = jsonObject(item.native['gpt'] ?? {});
  switch (item.kind) {
    case 'configuration':
      return <Json>[
        {
          'type': 'configuration_update',
          'reasoning': {'effort': item.settings['reasoning']},
        },
      ];
    case 'tools':
      throw const ModelFailure('obsolete_context', 'Standard Responses declarations belong to request tools, not model input.');
    case 'compaction':
      if (native['type'] != 'compaction' ||
          native['encrypted_content'] is! String) {
        throw const ModelFailure(
          'invalid_compaction',
          'GPT compaction state is missing',
        );
      }
      return <Json>[native];
  }
  if (native['type'] == 'reasoning') {
    final summary = <Json>[], content = <Json>[];
    for (final part in item.content) {
      final meta = jsonObject(jsonObject(part['native'] ?? {})['gpt'] ?? {});
      final channel = meta.remove('channel');
      (channel == 'content' ? content : summary).add({
        ...meta,
        'text': part['text'],
      });
    }
    return <Json>[
      {
        ...native,
        'summary': summary,
        if (content.isNotEmpty) 'content': content,
      },
    ];
  }
  final output = <Json>[];
  final textParts = <Json>[];
  for (final part in item.content) {
    final meta = jsonObject(jsonObject(part['native'] ?? {})['gpt'] ?? {});
    switch (part['type']) {
      case 'text':
        textParts.add({
          ...meta,
          'type':
              meta['type'] ??
              (item.role == 'assistant' ? 'output_text' : 'input_text'),
          if (meta['type'] == 'refusal')
            'refusal': part['text']
          else
            'text': part['text'],
        });
      case 'image':
        textParts.add({'type': 'input_image', 'image_url': attachmentDataUrl(part), 'detail': part['detail'] ?? 'high'});
      case 'file':
        textParts.add({'type': 'input_text', 'text': attachedFileText(part)});
      case 'tool_call':
        final call = ToolCall.fromJson(part);
        output.add({
          ...meta,
          'type': call.format == 'text' ? 'custom_tool_call' : 'function_call',
          'call_id': call.id,
          'name': call.name,
          if (call.namespace != null) 'namespace': call.namespace,
          if (call.format == 'text')
            'input': call.input
          else
            'arguments': call.input,
        });
      case 'tool_result':
        final content = meta.remove('content_items') == true
          ? (jsonDecode(part['output'] as String) as List).map(jsonObject).toList() : null;
        output.add({
          ...meta,
          'type': part['format'] == 'text'
              ? 'custom_tool_call_output'
              : 'function_call_output',
          'call_id': part['call_id'],
          'output': content == null && (part['images'] as List? ?? []).isEmpty ? part['output'] : [
            if (content != null) ...content
            else if ((part['output'] as String).isNotEmpty) {'type': 'input_text', 'text': part['output']},
            for (final image in (part['images'] as List? ?? []).map(jsonObject))
              {'type': 'input_image', 'image_url': attachmentDataUrl(image), 'detail': image['detail'] ?? 'high'},
          ],
        });
      case 'reasoning':
        throw const ModelFailure(
          'invalid_reasoning',
          'GPT reasoning is missing its provider state',
        );
    }
  }
  if (textParts.isNotEmpty) {
    output.insert(0, {
      ...native,
      'role': item.role,
      'content': item.role == 'assistant' || native.isNotEmpty || item.content.any((part) => part['type'] == 'image' || part['type'] == 'file')
          ? textParts
          : textParts.map((p) => p['text']).join('\n'),
    });
  }
  return output;
}

List<Json> gptTools(Iterable<ToolDefinition> tools) {
  final result = <Json>[];
  final namespaces = <String, List<Json>>{};
  final descriptions = <String, String>{};
  for (final tool in tools) {
    final spec = <String, dynamic>{
      'type': tool.format == 'text' ? 'custom' : 'function',
      'name': tool.name,
      'description': tool.description,
      if (tool.format == 'text')
        'format': tool.grammar == null
            ? {'type': 'text'}
            : {'type': 'grammar', 'syntax': 'lark', 'definition': tool.grammar}
      else
        'parameters': tool.parameters,
      if (tool.format != 'text') 'strict': false,
    };
    if (tool.namespace == null || tool.namespace == 'functions') {
      result.add(spec);
    } else {
      (namespaces[tool.namespace!] ??= []).add(spec);
      if (tool.namespaceDescription?.trim().isNotEmpty == true) {
        descriptions.putIfAbsent(tool.namespace!, () => tool.namespaceDescription!.trim());
      }
    }
  }
  for (final entry in namespaces.entries) {
    result.add({
      'type': 'namespace',
      'name': entry.key,
      'description': descriptions[entry.key] ?? '',
      'tools': entry.value,
    });
  }
  return result;
}
