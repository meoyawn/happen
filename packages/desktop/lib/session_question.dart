import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
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
    this.enabled = true, this.active = true, this.onBeforeChange, this.onAdvance});
  final Json request;
  final QuestionDraft draft;
  final Future<void> Function(List<List<String>>? answers, CancellationToken cancellation) onAnswer;
  final Widget Function(QuestionComposer answer) composer;
  final VoidCallback? onBeforeChange;
  final void Function(VoidCallback advance)? onAdvance;
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
    if (!available || !widget.active) {
      _advance?.cancel();
      widget.onBeforeChange?.call();
    }
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
    _custom.removeListener(_edited);
    widget.onBeforeChange?.call();
    draft.custom[draft.tab] = _custom.text;
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
    widget.onBeforeChange?.call();
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
    widget.onBeforeChange?.call();
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
    widget.onBeforeChange?.call();
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
    if (!available) return;
    if (widget.onAdvance case final onAdvance?) { onAdvance(_continue); } else { _continue(); }
  }

  void _continue() {
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
          mouseCursor: WidgetStateMouseCursor.clickable,
          focusNode: _options[index],
          onTap: available ? () => _pick(index) : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Container(
                width: 16, height: 16,
                decoration: BoxDecoration(
                  color: picked ? desktopForeground : desktopSurface,
                  border: Border.all(color: picked ? desktopForeground : desktopBorderStrong),
                  borderRadius: BorderRadius.circular(multi ? 4 : 8)),
                alignment: Alignment.center,
                child: !picked ? null : multi ? const Icon(Icons.check, size: 12, color: Colors.white)
                  : Container(width: 6, height: 6,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)))),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(fontSize: 14, height: 20 / 14,
                  fontWeight: FontWeight.w500, color: picked ? desktopForeground : desktopSecondary)),
                if (description?.isNotEmpty == true && description != label) Padding(
                  padding: const EdgeInsets.only(top: 2), child: Text(description!,
                    style: const TextStyle(fontSize: 11, height: 1.5, color: desktopSecondary))),
              ])),
              if (index < 9) ...[
                const SizedBox(width: 8),
                SizedBox(width: 24, height: 20, child: Center(child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(color: desktopMuted, border: Border.all(color: desktopBorder),
                    borderRadius: BorderRadius.circular(4)),
                  child: Text('${index + 1}', style: const TextStyle(fontSize: 10, height: 1.5, color: desktopSecondary))))),
              ],
            ])),
        ),
      ),
    );

  @override
  Widget build(BuildContext context) {
    final header = question['header'] as String? ?? 'Question';
    final custom = draft.custom[draft.tab].trim().isNotEmpty;
    final panel = Padding(padding: const EdgeInsets.symmetric(horizontal: 22),
      child: DecoratedBox(decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        border: Border(top: BorderSide(color: desktopBorder),
          left: BorderSide(color: desktopBorder),
          right: BorderSide(color: desktopBorder))),
        child: Material(color: Colors.transparent,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          clipBehavior: Clip.antiAlias,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Tooltip(
                message: draft.minimized ? 'Show question and options' : 'Hide question and options',
                child: InkWell(
                mouseCursor: WidgetStateMouseCursor.clickable,
                onTap: () {
                  _advance?.cancel();
                  setState(() => draft.minimized = !draft.minimized);
                },
                child: Padding(padding: const EdgeInsets.fromLTRB(16, 9, 0, 9), child: Row(children: [
                  Expanded(child: Text(draft.minimized ? '$header  ·  ${question['question']}' : header,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: desktopSecondary))),
                  if (questions.length > 1) Text('${draft.tab + 1}/${questions.length}',
                    style: const TextStyle(fontSize: 12, color: desktopSecondary)),
                  const SizedBox(width: 8),
                  Icon(draft.minimized ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 16, color: desktopSecondary),
                ]))))),
              IconButton(tooltip: 'Dismiss question without answering',
                onPressed: available ? () => unawaited(_finish(dismiss: true)) : null,
                constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                padding: EdgeInsets.zero, icon: const Icon(Icons.close_rounded, size: 14, color: desktopSecondary)),
              const SizedBox(width: 6),
            ]),
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _QuestionTiming(request: widget.request)),
            if (!draft.minimized) Flexible(fit: FlexFit.loose, child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: (MediaQuery.sizeOf(context).height * .4).clamp(80, 384)),
              child: SingleChildScrollView(controller: _scroll,
                padding: const EdgeInsets.fromLTRB(22, 2, 16, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ConversationMarkdown(text: question['question'] as String, directory: widget.directory),
                  if (multi) const Padding(padding: EdgeInsets.only(top: 8),
                    child: Text('Select all that apply', style: TextStyle(fontSize: 11, color: desktopSecondary))),
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

class _QuestionTiming extends StatefulWidget {
  const _QuestionTiming({required this.request});
  final Json request;

  @override
  State<_QuestionTiming> createState() => _QuestionTimingState();
}

class _QuestionTimingState extends State<_QuestionTiming> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(_QuestionTiming oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request['createdAt'] != widget.request['createdAt']) _watch();
  }

  void _watch() {
    _clock?.cancel();
    if (widget.request['createdAt'] is int) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final created = widget.request['createdAt'] as int?;
    final seconds = created == null ? null : (DateTime.now().millisecondsSinceEpoch - created) ~/ 1000;
    final elapsed = seconds == null ? null : seconds <= 0 ? '0s'
      : seconds >= 3600 ? '${seconds ~/ 3600}h ${seconds ~/ 60 % 60}m ${seconds % 60}s'
      : seconds >= 60 ? '${seconds ~/ 60}m ${seconds % 60}s' : '${seconds}s';
    final asynchronous = widget.request['async'] == true;
    final lifetime = asynchronous ? 'Until turn ends' : 'No time limit';
    return Tooltip(message: asynchronous
      ? 'You can answer while the agent works. This question closes when the turn ends or is cancelled.'
      : 'This question stays open until you answer or cancel it.',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.schedule_outlined, size: 12, color: desktopTertiary),
        const SizedBox(width: 5),
        Flexible(child: Text('${elapsed == null ? '' : 'Open $elapsed · '}$lifetime',
          style: const TextStyle(fontSize: 11, color: desktopSecondary, fontFeatures: [FontFeature.tabularFigures()]))),
      ]));
  }
}
