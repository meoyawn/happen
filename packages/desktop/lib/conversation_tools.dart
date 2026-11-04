import 'dart:convert';

import 'package:flutter/material.dart';

import 'conversation_data.dart';
import 'conversation_activity.dart';
import 'conversation_indicator.dart';
import 'conversation_markdown.dart';
import 'session.dart';

Object? _decode(Object? value) {
  if (value is! String) return value;
  try { return jsonDecode(value); } on FormatException { return value; }
}

List<({String name, String path})> toolSkillReads(ToolActivity call) {
  final input = _decode(call.rawInput);
  if (input is! Map) return const [];
  if (call.name.split('.').last == 'skill') {
    final name = input['name'] ?? input['id'];
    return name is String && name.isNotEmpty ? [(name: name, path: name)] : const [];
  }
  final paths = <String>{};
  if ({'read', 'read_file'}.contains(call.name.split('.').last)) {
    final path = input['path'] ?? input['filePath'] ?? input['file_path'];
    if (path is String && path.endsWith('/SKILL.md')) paths.add(path);
  }
  final command = input['cmd'] ?? input['command'];
  if (command is String) {
    for (final match in RegExp(r'''(?:^|[;&|\n])\s*(?:cat|head|tail|sed)\s+([^;&|\n]+)''').allMatches(command)) {
      for (final token in RegExp(r'''"([^"]*)"|'([^']*)'|([^\s"'<>]+)''').allMatches(match[1]!)) {
        final path = token[1] ?? token[2] ?? token[3]!;
        if (path.replaceAll(r'\', '/').endsWith('/SKILL.md')) paths.add(path);
      }
    }
  }
  return [for (final path in paths) (name: path.replaceAll(r'\', '/').split('/').reversed.skip(1).first, path: path)];
}

Iterable<String> toolSkillNames(ToolActivity tool) sync* {
  for (final read in toolSkillReads(tool)) { yield read.name; }
  for (final child in tool.children) { yield* toolSkillNames(child); }
}

class SkillReadRows extends StatelessWidget {
  const SkillReadRows({super.key, required this.tool});
  final ToolActivity tool;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    for (final read in toolSkillReads(tool)) Tooltip(message: read.path, child: Text('Read ${read.name} skill', style: const TextStyle(fontSize: 13))),
  ]);
}

/// T3Code's work-log detail model: each native tool call owns one compact row;
/// arguments/output stay unformatted until that row is expanded.
class ConversationToolCall extends StatelessWidget {
  const ConversationToolCall({super.key, required this.tool, required this.onExpand, this.directory = ''});
  final ToolActivity tool;
  final VoidCallback onExpand;
  final String directory;

  @override
  Widget build(BuildContext context) => ConversationDisclosure(
    key: PageStorageKey('tool:${tool.id}'), label: {'exec', 'functions.exec'}.contains(tool.name) ? 'JavaScript' : tool.name,
    onExpand: onExpand, fontSize: 13,
    icon: tool.status == 'running' ? const ConversationActivityIndicator() : Icon(
      tool.status == 'failed' ? Icons.error_outline : Icons.terminal, size: 14,
      color: tool.status == 'failed' ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant),
    builder: (context) => Padding(padding: const EdgeInsets.only(left: 20, top: 8, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ConversationData(value: tool.rawInput, formatText: true, builder: (context, input) =>
          ConversationData(value: tool.rawOutput, formatText: true, builder: (context, output) => ConversationCode(
            source: input as String? ?? '', output: output as String?,
            language: {'exec', 'functions.exec'}.contains(tool.name) ? 'javascript' : 'json'))),
        for (final child in tool.children) Padding(padding: const EdgeInsets.only(top: 8),
          child: ConversationToolCall(tool: child, onExpand: onExpand, directory: directory)),
      ])),
  );
}
