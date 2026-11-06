import 'dart:convert';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'records.dart';

// Codex core/context/world_state/{top_level_tools,model}.rs. The agent commits
// these updates before inference; the retained catalog is the comparison state.
List<ConversationItem> renderModelContext(String instructions, List<ToolDefinition> tools,
  List<ConversationItem> history) {
  final previous = history.where((item) => item.native['harness']?['context'] == 'model_tools').lastOrNull;
  final definitions = gptTools(tools), before = previous == null ? <Json>[] : gptTools(previous.tools);
  String name(Json definition) => (definition['name'] ?? definition['type']) as String;
  Map<String, Json> index(List<Json> definitions) => {
    for (final definition in definitions) ...{
      name(definition): {...definition}..remove('tools'),
      for (final member in (definition['tools'] as List? ?? []).map(jsonObject))
        '${name(definition)}.${name(member)}': member,
    },
  };
  Object? sorted(Object? value) {
    if (value is List) return value.map(sorted).toList();
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(value[key])};
    }
    return value;
  }
  final old = index(before), next = index(definitions);
  bool changed(String key) => jsonEncode(sorted(old[key])) != jsonEncode(sorted(next[key]));
  final updates = <ConversationItem>[], declarations = <Json>[], notices = <ConversationItem>[];
  ConversationItem notice(String text, String kind) => ConversationItem(
    role: 'developer', content: [{'type': 'text', 'text': text}],
    native: {'harness': {'context': kind}},
  );
  for (final definition in definitions) {
    final key = name(definition), members = definition['tools'] as List?;
    if (members == null) {
      if (changed(key)) declarations.add(definition);
      continue;
    }
    final modified = members.map(jsonObject).where((member) => changed('$key.${name(member)}')).toList();
    if (modified.isNotEmpty) {
      declarations.add({...definition, 'tools': modified});
    } else if (changed(key)) {
      final description = definition['description'] as String? ?? '';
      notices.add(notice(description.isEmpty ? 'The $key namespace no longer has additional instructions.'
        : 'Updated instructions for the $key namespace:\n$description', 'tools_namespace'));
    }
  }
  if (declarations.isNotEmpty) {
    if (previous != null && declarations.any((tool) => tool['type'] == 'namespace')) {
      updates.add(notice('This is an incremental tools update. Previously declared tools remain available for direct calls unless explicitly marked unavailable. If a tool is redefined here, its latest definition replaces the earlier one.',
        'tools_update'));
    }
    updates.add(ConversationItem(kind: 'tools', tools: tools,
      native: {'harness': {'context': 'model_tools'},
        'gpt': {'type': 'additional_tools', 'role': 'developer', 'tools': declarations}}));
  }
  updates.addAll(notices);
  final removedNamespaces = old.keys.where((key) => !key.contains('.') && !next.containsKey(key) &&
    old.keys.any((member) => member.startsWith('$key.'))).toList()..sort();
  final removedTools = old.keys.where((key) => !next.containsKey(key) && !removedNamespaces.contains(key) &&
    !removedNamespaces.any((namespace) => key.startsWith('$namespace.'))).toList()..sort();
  if (removedNamespaces.isNotEmpty || removedTools.isNotEmpty) {
    updates.add(notice([
      if (removedNamespaces.isNotEmpty) 'The following namespaces are no longer available. Do not call tools in them unless those tools are declared in a later update:\n${removedNamespaces.map((name) => '- $name').join('\n')}',
      if (removedTools.isNotEmpty) 'The following tools are no longer available. Do not call them:\n${removedTools.map((name) => '- $name').join('\n')}',
    ].join('\n\n'), 'tools_removed'));
  }
  if (declarations.isEmpty && updates.isNotEmpty) {
    updates.add(ConversationItem(kind: 'tools', tools: tools,
      native: {'harness': {'context': 'model_tools'}, 'gpt': {'snapshot_only': true}}));
  }
  final base = history.where((item) => item.native['harness']?['context'] == 'model').lastOrNull;
  if (instructions.isNotEmpty && base?.text != instructions) {
    updates.add(notice(instructions, 'model'));
  }
  return updates;
}
