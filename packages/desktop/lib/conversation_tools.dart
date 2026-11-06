import 'dart:convert';

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'code_highlight.dart';
import 'conversation_activity.dart';
import 'conversation_changes.dart';
import 'conversation_data.dart';
import 'conversation_markdown.dart' show ConversationCopyButton;
import 'session.dart';

Object? _decode(Object? value) {
  if (value is! String || value.length > 65536) return value;
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

String toolKind(ToolActivity tool) {
  final name = tool.name.split('.').last.split('__').last.toLowerCase();
  if ({'exec', 'exec_command', 'shell', 'shell_command', 'bash', 'run_command'}.contains(name)) return 'command';
  if ({'read', 'read_file', 'read_text_file', 'list_directory'}.contains(name)) return 'read';
  if ({'write', 'write_file', 'edit', 'edit_file', 'apply_patch'}.contains(name)) return 'edit';
  if ({'wait', 'write_stdin', 'sleep'}.contains(name)) return 'wait';
  if ({'question', 'request_user_input', 'request_user_input_async'}.contains(name)) return 'question';
  if (name == 'skill') return 'skill';
  if (name == 'view_image' || name == 'imagegen') return 'image';
  if (tool.name.contains('chrome') || tool.name.contains('browser')) return 'browser';
  if (name.contains('search') || name == 'find' || name == 'grep') return 'search';
  return 'tool';
}

String? toolCommand(ToolActivity tool) {
  final input = _decode(tool.rawInput);
  final command = input is Map ? input['cmd'] ?? input['command'] : toolKind(tool) == 'command' ? input : null;
  return command is String ? command.trim() : null;
}

String? toolJavaScript(ToolActivity tool) {
  if (tool.name.split('.').last != 'exec') return null;
  final input = tool.rawInput;
  if (input is String) return input;
  if (input is Map) {
    final source = input['code'] ?? input['script'] ?? input['source'];
    if (source is String) return source;
  }
  return null;
}

String _relative(String path, String directory) => directory.isNotEmpty && path.startsWith('$directory/')
  ? path.substring(directory.length + 1) : path;

String toolLabel(ToolActivity tool, {String directory = '', bool active = false}) {
  final input = _decode(tool.rawInput);
  final name = tool.name.split('.').last.split('__').last;
  final failed = tool.status == 'failed';
  final kind = toolKind(tool);
  final command = toolCommand(tool);
  if (kind == 'command') {
    final program = name == 'exec' ? 'JavaScript' : command == null || command.isEmpty ? 'command'
      : command.split(RegExp(r'\s+')).first.split('/').last;
    return '${failed ? 'Failed' : active ? 'Running' : 'Ran'} $program';
  }
  if (kind == 'read' || kind == 'edit') {
    final path = input is Map ? input['path'] ?? input['filePath'] ?? input['file_path'] : null;
    final changes = input is Map ? input['changes'] : null;
    final changedPaths = changes is List ? changes.whereType<Map>().map((change) => change['path']).whereType<String>().toList() : const <String>[];
    final target = path is String ? _relative(path, directory) : changedPaths.length == 1
      ? _relative(changedPaths.single, directory) : changedPaths.length > 1 ? '${changedPaths.length} files' : 'file';
    return '${kind == 'read' ? active ? 'Reading' : 'Read' : active ? 'Editing' : 'Changed'} $target';
  }
  if (kind == 'wait') return active ? 'Waiting for ${name == 'sleep' ? 'timer' : 'command'}' : 'Waited for ${name == 'sleep' ? 'timer' : 'command'}';
  if (kind == 'skill') {
    final reads = toolSkillReads(tool);
    return '${active ? 'Loading' : 'Loaded'} ${reads.isEmpty ? '' : '${reads.first.name} '}skill';
  }
  if (kind == 'question') return active ? 'Waiting for your answer' : 'Asked a question';
  if (name == 'view_image') return active ? 'Opening image' : 'Viewed image';
  if (kind == 'search') {
    final query = input is Map ? input['query'] ?? input['q'] ?? input['pattern'] : null;
    return '${active ? 'Searching' : 'Searched'}${query is String ? ' for $query' : ''}';
  }
  final friendly = name.replaceAll('_', ' ');
  final source = tool.name.contains('__') ? tool.name.split('__').where((part) => part.isNotEmpty && part != 'mcp').first
    : tool.name.contains('.') ? tool.name.split('.').first : null;
  return source == null ? friendly : '$source · $friendly';
}

String toolGroupSummary(List<ToolActivity> tools) {
  final groups = <String, int>{};
  for (final tool in tools) { groups.update(toolKind(tool), (count) => count + 1, ifAbsent: () => 1); }
  final labels = <String>[];
  for (final entry in groups.entries.take(2)) {
    final count = entry.value, plural = count == 1 ? '' : 's';
    labels.add(switch (entry.key) {
      'command' => 'Ran $count command$plural',
      'read' => 'Read $count file$plural',
      'edit' => 'Changed $count file$plural',
      'search' => 'Searched $count ${count == 1 ? 'time' : 'times'}',
      'browser' => 'Used browser $count ${count == 1 ? 'time' : 'times'}',
      'skill' => 'Loaded $count skill$plural',
      'wait' => 'Waited for $count ${count == 1 ? 'operation' : 'operations'}',
      'question' => 'Asked $count question$plural',
      _ => 'Used $count tool$plural',
    });
  }
  final others = groups.entries.skip(2).fold(0, (total, entry) => total + entry.value);
  if (others > 0) labels.add('Performed $others other ${others == 1 ? 'action' : 'actions'}');
  return labels.indexed.map((item) => item.$1 == 0 ? item.$2 : '${item.$2[0].toLowerCase()}${item.$2.substring(1)}').join(' and ');
}

class ConversationToolCall extends StatelessWidget {
  const ConversationToolCall({super.key, required this.tool, required this.onExpand, this.directory = ''});
  final ToolActivity tool;
  final VoidCallback onExpand;
  final String directory;

  @override
  Widget build(BuildContext context) {
    if (toolKind(tool) == 'question') return QuestionToolResult(tool: tool, onExpand: onExpand);
    if (tool.rawInput case {'changes': final List _}) {
      return ConversationFileChangeActivity(tool: tool, onExpand: onExpand, directory: directory);
    }
    return ConversationDisclosure(
    key: PageStorageKey('tool:${tool.id}'),
    label: toolLabel(tool, directory: directory, active: tool.status == 'running'),
    fontSize: 14, shimmer: tool.status == 'running', timestamp: tool.startedAt,
    color: tool.status == 'failed' ? const Color(0xffc10007) : conversationSecondary,
    icon: ConversationWorkIcon(kind: toolKind(tool), failed: tool.status == 'failed'),
    onExpand: onExpand,
    builder: (context) => Padding(padding: const EdgeInsets.only(left: 30, top: 4, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ConversationData(value: tool.rawInput, formatText: true, builder: (context, input) =>
          ConversationData(value: tool.rawOutput, formatText: true, builder: (context, output) {
            final script = toolJavaScript(tool);
            final source = script ?? toolCommand(tool) ?? input as String? ?? '';
            final result = output as String?;
            if (script != null) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Expanded(child: Text('JavaScript', style: TextStyle(fontSize: 11, color: conversationSecondary))),
                ConversationCopyButton(text: script, label: 'Copy JavaScript', compact: true),
              ]),
              const SizedBox(height: 4),
              ConstrainedBox(constraints: const BoxConstraints(maxHeight: 256),
                child: SingleChildScrollView(key: PageStorageKey('tool-script:${tool.id}'),
                  child: SelectableText.rich(highlightedCode(script, language: 'javascript'),
                    style: const TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 12,
                      height: 1.625, color: conversationForeground)))),
              if (result?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                const Text('Output', style: TextStyle(fontSize: 11, color: conversationSecondary)),
                const SizedBox(height: 4),
                _ToolOutput(id: tool.id, text: result!),
              ],
            ]);
            final text = [if (source.isNotEmpty) source, if (result?.isNotEmpty == true) result!].join('\n\n');
            return _ToolOutput(id: tool.id, text: text.isEmpty ? 'No output' : text);
          })),
        for (final child in tool.children) ConversationToolCall(
          key: ValueKey(child.id), tool: child, onExpand: onExpand, directory: directory),
      ])),
    );
  }
}

