import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'conversation_activity.dart';
import 'conversation_data.dart';
import 'session.dart';

/// OpenCode's question dock, kept with its session while switching tabs.
class SessionQuestionDock extends StatefulWidget {
  const SessionQuestionDock({super.key, required this.request, required this.draft,
    required this.onAnswer, this.enabled = true});
  final Json request;
  final QuestionDraft draft;
  final Future<void> Function(List<List<String>>? answers, CancellationToken cancellation) onAnswer;
  final bool enabled;

  @override
  State<SessionQuestionDock> createState() => _SessionQuestionDockState();
}

class _SessionQuestionDockState extends State<SessionQuestionDock> {
  final _lifetime = CancellationToken();
  final _focus = FocusNode();
  final _customFocus = FocusNode();
  final _custom = TextEditingController();
  final _scroll = ScrollController();
  List<FocusNode> _options = [];
  bool _sending = false;
  String? _error;

  QuestionDraft get draft => widget.draft;
  List<Json> get questions => (widget.request['questions'] as List).cast<Json>();
  Json get question => questions[draft.tab];
  List<Json> get options => (question['options'] as List).cast<Json>();
  bool get multi => question['multiple'] == true;
  bool get available => widget.enabled && !_sending;
  bool get customOn => draft.customOn.contains(draft.tab);
  bool get last => draft.tab == questions.length - 1;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  void _prepare() {
    for (final node in _options) { node.dispose(); }
    _options = List.generate(options.length + 1, (_) => FocusNode());
    _custom.text = draft.custom[draft.tab];
  }

  @override
  void dispose() {
    _lifetime.cancel();
    _focus.dispose();
    _customFocus.dispose();
    _custom.dispose();
    _scroll.dispose();
    for (final node in _options) { node.dispose(); }
    super.dispose();
  }

