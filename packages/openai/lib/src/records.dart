import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

/// Converts both provider output and the prototype's historical input items.
ConversationItem gptItemFromNative(Json wire, {String? id}) {
  final type = wire['type'];
  final state = {...wire};
  switch (type) {
    case 'configuration_update':
      return ConversationItem(
        id: id,
        kind: 'configuration',
        settings: {'reasoning': jsonObject(wire['reasoning'])['effort']},
      );
    case 'additional_tools':
      return ConversationItem(
        id: id,
        kind: 'tools',
        tools: gptToolsFromNative((wire['tools'] as List).map(jsonObject)),
      );
    case 'tool_search_call':
      if (wire['execution'] != 'client') {
        throw const ModelFailure('unsupported_item', 'Only client-executed tool search is supported');
      }
      return ConversationItem(
        id: id,
        role: 'assistant',
        content: [ToolCall(
          id: requiredString(wire, 'call_id'),
          name: 'tool_search',
          input: jsonEncode(jsonObject(wire['arguments'])),
          format: 'search',
          native: {'gpt': {...state..remove('call_id')..remove('arguments')}},
        ).toJson()],
      );
    case 'tool_search_output':
      return ConversationItem(
        id: id,
        role: 'tool',
        tools: gptToolsFromNative((wire['tools'] as List).map(jsonObject)),
        content: [{
          'type': 'tool_result', 'call_id': requiredString(wire, 'call_id'),
          'name': 'tool_search', 'format': 'search', 'output': '{}',
          'native': {'gpt': {...state..remove('call_id')..remove('tools')}},
        }],
      );
    case 'compaction':
      return ConversationItem(
        id: id,
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
        id: id,
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
        id: id,
        role: 'assistant',
        content: [call.toJson()],
      );
    case 'function_call_output':
    case 'custom_tool_call_output':
      return ConversationItem(
        id: id,
        role: 'tool',
        content: [
          {
            'type': 'tool_result',
            'call_id': requiredString(wire, 'call_id'),
            'format': type == 'custom_tool_call_output' ? 'text' : 'json',
            'output': wire['output'] is List
                ? (wire['output'] as List).map(jsonObject).where((part) => part['type'] == 'input_text').map((part) => part['text']).join('\n')
                : wire['output'] as String? ?? '',
            if (wire['output'] is List) 'images': inputAttachments([
              for (final part in (wire['output'] as List).map(jsonObject))
                if (part['type'] == 'input_image') toolImage(part),
            ]),
            'native': {
              'gpt': {
                ...state
                  ..remove('call_id')
                  ..remove('output'),
              },
            },
          },
        ],
      );
    case null:
    case 'message':
      final role = requiredString(wire, 'role');
      state.remove('role');
      final source = state.remove('content');
      return ConversationItem(
        id: id,
        role: role,
        native: state.isEmpty ? {} : {'gpt': state},
        content: source is String
            ? [
                {'type': 'text', 'text': source},
              ]
            : (source as List? ?? []).map((value) {
                final part = jsonObject(value);
                if (part['type'] == 'input_image') {
                  final uri = Uri.tryParse(part['image_url'] as String? ?? '');
                  final data = uri?.scheme == 'data' ? uri!.data : null;
                  if (data == null || !imageMimeTypes.contains(data.mimeType)) {
                    throw const ModelFailure('unsupported_content', 'GPT image requires inline image bytes');
                  }
                  return inputAttachments([{
                    'type': 'image', 'name': 'Image', 'mime_type': data.mimeType,
                    'data': base64Encode(data.contentAsBytes()),
                    'detail': part['detail'] ?? 'high',
                  }]).single;
                }
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

List<Json> gptInput(Iterable<ConversationItem> items) => items.expand((item) {
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
      return <Json>[
        {
          'type': 'additional_tools',
          'role': 'developer',
          'tools': gptTools(item.tools),
        },
      ];
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
        if (call.format == 'search') {
          output.add({
            ...meta, 'type': 'tool_search_call', 'execution': 'client',
            'call_id': call.id, 'arguments': jsonDecode(call.input),
          });
          continue;
        }
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
        if (part['format'] == 'search') {
          output.add({
            ...meta, 'type': 'tool_search_output', 'execution': 'client',
            'status': 'completed', 'call_id': part['call_id'],
            'tools': gptTools(item.tools, deferLoading: true),
          });
          if (part['is_error'] == true) {
            output.add({'role': 'developer', 'content': 'Tool search failed: ${part['output']}'});
          }
          continue;
        }
        output.add({
          ...meta,
          'type': part['format'] == 'text'
              ? 'custom_tool_call_output'
              : 'function_call_output',
          'call_id': part['call_id'],
          'output': (part['images'] as List? ?? []).isEmpty ? part['output'] : [
            if ((part['output'] as String).isNotEmpty) {'type': 'input_text', 'text': part['output']},
            for (final image in (part['images'] as List).map(jsonObject))
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
}).toList();

List<Json> gptTools(Iterable<ToolDefinition> tools, {bool deferLoading = false}) {
  final result = <Json>[];
  final namespaces = <String, List<Json>>{};
  final descriptions = <String, String>{};
  for (final tool in tools) {
    if (tool.format == 'search') {
      result.add({
        'type': 'tool_search', 'execution': 'client',
        'description': tool.description, 'parameters': tool.parameters,
      });
      continue;
    }
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
      if (deferLoading) 'defer_loading': true,
    };
    if (tool.namespace == null) {
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
      'description': descriptions[entry.key] ?? (deferLoading ? 'Tools in the ${entry.key} namespace.' : ''),
      'tools': entry.value,
    });
  }
  return result;
}

List<ToolDefinition> gptToolsFromNative(
  Iterable<Json> tools, {
  String? namespace,
  String? namespaceDescription,
}) => tools.expand((tool) {
  if (tool['type'] == 'namespace') {
    return gptToolsFromNative(
      (tool['tools'] as List).map(jsonObject),
      namespace: tool['name'] as String,
      namespaceDescription: tool['description'] as String?,
    );
  }
  return [
    ToolDefinition(
      name: tool['type'] == 'tool_search' ? 'tool_search' : requiredString(tool, 'name'),
      description: tool['description'] as String? ?? '',
      namespace: namespace,
      namespaceDescription: namespaceDescription,
      format: tool['type'] == 'tool_search' ? 'search' : tool['type'] == 'custom' ? 'text' : 'json',
      parameters: jsonObject(tool['parameters'] ?? {}),
      grammar: tool['format'] is Map
          ? tool['format']['definition'] as String?
          : null,
    ),
  ];
}).toList();