Object? _decodeQuestionResult(Object? value) {
  if (value is String) {
    try { return _decodeQuestionResult(jsonDecode(value)); } on FormatException { return value; }
  }
  if (value is List && value.length == 1 && value.first is Map) {
    return _decodeQuestionResult(value.first['text']);
  }
  if (value is Map && value['content'] is List) return _decodeQuestionResult(value['content']);
  return value;
}

class QuestionToolResult extends StatelessWidget {
  const QuestionToolResult({super.key, required this.tool, required this.onExpand});
  final ToolActivity tool;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => ConversationData(value: tool.rawInput, builder: (context, input) {
    final decoded = _decodeQuestionResult(input);
    final rawQuestions = decoded is Map && decoded['questions'] is List ? decoded['questions'] as List : const <Object?>[];
    final questions = [for (final question in rawQuestions.whereType<Map<Object?, Object?>>())
      if (question['question'] is String || question['title'] is String) {
        'id': question['id'],
        'question': question['question'] is String ? question['question'] : question['title'],
      },
    ];
    return ConversationData(value: tool.rawOutput, builder: (context, output) {
      final result = _decodeQuestionResult(output);
      final rawAnswers = result is Map ? result['answers'] : null;
      final answers = <List<String>>[];
      for (var i = 0; i < questions.length; i++) {
        Object? answer;
        if (rawAnswers is List && i < rawAnswers.length) answer = rawAnswers[i];
        if (rawAnswers is Map) {
          final value = rawAnswers[questions[i]['id']];
          answer = value is Map ? value['answers'] : value;
        }
        answers.add(answer is List ? answer.whereType<String>().toList() : answer is String ? [answer] : const []);
      }
      final running = tool.status == 'running';
      final asynchronous = tool.name.split('.').last.split('__').last == 'request_user_input_async';
      final count = questions.length;
      final status = asynchronous && tool.status == 'done' ? 'Asked $count question${count == 1 ? '' : 's'}'
          : running ? 'Waiting for your answer' : tool.status == 'done'
          ? 'Answered $count question${count == 1 ? '' : 's'}'
          : tool.status == 'failed' ? 'Questions failed' : 'Question dismissed';
      return QuestionAnswerRow(key: PageStorageKey('question:${tool.id}'),
        id: tool.id,
        answers: [for (var i = 0; i < count; i++)
          (question: questions[i]['question'] as String, answer: answers[i].join(', '))],
        status: status, active: running, onExpand: onExpand,
        error: tool.status == 'failed' && output != null
          ? result is Map ? (result['error'] ?? result['output'] ?? result).toString() : result.toString() : null);
    });
  });
}