  void _jump(int tab) {
    if (!available || tab == draft.tab || tab < 0 || tab >= questions.length) return;
    _customFocus.unfocus();
    setState(() {
      draft.tab = tab;
      _prepare();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _focus.requestFocus();
  }

  void _pick(int index) {
    if (!available) return;
    if (index == options.length) {
      setState(() {
        if (multi && customOn) {
          draft.customOn.remove(draft.tab);
        } else {
          draft.customOn.add(draft.tab);
          if (!multi) draft.answers[draft.tab].clear();
          draft.minimized = false;
        }
      });
      if (customOn) _customFocus.requestFocus();
      return;
    }
    final label = options[index]['label'] as String;
    setState(() {
      final answers = draft.answers[draft.tab];
      if (multi) {
        if (!answers.add(label)) answers.remove(label);
      } else {
        answers..clear()..add(label);
        draft.customOn.remove(draft.tab);
      }
    });
    _options[index].requestFocus();
  }

  Future<void> _finish({bool dismiss = false}) async {
    if (!available) return;
    setState(() { _sending = true; _error = null; });
    try {
      await widget.onAnswer(dismiss ? null : [
        for (var i = 0; i < questions.length; i++) draft.answer(i),
      ], _lifetime);
    } on CancelledException {
      // Closing the session or receiving its resolution removes the dock.
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _next() {
    if (!available) return;
    if (last) { unawaited(_finish()); } else { _jump(draft.tab + 1); }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !available || !_custom.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      unawaited(_finish(dismiss: true));
      return KeyEventResult.handled;
    }
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final primary = mac ? keys.isMetaPressed : keys.isControlPressed;
    if (primary && !keys.isAltPressed && key == LogicalKeyboardKey.enter) {
      _next();
      return KeyEventResult.handled;
    }
    if (mac && keys.isMetaPressed && key == LogicalKeyboardKey.bracketLeft ||
        !mac && keys.isAltPressed && key == LogicalKeyboardKey.arrowLeft) {
      _jump(draft.tab - 1);
      return KeyEventResult.handled;
    }
    if (_customFocus.hasFocus || keys.isAltPressed || keys.isControlPressed || keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final number = int.tryParse(key.keyLabel);
    if (number != null && number >= 1 && number <= _options.length && !draft.minimized) {
      _pick(number - 1);
      return KeyEventResult.handled;
    }
    final current = _options.indexWhere((node) => node.hasFocus);
    final next = switch (key) {
      LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.arrowRight => (current + 1).clamp(0, _options.length - 1),
      LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.arrowLeft => (current - 1).clamp(0, _options.length - 1),
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => _options.length - 1,
      _ => null,
    };
    if (next != null && !draft.minimized) {
      _options[next].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter) {
      if (current >= 0) _pick(current);
      if (!multi && !_customFocus.hasFocus) _next();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _option(int index, {required String label, String? description, required bool picked}) =>
    Semantics(
      selected: picked, checked: multi ? picked : null,
      inMutuallyExclusiveGroup: !multi, enabled: available,
      child: Material(color: picked ? const Color(0xffedf2ff) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          focusNode: _options[index],
          onTap: available ? () => _pick(index) : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(
                multi ? picked ? Icons.check_box_outlined : Icons.check_box_outline_blank
                  : picked ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 16, color: picked ? const Color(0xff3250df) : opencodeFaint)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 13, height: 1.5, color: opencodeInk)),
                if (description?.isNotEmpty == true) Text(description!,
                  style: const TextStyle(fontSize: 12, height: 1.5, color: opencodeMuted)),
              ])),
              if (index < 9) ...[
                const SizedBox(width: 8),
                Container(padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(border: Border.all(color: opencodeBorder), borderRadius: BorderRadius.circular(4)),
                  child: Text('${index + 1}', style: const TextStyle(fontSize: 11, color: opencodeFaint))),
              ],
            ])),
        ),
      ),
    );

  @override
  Widget build(BuildContext context) {
    final shortcut = defaultTargetPlatform == TargetPlatform.macOS ? '⌘↵' : 'Ctrl+Enter';
    final secondaryStyle = TextButton.styleFrom(minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8), tapTargetSize: MaterialTapTargetSize.shrinkWrap);
    return Center(heightFactor: 1, child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: opencodeSessionWidth),
      child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
        child: Focus(focusNode: _focus, autofocus: true, onKeyEvent: _key,
          child: Material(color: Colors.white, shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10), side: const BorderSide(color: opencodeBorder, width: .5)),
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: SingleChildScrollView(controller: _scroll, padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Expanded(child: Text(questions.length == 1 ? 'Question' : '${draft.tab + 1} of ${questions.length} questions',
                      style: const TextStyle(fontSize: 13, color: opencodeMuted))),
                    if (questions.length > 1) Flexible(child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (var i = 0; i < questions.length; i++) Tooltip(
                          message: questions[i]['header'] as String,
                          child: Semantics(label: 'Question ${i + 1}', selected: draft.tab == i,
                            child: InkWell(onTap: available ? () => _jump(i) : null,
                              borderRadius: BorderRadius.circular(4),
                              child: Padding(padding: const EdgeInsets.all(5), child: Container(
                                width: 12, height: 3, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
                                  color: draft.tab == i ? const Color(0xff3250df)
                                    : draft.answer(i).isEmpty ? opencodeBorder : opencodeMuted))))),
                        ),
                      ]),
                    )),
                    IconButton(
                      tooltip: draft.minimized ? 'Expand questions' : 'Minimize questions',
                      onPressed: available ? () => setState(() => draft.minimized = !draft.minimized) : null,
                      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                      padding: EdgeInsets.zero, iconSize: 18,
                      icon: Icon(draft.minimized ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded)),
                  ]),
                  const SizedBox(height: 4),
                  SelectableText(question['question'] as String,
                    maxLines: draft.minimized ? 3 : null,
                    style: const TextStyle(fontSize: 13, height: 1.5, fontWeight: FontWeight.w500, color: opencodeInk)),
                  if (!draft.minimized) ...[
                    const SizedBox(height: 6),
                    Text(multi ? 'Select all that apply' : 'Select one answer',
                      style: const TextStyle(fontSize: 11, color: opencodeFaint)),
                    const SizedBox(height: 8),
                    for (var i = 0; i < options.length; i++) _option(i,
                      label: options[i]['label'] as String, description: options[i]['description'] as String,
                      picked: draft.answers[draft.tab].contains(options[i]['label'])),
                    _option(options.length, label: 'Type your own answer', picked: customOn),
                    if (customOn) Padding(padding: const EdgeInsets.fromLTRB(36, 4, 8, 8), child: TextField(
                      controller: _custom, focusNode: _customFocus, enabled: available,
                      minLines: 1, maxLines: 4,
                      style: const TextStyle(fontSize: 13, color: opencodeInk),
                      decoration: const InputDecoration(hintText: 'Type your answer…',
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: opencodeBorder))),
                      onChanged: (value) => setState(() => draft.custom[draft.tab] = value),
                    )),
                  ],
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error))),
                ]),
              )),
              LayoutBuilder(builder: (context, constraints) => Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 12, 8), child: Wrap(
                  alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8,
                  children: [
                TextButton(style: secondaryStyle, onPressed: available ? () => unawaited(_finish(dismiss: true)) : null,
                  child: const Text('Dismiss', style: TextStyle(fontSize: 12, color: opencodeMuted))),
                if (draft.tab > 0) ...[
                  TextButton(style: secondaryStyle, onPressed: available ? () => _jump(draft.tab - 1) : null,
                    child: const Text('Back', style: TextStyle(fontSize: 12))),
                ],
                Tooltip(message: shortcut, child: FilledButton(
                  onPressed: available ? _next : null,
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(horizontal: 12), visualDensity: VisualDensity.compact),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_sending) ...[
                      const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                      const SizedBox(width: 8),
                    ],
                    Text(last ? 'Submit' : 'Next', style: const TextStyle(fontSize: 12)),
                    if (constraints.maxWidth >= 360) ...[
                      const SizedBox(width: 10),
                      Text(shortcut, style: const TextStyle(fontSize: 11)),
                    ],
                  ]),
                )),
              ]))),
            ]),
          ),
        ),
      ),
    ));
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
    final rawQuestions = decoded is Map && decoded['questions'] is List ? decoded['questions'] as List : const [];
    final questions = [for (final question in rawQuestions.whereType<Map>())
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
          if (value is Map) answer = value['answers'];
        }
        answers.add(answer is List ? answer.whereType<String>().toList() : const []);
      }
      final running = tool.status == 'running';
      final asynchronous = tool.name.split('.').last == 'request_user_input_async';
      final count = questions.length;
      return ConversationDisclosure(
        key: PageStorageKey('question:${tool.id}'),
        label: asynchronous && tool.status == 'done' ? 'Asked $count question${count == 1 ? '' : 's'}'
          : running ? 'Waiting for your answer' : tool.status == 'done'
          ? 'Answered $count question${count == 1 ? '' : 's'}'
          : tool.status == 'failed' ? 'Questions failed' : 'Question dismissed',
        fontSize: 13, initiallyExpanded: true, onExpand: onExpand,
        icon: const Icon(Icons.help_outline_rounded, size: 14, color: opencodeMuted),
        builder: (context) => Padding(padding: const EdgeInsets.only(left: 18, top: 4, bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (tool.status == 'failed' && output != null)
              SelectableText(result is Map ? (result['error'] ?? result['output'] ?? result).toString()
                : result.toString(), style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.error)),
            for (var i = 0; i < count; i++) Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(questions[i]['question'] as String,
                  style: const TextStyle(fontSize: 13, color: opencodeMuted)),
                if (!asynchronous) ...[
                  const SizedBox(height: 2),
                  SelectableText(answers[i].isNotEmpty
                    ? answers[i].join(', ') : running ? 'Waiting for your answer…' : 'Unanswered',
                    style: const TextStyle(fontSize: 13, color: opencodeInk)),
                ],
              ])),
          ])),
      );
    });
  });
}
