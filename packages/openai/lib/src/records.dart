import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'response_ids.dart';

/// Rollout response records are already canonical model input. Retain their
/// complete wire payload (including hosted/extension items) while also exposing
/// message and tool content to provider-neutral execution and interruption.
ConversationItem gptItemFromRollout(Json wire, {required String id, required Map<String, ToolCall> calls}) {
  final type = wire['type'];
  final ConversationItem item;
  if (type == 'function_call_output' || type == 'custom_tool_call_output' || type == 'tool_search_output') {
    final callId = requiredString(wire, 'call_id'), call = calls[callId];
    item = ConversationItem(id: id, role: 'tool', content: [{
      'type': 'tool_result', 'call_id': callId, 'name': call?.name ?? 'tool',
      if (call?.namespace != null) 'namespace': call!.namespace,
      'format': type == 'custom_tool_call_output' ? 'text' : type == 'tool_search_output' ? 'search' : 'json',
      'output': wire['output'] is String ? wire['output'] : jsonEncode(wire['output'] ?? wire['tools']),
    }]);
  } else if (type == 'message') {
    final content = wire['content'];
    item = ConversationItem(id: id, role: requiredString(wire, 'role'), content: content is String
      ? [{'type': 'text', 'text': content}] : [for (final part in (content as List).map(jsonObject))
        if (part['type'] == 'input_image') toolImage(part)
        else {'type': 'text', 'text': part['text'] ?? part['refusal'] ?? ''}]);
  } else if (type == 'configuration_update') {
    item = ConversationItem(id: id, kind: 'configuration', settings: jsonObject(wire['reasoning'] ?? {}));
  } else if ({'function_call', 'custom_tool_call', 'tool_search_call', 'reasoning', 'compaction'}.contains(type)) {
    item = gptItemFromNative(wire);
  } else {
    item = ConversationItem(id: id, role: 'assistant');
  }
  for (final call in item.calls) { calls[call.id] = call; }
  return ConversationItem(id: id, kind: item.kind, role: item.role, content: item.content, settings: item.settings,
    native: {...item.native, 'gpt': {...jsonObject(item.native['gpt'] ?? {}), 'rollout': wire}});
}

