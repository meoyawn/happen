import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'conversation_activity.dart';
import 'conversation_data.dart';
import 'conversation_markdown.dart';
import 'session.dart';

typedef QuestionComposer = ({
  Widget panel,
  TextEditingController controller,
  FocusNode focus,
  bool enabled,
  bool canSubmit,
  bool sending,
  String placeholder,
  String action,
  VoidCallback advance,
  VoidCallback? previous,
});

/// Questions attach to the composer and keep their answers with the session.
class SessionQuestionDock extends StatefulWidget {
  const SessionQuestionDock({super.key, required this.request, required this.draft,
    required this.onAnswer, required this.composer, this.directory = '',
    this.enabled = true, this.active = true});
  final Json request;
  final QuestionDraft draft;
  final Future<void> Function(List<List<String>>? answers, CancellationToken cancellation) onAnswer;
  final Widget Function(QuestionComposer answer) composer;
  final String directory;
  final bool enabled, active;

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
  Timer? _advance;
  bool _sending = false;
  bool _changingQuestion = false;
  String? _error;

  QuestionDraft get draft => widget.draft;
  List<Json> get questions => (widget.request['questions'] as List).cast<Json>();
  Json get question => questions[draft.tab];
  List<Json> get options => (question['options'] as List).cast<Json>();
  bool get multi => question['multiple'] == true;
  bool get available => widget.enabled && !_sending;
  bool get last => draft.tab == questions.length - 1;
  bool get canSubmit => available && draft.answer(draft.tab).isNotEmpty &&
      (!last || List.generate(questions.length, draft.answer).every((answer) => answer.isNotEmpty));

  @override
  void initState() {
    super.initState();
    _prepare();
    _custom.addListener(_edited);
  }

