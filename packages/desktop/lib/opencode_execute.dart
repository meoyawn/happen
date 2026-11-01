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

String _summary(ToolActivity call) {
  if (call.preview != null) return call.preview!.split('\n').first;
  final value = call.rawInput;
  // Large history parts stay lazy until the call is expanded.
  if (value is Map && !value.containsKey(r'$part')) {
    return value.values.map((value) => conversationDataText(value).split('\n').first).join(', ');
  }
  return '';
}

/// OpenCode's execute renderer: compact call rows inline, source in View code.
/// See session-ui/src/tools/tool-renderer.tsx (execute / ExecuteDetails).
class OpenCodeExecute extends StatelessWidget {
  const OpenCodeExecute({super.key, required this.tool, required this.onExpand});
  final ToolActivity tool;
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
  Widget build(BuildContext context) => ConversationDisclosure(
    key: PageStorageKey('tool:${tool.id}'), label: 'JavaScript', fontSize: 13,
    shimmer: tool.status == 'running', initiallyExpanded: true, onExpand: onExpand,
    icon: tool.status == 'running' ? const OpenCodeActivityIndicator() : null,
    color: tool.status == 'failed' ? Theme.of(context).colorScheme.error : opencodeInk,
    action: IconButton(tooltip: 'View code', onPressed: () => _viewCode(context),
      style: IconButton.styleFrom(minimumSize: const Size.square(24), maximumSize: const Size.square(24),
        padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: const Icon(Icons.code_rounded, size: 16, color: opencodeFaint)),
    builder: (context) => DefaultTextStyle(style: _codeStyle, child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final call in tool.children) Padding(padding: const EdgeInsets.only(bottom: 6),
          child: _ExecuteCall(key: PageStorageKey('execute-call:${call.id}'), call: call, onExpand: onExpand)),
        ConversationData(value: tool.rawOutput, builder: (context, value) {
          final output = value == null ? '' : conversationDataText(value).trim();
          if (output.isEmpty) return const SizedBox.shrink();
          return _ExecuteOutput(key: PageStorageKey('execute-output:${tool.id}'), output: output,
            failed: tool.status == 'failed', onExpand: onExpand);
        }),
      ],
    )),
  );
}

class _ExecuteCall extends StatefulWidget {
  const _ExecuteCall({super.key, required this.call, required this.onExpand});
  final ToolActivity call;
  final VoidCallback onExpand;

  @override
  State<_ExecuteCall> createState() => _ExecuteCallState();
}

class _ExecuteCallState extends State<_ExecuteCall> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    _open ??= PageStorage.maybeOf(context)?.readState(context, identifier: 'execute-call-open') as bool? ?? false;
    final call = widget.call;
    final failed = call.status == 'failed';
    final summary = _summary(call);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(button: true, expanded: _open, child: InkWell(
        onTap: () {
          setState(() => _open = !_open!);
          PageStorage.maybeOf(context)?.writeState(context, _open, identifier: 'execute-call-open');
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
              if (call.rawOutput != null || failed) ConversationData(value: call.rawOutput, builder: (context, value) =>
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(
                  value == null ? 'Tool call failed' : conversationDataText(value),
                  style: TextStyle(color: failed ? Theme.of(context).colorScheme.error : opencodeMuted)))),
            ]));
          })),
      ),
    ]);
  }
}

class _ExecuteOutput extends StatelessWidget {
  const _ExecuteOutput({super.key, required this.output, required this.failed, required this.onExpand});
  final String output;
  final bool failed;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => ConversationDisclosure(
    label: failed ? 'Error' : 'Output', fontSize: 13, onExpand: onExpand,
    icon: Text('›', style: _codeStyle.copyWith(color: failed ? Theme.of(context).colorScheme.error : opencodeFaint)),
    summary: Text('${output.split('\n').length} lines', style: _codeStyle.copyWith(color: opencodeMuted)),
    builder: (context) => Padding(padding: const EdgeInsets.only(left: 20),
      child: SelectableText(output, style: _codeStyle.copyWith(color: failed ? Theme.of(context).colorScheme.error : opencodeInk))),
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
              ConversationData(value: tool.rawOutput, builder: (context, value) => value == null ? const SizedBox.shrink()
                : _section(failed ? 'Error' : 'Output', conversationDataText(value), failed ? '' : 'json')),
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
