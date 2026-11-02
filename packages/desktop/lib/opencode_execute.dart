import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'code_highlight.dart';
import 'conversation_activity.dart';
import 'conversation_data.dart';
import 'conversation_markdown.dart';
import 'opencode_activity.dart';
import 'session.dart';

const _codeStyle = TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 13, height: 20 / 13,
  letterSpacing: -.04, color: opencodeInk);

Object? _decode(Object? value) {
  if (value is! String) return value;
  try { return jsonDecode(value); } on FormatException { return value; }
}

String _code(Object? value) {
  final decoded = _decode(value);
  return decoded is Map && decoded['code'] is String ? decoded['code'] as String : conversationDataText(value);
}

String _outputText(Object? value) => (value as String? ?? '')
  .replaceAll('\r\n', '\n').replaceAll('\r', '\n')
  .replaceFirst(RegExp(r'^Script (?:completed|failed)\nWall time [^\n]+\nOutput:\n'), '')
  .trim().replaceFirst(RegExp(r'^Script error:\s*'), '').trim();

String _errorText(String output) {
  final error = output.replaceFirst(RegExp(r'^Error:\s*'), '').trim();
  return error.isEmpty ? 'Tool call failed' : error;
}

String _summary(ToolActivity call) {
  if (call.preview != null) return call.preview!.split('\n').first;
  final value = call.rawInput;
  // Large history parts stay lazy until the call is expanded.
  if (value is Map && !value.containsKey(r'$part')) {
    return value.values.map((value) => conversationDataText(value).split('\n').first).join(', ');
  }
  return '';
}