class QuestionAnswerRow extends StatelessWidget {
  const QuestionAnswerRow({super.key, required this.id, required this.answers, this.status = 'Answered',
    this.active = false, this.onExpand, this.error});
  final List<ChatQuestionAnswer> answers;
  final String id, status;
  final bool active;
  final VoidCallback? onExpand;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final question = answers.map((answer) => answer.question.replaceAll(RegExp(r'\s+'), ' ')).join(' · ');
    final answer = answers.map((answer) => answer.answer.replaceAll(RegExp(r'\s+'), ' ')).where((text) => text.isNotEmpty).join(' · ');
    return ConversationDisclosure(
      key: PageStorageKey('answer:$id'),
      label: question.isEmpty ? status : question, fontSize: 14,
      shimmer: active, onExpand: onExpand,
      icon: ConversationWorkIcon(kind: 'question', failed: error != null),
      labelContent: question.isEmpty ? null : Row(children: [
        Flexible(child: Text(question, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, height: 1.625, color: conversationSecondary))),
        if (answer.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(child: Text(answer, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, height: 1.625, color: conversationForeground))),
        ],
      ]),
      builder: (context) => Padding(padding: const EdgeInsets.fromLTRB(30, 8, 2, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final answer in answers) Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(answer.question,
                style: const TextStyle(fontSize: 14, height: 1.625, color: conversationSecondary)),
              if (answer.answer.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 12, top: 4),
                child: SelectableText(answer.answer,
                  style: const TextStyle(fontSize: 14, height: 1.625, color: conversationSecondary))),
            ])),
          if (error != null) SelectableText(error!,
            style: const TextStyle(fontSize: 14, height: 1.625, color: Color(0xffc10007))),
        ])),
    );
  }
}

class _ToolOutput extends StatefulWidget {
  const _ToolOutput({required this.id, required this.text});
  final String id, text;
  @override
  State<_ToolOutput> createState() => _ToolOutputState();
}

class _ToolOutputState extends State<_ToolOutput> {
  final _scroll = ScrollController();
  bool _following = true, _scheduled = false;

  @override
  void initState() { super.initState(); _follow(); }