  @override
  void didUpdateWidget(SessionQuestionDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!available || !widget.active) _advance?.cancel();
  }

  void _prepare() {
    _advance?.cancel();
    for (final node in _options) { node.dispose(); }
    _options = List.generate(options.length, (_) => FocusNode());
    _changingQuestion = true;
    _custom.text = draft.custom[draft.tab];
    _custom.selection = TextSelection.collapsed(offset: _custom.text.length);
    _changingQuestion = false;
  }

  void _edited() {
    if (_changingQuestion || draft.custom[draft.tab] == _custom.text) return;
    _advance?.cancel();
    setState(() {
      draft.custom[draft.tab] = _custom.text;
    });
  }

  @override
  void dispose() {
    _lifetime.cancel();
    _advance?.cancel();
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
      draft.minimized = false;
      _error = null;
      _prepare();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (options.isEmpty) { _customFocus.requestFocus(); } else { _focus.requestFocus(); }
  }

  void _pick(int index) {
    if (!available) return;
    _advance?.cancel();
    final label = options[index]['label'] as String;
    setState(() {
      _custom.clear();
      final answers = draft.answers[draft.tab];
      if (multi) {
        if (!answers.add(label)) answers.remove(label);
      } else {
        answers..clear()..add(label);
      }
    });
    _options[index].requestFocus();
    if (!multi) _advance = Timer(const Duration(milliseconds: 200), _next);
  }

  Future<void> _finish({bool dismiss = false}) async {
    if (!available) return;
    _advance?.cancel();
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
    if (!canSubmit) return;
    if (last) { unawaited(_finish()); } else { _jump(draft.tab + 1); }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !available || !widget.active || !_custom.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _advance?.cancel();
      setState(() => draft.minimized = !draft.minimized);
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
    if (_customFocus.hasFocus || keys.isAltPressed || keys.isControlPressed || keys.isMetaPressed || keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final number = int.tryParse(key.keyLabel);
    if (number != null && number >= 1 && number <= _options.length && !draft.minimized) {
      _pick(number - 1);
      return KeyEventResult.handled;
    }
    if (_options.isEmpty) return KeyEventResult.ignored;
    final current = _options.indexWhere((node) => node.hasFocus);
    final next = switch (key) {
      LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.arrowRight => (current + 1).clamp(0, _options.length - 1),
      LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.arrowLeft => (current - 1).clamp(0, _options.length - 1),
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => _options.length - 1,
      _ => null,
    };
    if (next != null && _options.isNotEmpty && !draft.minimized) {
      _options[next].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter) {
      if (current >= 0) { _pick(current); } else { _next(); }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _option(int index, {required String label, String? description, required bool picked}) =>
    Semantics(
      selected: picked, checked: multi ? picked : null,
      inMutuallyExclusiveGroup: !multi, enabled: available,
      child: Material(color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          focusNode: _options[index],
          onTap: available ? () => _pick(index) : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(
                multi ? picked ? Icons.check_box_outlined : Icons.check_box_outline_blank
                  : picked ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 15, color: picked ? opencodeInk : opencodeFaint)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(fontSize: 13, height: 1.5,
                  fontWeight: FontWeight.w500, color: picked ? opencodeInk : opencodeMuted)),
                if (description?.isNotEmpty == true && description != label) Text(description!,
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
    final header = question['header'] as String? ?? 'Question';
    final custom = draft.custom[draft.tab].trim().isNotEmpty;
    final panel = Padding(padding: const EdgeInsets.symmetric(horizontal: 10),
      child: DecoratedBox(decoration: const BoxDecoration(
        color: Color(0xfffafafa),
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        border: Border(top: BorderSide(color: opencodeBorder, width: .5),
          left: BorderSide(color: opencodeBorder, width: .5),
          right: BorderSide(color: opencodeBorder, width: .5))),
        child: Material(color: Colors.transparent,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Tooltip(
                message: draft.minimized ? 'Show question and options' : 'Hide question and options',
                child: InkWell(
                onTap: () {
                  _advance?.cancel();
                  setState(() => draft.minimized = !draft.minimized);
                },
                child: Padding(padding: const EdgeInsets.fromLTRB(16, 9, 0, 9), child: Row(children: [
                  Expanded(child: Text(draft.minimized ? '$header  ·  ${question['question']}' : header,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: opencodeMuted))),
                  if (questions.length > 1) Text('${draft.tab + 1}/${questions.length}',
                    style: const TextStyle(fontSize: 11, color: opencodeMuted)),
                  const SizedBox(width: 8),
                  Icon(draft.minimized ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 16, color: opencodeFaint),
                ]))))),
              IconButton(tooltip: 'Dismiss question without answering',
                onPressed: available ? () => unawaited(_finish(dismiss: true)) : null,
                constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                padding: EdgeInsets.zero, icon: const Icon(Icons.close_rounded, size: 14, color: opencodeFaint)),
              const SizedBox(width: 6),
            ]),
            if (!draft.minimized) Flexible(fit: FlexFit.loose, child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: (MediaQuery.sizeOf(context).height * .4).clamp(80, 384)),
              child: SingleChildScrollView(controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ConversationMarkdown(text: question['question'] as String, directory: widget.directory, fontSize: 13),
                  if (multi) const Padding(padding: EdgeInsets.only(top: 8),
                    child: Text('Select all that apply', style: TextStyle(fontSize: 11, color: opencodeFaint))),
                  if (options.isNotEmpty) const SizedBox(height: 6),
                  for (var i = 0; i < options.length; i++) _option(i,
                    label: options[i]['label'] as String, description: options[i]['description'] as String?,
                    picked: !custom && draft.answers[draft.tab].contains(options[i]['label'])),
                ]),
              ),
            )),
            if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(_error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error))),
          ]),
        ),
      ),
    );
    return Focus(focusNode: _focus, onKeyEvent: _key, child: widget.composer((
      panel: panel, controller: _custom, focus: _customFocus,
      enabled: available, canSubmit: canSubmit, sending: _sending,
      placeholder: options.isEmpty ? 'Type your answer…' : 'Type your own answer, or choose an option above…',
      action: last ? (questions.length > 1 ? 'Submit answers' : 'Submit answer') : 'Next',
      advance: _next, previous: draft.tab > 0 && available ? () => _jump(draft.tab - 1) : null,
    )));
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