/// Use executed child calls, never JavaScript source, to identify skill reads.
List<({String name, String path})> toolSkillReads(ToolActivity call) {
  final input = _decode(call.rawInput);
  if (input is! Map || input.containsKey(r'$part')) return const [];
  final tool = call.name.split('.').last;
  if (tool == 'skill') {
    final name = input['name'] ?? input['id'];
    return name is String && name.isNotEmpty ? [(name: name, path: name)] : const [];
  }
  final paths = <String>{};
  if ({'read', 'read_file'}.contains(tool)) {
    final path = input['path'] ?? input['filePath'] ?? input['file_path'];
    if (path is String && path.replaceAll(r'\', '/').split('/').last == 'SKILL.md') paths.add(path);
  } else if ({'exec_command', 'shell_command', 'bash', 'shell'}.contains(tool)) {
    final command = input['cmd'] ?? input['command'];
    if (command is String) {
      for (final read in RegExp(r'''(?:^|[;&|\n])\s*(?:cat|head|tail|sed)\s+([^;&|\n]+)''').allMatches(command)) {
        for (final token in RegExp(r'''"([^"]*)"|'([^']*)'|([^\s"'<>]+)''').allMatches(read[1]!)) {
          final path = token[1] ?? token[2] ?? token[3]!;
          if (path.replaceAll(r'\', '/').split('/').last == 'SKILL.md') paths.add(path);
        }
      }
    }
  }
  return [for (final path in paths) () {
    final segments = path.replaceAll(r'\', '/').split('/');
    final workdir = input['workdir'] ?? input['cwd'];
    final name = segments.length > 1 && !{'.', '..'}.contains(segments[segments.length - 2])
      ? segments[segments.length - 2] : workdir is String ? workdir.replaceAll(r'\', '/').split('/').last : 'SKILL.md';
    return (name: name, path: path);
  }()];
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
    for (final read in toolSkillReads(tool)) Tooltip(message: read.path, child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DefaultTextStyle(style: const TextStyle(fontFamily: 'Inter', fontSize: 13, height: 16 / 13,
        letterSpacing: -.04, color: opencodeInk), child: Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
        Text(tool.status == 'failed' ? 'Failed to read' : tool.status == 'running' ? 'Reading'
          : tool.name.split('.').last == 'skill' ? 'Loaded' : 'Read',
          style: const TextStyle(fontVariations: [FontVariation('wght', 530)])),
        Flexible(child: tool.status == 'running' ? ThinkingLabel(label: read.name, fontSize: 13)
          : Text(read.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        const Text('skill', style: TextStyle(color: opencodeMuted)),
      ])),
    )),
  ]);
}

/// OpenCode's execute renderer: compact call rows inline, source in View code.
/// See session-ui/src/tools/tool-renderer.tsx (execute / ExecuteDetails).
class OpenCodeExecute extends StatelessWidget {
  const OpenCodeExecute({super.key, required this.tool, required this.onExpand, this.directory = ''});
  final ToolActivity tool;
  final String directory;
  final VoidCallback onExpand;

  void _viewCode(BuildContext context) {
    onExpand();
    final scope = context.getInheritedWidgetOfExactType<ConversationDataScope>();
    unawaited(showDialog<void>(context: context, builder: (context) {
      Widget details = _ExecuteDetails(tool: tool);
      if (scope != null) details = ConversationDataScope(client: scope.client, providers: scope.providers, child: details);
      return ConversationTypography(child: details);
    }));
  }

  @override
  Widget build(BuildContext context) => ConversationImageGroup(child: ConversationDisclosure(
    key: PageStorageKey('tool:${tool.id}'), label: 'JavaScript', fontSize: 13,
    shimmer: tool.status == 'running', initiallyExpanded: true, onExpand: onExpand,
    icon: tool.status == 'running' ? const OpenCodeActivityIndicator() : null,
    color: tool.status == 'failed' ? Theme.of(context).colorScheme.error : opencodeInk,
    action: IconButton(tooltip: 'View code', onPressed: () => _viewCode(context),
      style: IconButton.styleFrom(minimumSize: const Size.square(24), maximumSize: const Size.square(24),
        padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: const Icon(Icons.code_rounded, size: 16, color: opencodeFaint)),
    builder: (context) => ConversationData(value: tool.rawOutput, formatText: true, builder: (context, value) {
      final output = _outputText(value);
      final error = tool.status == 'failed' ? _errorText(output) : null;
      final owner = tool.children.where((call) => call.status == 'failed').lastOrNull;
      return DefaultTextStyle(style: _codeStyle, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final call in tool.children) Padding(padding: const EdgeInsets.only(bottom: 6),
            child: _ExecuteCall(key: PageStorageKey('execute-call:${call.id}'), call: call, directory: directory,
              error: identical(call, owner) ? error : null, onExpand: onExpand)),
          if (error != null && owner == null) ConversationDisclosure(
            key: PageStorageKey('execute-error:${tool.id}'), label: error.split('\n').first,
            fontSize: 13, color: Theme.of(context).colorScheme.error, onExpand: onExpand,
            icon: Icon(Icons.error_outline_rounded, size: 13, color: Theme.of(context).colorScheme.error),
            builder: (context) => Padding(padding: const EdgeInsets.only(left: 20),
              child: SelectableText(error,
                style: _codeStyle.copyWith(color: Theme.of(context).colorScheme.error)))),
          if (error == null && output.isNotEmpty) _ExecuteOutput(
            key: PageStorageKey('execute-output:${tool.id}'), output: output, onExpand: onExpand),
        ],
      ));
    }),
  ));
}

class _ExecuteCall extends StatefulWidget {
  const _ExecuteCall({super.key, required this.call, required this.directory, required this.onExpand, this.error});
  final ToolActivity call;
  final String directory;
  final VoidCallback onExpand;
  final String? error;

  @override
  State<_ExecuteCall> createState() => _ExecuteCallState();
}

class _ExecuteCallState extends State<_ExecuteCall> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    _open ??= PageStorage.maybeOf(context)?.readState(context, identifier: ('execute-call', widget.call.id)) as bool? ?? false;
    final call = widget.call;
    final failed = call.status == 'failed';
    final summary = _summary(call);
    if (call.name.split('.').last == 'skill' && toolSkillReads(call).isNotEmpty) return SkillReadRows(tool: call);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (toolSkillReads(call).isNotEmpty) SkillReadRows(tool: call),
      Semantics(button: true, expanded: _open, child: InkWell(
        onTap: () {
          setState(() => _open = !_open!);
          PageStorage.maybeOf(context)?.writeState(context, _open, identifier: ('execute-call', call.id));
          widget.onExpand();
        },
        child: Row(children: [
          SizedBox(width: 14, child: Center(child: failed
            ? Icon(Icons.error_outline_rounded, size: 13, color: Theme.of(context).colorScheme.error)
            : const Text('›', style: TextStyle(color: opencodeFaint)))),
          const SizedBox(width: 6),
          Flexible(child: call.status == 'running' ? ThinkingLabel(label: call.name, fontSize: 13, lineHeight: 20)
            : Text(call.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (!_open! && summary.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(child: Text('[$summary]', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: opencodeMuted))),
          ],
        ]),
      )),
      if (_open!) Container(
        margin: const EdgeInsets.fromLTRB(4, 4, 0, 2), padding: const EdgeInsets.only(left: 13),
        decoration: const BoxDecoration(border: Border(left: BorderSide(color: opencodeBorder, width: .5))),
        constraints: const BoxConstraints(maxHeight: 240),
        child: SingleChildScrollView(key: const PageStorageKey('execute-call-input'),
          child: ConversationData(value: call.rawInput, builder: (context, value) {
            final input = _decode(value);
            return SelectionArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (input is Map) for (final entry in input.entries) Padding(padding: const EdgeInsets.only(bottom: 2),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${entry.key}: ', style: const TextStyle(color: opencodeMuted)),
                  TextSpan(text: conversationDataText(entry.value)),
                ])))
              else Text(conversationDataText(value)),
              if (widget.error != null) Padding(padding: const EdgeInsets.only(top: 8),
                child: Text(widget.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)))
              else if (call.rawOutput != null || failed) ConversationData(value: call.rawOutput, formatText: true, builder: (context, value) =>
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(
                  value as String? ?? 'Tool call failed',
                  style: TextStyle(color: failed ? Theme.of(context).colorScheme.error : opencodeMuted)))),
            ]));
          })),
      ),
    ]);
  }
}