  @override
  void didUpdateWidget(_ToolOutput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _follow();
  }

  void _follow() {
    if (!_following || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && _following && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() { _scroll.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ConstrainedBox(constraints: const BoxConstraints(maxHeight: 256),
    child: NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _following = notification.metrics.extentAfter <= 4;
        return false;
      },
      child: SingleChildScrollView(key: PageStorageKey('tool-output:${widget.id}'), controller: _scroll,
        child: SelectableText(widget.text, style: const TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 11,
          height: 1.625, color: conversationSecondary)))));
}

class ConversationWorkIcon extends StatelessWidget {
  const ConversationWorkIcon({super.key, required this.kind, this.failed = false});
  final String kind;
  final bool failed;
  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size.square(16),
    painter: _WorkIconPainter(kind, failed ? const Color(0xffc10007) : conversationSecondary));
}

class _WorkIconPainter extends CustomPainter {
  const _WorkIconPainter(this.kind, this.color);
  final String kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()..color = color..style = PaintingStyle.stroke
      ..strokeWidth = 1.8..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    void line(double x1, double y1, double x2, double y2) =>
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke);
    switch (kind) {
      case 'command':
        canvas.drawPath(Path()..moveTo(4, 5)..lineTo(10, 11)..lineTo(4, 17), stroke);
        line(12, 19, 20, 19);
      case 'read':
      case 'edit':
        canvas.drawPath(Path()..moveTo(14, 2)..lineTo(6, 2)..quadraticBezierTo(4, 2, 4, 4)
          ..lineTo(4, 20)..quadraticBezierTo(4, 22, 6, 22)..lineTo(18, 22)
          ..quadraticBezierTo(20, 22, 20, 20)..lineTo(20, 8)..close(), stroke);
        canvas.drawPath(Path()..moveTo(14, 2)..lineTo(14, 8)..lineTo(20, 8), stroke);
        line(8, 13, 16, 13);
        line(8, 17, kind == 'edit' ? 12 : 16, 17);
      case 'search':
        canvas.drawCircle(const Offset(10.5, 10.5), 7, stroke);
        line(16, 16, 21, 21);
      case 'browser':
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawOval(const Rect.fromLTWH(8, 3, 8, 18), stroke);
        line(3, 12, 21, 12);
      case 'wait':
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawPath(Path()..moveTo(12, 7)..lineTo(12, 12)..lineTo(15, 14), stroke);
      case 'image':
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 3, 18, 18), const Radius.circular(2)), stroke);
        canvas.drawCircle(const Offset(8.5, 8.5), 1.5, stroke);
        canvas.drawPath(Path()..moveTo(21, 15)..lineTo(16, 10)..lineTo(5, 21), stroke);
      case 'reasoning':
        canvas.drawPath(Path()..moveTo(12, 5)..cubicTo(9, 0, 5, 3, 5, 6)
          ..cubicTo(0, 7, 2, 13, 4, 14)..cubicTo(1, 19, 7, 23, 10, 20)
          ..lineTo(12, 18)..lineTo(12, 5)..cubicTo(15, 0, 19, 3, 19, 6)
          ..cubicTo(24, 7, 22, 13, 20, 14)..cubicTo(23, 19, 17, 23, 14, 20)
          ..lineTo(12, 18), stroke);
        canvas.drawPath(Path()..moveTo(5, 7)..quadraticBezierTo(9, 7, 8, 11)
          ..moveTo(4, 14)..quadraticBezierTo(9, 13, 9, 17)
          ..moveTo(19, 7)..quadraticBezierTo(15, 7, 16, 11), stroke);
      case 'question':
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 3, 18, 15), const Radius.circular(3)), stroke);
        canvas.drawPath(Path()..moveTo(7, 18)..lineTo(7, 22)..lineTo(12, 18), stroke);
        line(8, 9, 16, 9);
        line(8, 13, 13, 13);
      default:
        canvas.drawPath(Path()..moveTo(12, 3)..lineTo(3, 8)..lineTo(12, 13)
          ..lineTo(21, 8)..close(), stroke);
        canvas.drawPath(Path()..moveTo(3, 12)..lineTo(12, 17)..lineTo(21, 12)
          ..moveTo(3, 16)..lineTo(12, 21)..lineTo(21, 16), stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WorkIconPainter oldDelegate) => kind != oldDelegate.kind || color != oldDelegate.color;
}