/// Converts provider output into durable conversation items.
ConversationItem gptItemFromNative(Json wire, {Map<String, Json> reasoningTimes = const {}}) {
  final type = wire['type'];
  final state = {...wire};
  switch (type) {
    case 'web_search_call':
      return ConversationItem(role: 'assistant', native: {'gpt': state});
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
          for (final (index, part) in summary.indexed)
            {
              'type': 'reasoning',
              'text': part['text'] ?? '',
              if (reasoningTimes['${wire['id']}:summary:$index'] case final time?) 'time': time,
              'native': {
                'gpt': {'channel': 'summary', ...part..remove('text')},
              },
            },
          for (final (index, part) in content.indexed)
            {
              'type': 'reasoning',
              'text': part['text'] ?? '',
              if (reasoningTimes['${wire['id']}:content:$index'] case final time?) 'time': time,
              'native': {
                'gpt': {'channel': 'content', ...part..remove('text')},
              },
            },
        ],
      );
    case 'tool_search_call':
    case 'function_call':
    case 'custom_tool_call':
      final call = ToolCall(
        id: requiredString(wire, 'call_id'),
        name: type == 'tool_search_call' ? 'tool_search' : requiredString(wire, 'name'),
        namespace: wire['namespace'] as String?,
        input: type == 'tool_search_call' ? jsonEncode(wire['arguments']) :
            (wire[type == 'custom_tool_call' ? 'input' : 'arguments']
                as String?) ??
            '',
        format: type == 'tool_search_call' ? 'search' : type == 'custom_tool_call' ? 'text' : 'json',
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

List<Json> withGptInstructions(String instructions, List<Json> input, {String? sessionId}) => [
  if (instructions.isNotEmpty) {
    if (sessionId != null) 'id': instructionsId(sessionId, instructions),
    'type': 'message', 'role': 'developer', 'content': [{'type': 'input_text', 'text': instructions}],
  },
  ...input,
];

List<Json> gptInput(Iterable<ConversationItem> items) {
  final output = <Json>[];
  final notifications = <String, List<Json>>{};
  final completedCalls = <String>{};
  ConversationItem? previous;
  bool context(ConversationItem? item) => item?.kind == 'message' &&
    {'agents_md', 'environment', 'skills', 'tool_catalog'}.contains(item?.native['harness']?['context']);
  List<Json> parts(Json item) => item['content'] is String
    ? [{'type': 'input_text', 'text': item['content']}] : (item['content'] as List).map(jsonObject).toList();
  for (final item in items) {
    for (final wire in _gptItems(item)) {
      // notify() is delivered durably as it arrives. Codex admits its queued
      // injection after the observing exec result, before the next inference.
      final call = wire['call_id'] as String?;
      if (item.native['gpt']?['notification'] == true && call != null && !completedCalls.contains(call)) {
        (notifications[call] ??= []).add(wire);
        continue;
      }
      if (context(item) && context(previous) && output.isNotEmpty &&
          output.last['role'] == wire['role'] && output.last.containsKey('content') && wire.containsKey('content')) {
        output.last['content'] = [...parts(output.last), ...parts(wire)];
      } else { output.add(wire); }
      if (call != null && {'custom_tool_call_output', 'function_call_output'}.contains(wire['type'])) {
        completedCalls.add(call);
        output.addAll(notifications.remove(call) ?? []);
      }
    }
    previous = item;
  }
  for (final queued in notifications.values) { output.addAll(queued); }
  return output;
}

List<Json> _gptItems(ConversationItem item) {
  final native = jsonObject(item.native['gpt'] ?? {})..remove('notification');
  if (native['rollout'] case final Map<String, dynamic> wire) return [wire];
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
      return <Json>[{'id': 'cmp_${item.id}', ...native}];
  }
  if (native['type'] == 'web_search_call') return [{'id': 'ws_${item.id}', ...native}];
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
        'id': 'rs_${item.id}',
        ...native,
        'summary': summary,
        'content': content.isEmpty ? null : content,
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
          output.add({'id': 'tsc_${item.id}', ...meta, 'type': 'tool_search_call',
            'call_id': call.id, 'execution': meta['execution'] ?? 'client', 'arguments': jsonDecode(call.input)});
          continue;
        }
        output.add({
          'id': '${call.format == 'text' ? 'ctc' : 'fc'}_${item.id}',
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
          output.add({'id': 'tso_${item.id}', ...meta, 'type': 'tool_search_output',
            'call_id': part['call_id'], 'status': 'completed', 'execution': 'client', 'tools': jsonDecode(part['output'] as String)});
          continue;
        }
        final inlineImages = meta.remove('inline_images') == true;
        final images = inlineImages ? const <dynamic>[] : part['images'] as List? ?? [];
        final content = meta.remove('content_items') == true
          ? (jsonDecode(part['output'] as String) as List).map(jsonObject).toList() : null;
        final singleText = content?.length == 1 && content!.single['type'] == 'input_text' &&
          images.isEmpty ? content.single['text'] as String : null;
        output.add({
          'id': '${part['format'] == 'text' ? 'ctco' : 'fco'}_${item.id}',
          ...meta,
          'type': part['format'] == 'text'
              ? 'custom_tool_call_output'
              : 'function_call_output',
          'call_id': part['call_id'],
          'output': singleText ?? (content == null && images.isEmpty ? part['output'] : [
            if (content != null) ...content
            else if ((part['output'] as String).isNotEmpty) {'type': 'input_text', 'text': part['output']},
            for (final image in images.map(jsonObject))
              {'type': 'input_image', 'image_url': attachmentDataUrl(image), 'detail': image['detail'] ?? 'high'},
          ]),
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
      'id': 'msg_${item.id}',
      ...native,
      'type': 'message',
      'role': item.role,
      'content': textParts,
    });
  }
  return output;
}

List<Json> gptTools(Iterable<ToolDefinition> tools) {
  final result = <Json>[];
  final hosted = <Json>[];
  final namespaces = <String, Json>{};
  for (final tool in tools) {
    if (tool.native['gpt'] is Map) {
      hosted.add(jsonObject(tool.native['gpt']));
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
    };
    if (tool.namespace == null || tool.namespace == 'functions') {
      result.add(spec);
    } else {
      final namespace = namespaces.putIfAbsent(tool.namespace!, () {
        final namespace = <String, dynamic>{'type': 'namespace', 'name': tool.namespace,
          'description': '', 'tools': <Json>[]};
        result.add(namespace);
        return namespace;
      });
      (namespace['tools'] as List).add(spec);
      if (namespace['description'] == '' && tool.namespaceDescription?.trim().isNotEmpty == true) {
        namespace['description'] = tool.namespaceDescription!.trim();
      }
    }
  }
  return [...result, ...hosted];
}