class _ExecuteOutput extends StatelessWidget {
  const _ExecuteOutput({super.key, required this.output, required this.onExpand});
  final String output;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => ConversationDisclosure(
    label: 'Output', fontSize: 13, onExpand: onExpand,
    icon: Text('›', style: _codeStyle.copyWith(color: opencodeFaint)),
    summary: Text('${output.split('\n').length} lines', style: _codeStyle.copyWith(color: opencodeMuted)),
    builder: (context) => Padding(padding: const EdgeInsets.only(left: 20),
      child: SelectableText(output, style: _codeStyle)),
  );
}

class _ExecuteDetails extends StatelessWidget {
  const _ExecuteDetails({required this.tool});
  final ToolActivity tool;

  @override
  Widget build(BuildContext context) {
    final failed = tool.status == 'failed';
    final status = failed ? 'Failed' : tool.status == 'running' ? 'Running' : 'Completed';
    return Dialog(backgroundColor: Colors.white, surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 46),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: opencodeBorder, width: .5)),
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 720, maxHeight: MediaQuery.sizeOf(context).height - 92),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.fromLTRB(24, 12, 12, 12), child: Row(children: [
            const Text('JavaScript', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: opencodeInk)),
            const SizedBox(width: 10), Text(status, style: TextStyle(fontSize: 12,
              color: failed ? Theme.of(context).colorScheme.error : opencodeMuted)),
            const SizedBox(width: 8), Text('${tool.children.length} calls', style: const TextStyle(fontSize: 12, color: opencodeFaint)),
            const Spacer(), IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close, size: 18)),
          ])),
          Flexible(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ConversationData(value: tool.rawInput, builder: (context, value) => _section('Code', _code(value), 'javascript')),
              ConversationData(value: tool.rawOutput, formatText: true, builder: (context, value) {
                final output = _outputText(value);
                if (!failed && output.isEmpty) return const SizedBox.shrink();
                var language = '';
                if (!failed) {
                  try { jsonDecode(output); language = 'json'; } on FormatException { /* Plain console output. */ }
                }
                return _section(failed ? 'Error' : 'Output', failed ? _errorText(output) : output, language);
              }),
            ]))),
        ])),
    );
  }

  Widget _section(String title, String text, String language) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Row(children: [Text(title, style: const TextStyle(fontSize: 13, color: opencodeInk)),
      const SizedBox(width: 8), Text('${text.split('\n').length} lines', style: const TextStyle(fontSize: 12, color: opencodeFaint)),
      const Spacer(), ConversationCopyButton(text: text, label: 'Copy ${title.toLowerCase()}')]),
    Container(padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(color: const Color(0xfffafafa), borderRadius: BorderRadius.circular(6)),
      child: SelectableText.rich(highlightedCode(text, language: language), style: _codeStyle)),
  ]);
}
