import 'dart:async';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import 'appearance.dart';
import 'composer_text_controller.dart';
import 'file_autocomplete.dart';
import 'inline_reference.dart';

typedef _Reference = ({int start, int end, ComposerFileReference file});

/// A viewport of independently laid out lines. The conversation and controls do
/// not rebuild when text changes, and reference labels are painted as text.
class ComposerEditor extends StatefulWidget {
  const ComposerEditor({super.key, required this.controller, required this.focusNode,
    required this.enabled, required this.paste, required this.copy});
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final Future<void> Function(SelectionChangedCause) paste;
  final Future<void> Function({bool cut}) copy;

  @override
  State<ComposerEditor> createState() => _ComposerEditorState();
}

class _ComposerEditorState extends State<ComposerEditor> {
  late final _code = CodeLineEditingController(spanBuilder: _span);
  final _snapshots = Expando<List<_Reference>>();
  final _height = ValueNotifier(44.0);
  List<_Reference> _references = [];
  List<int> _lines = [0];
  String _display = '';
  TextEditingValue _raw = TextEditingValue.empty;
  CodeLineEditingValue? _previous;
  bool _syncing = false;
  double _width = 0;
  TextScaler _scaler = TextScaler.noScaling;

  @override
  void initState() {
    super.initState();
    _pull();
    widget.controller.addListener(_pull);
    _code.addListener(_edited);
  }

  @override
  void didUpdateWidget(ComposerEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_pull);
      widget.controller.addListener(_pull);
      _code.clearHistory();
      _pull();
    }
  }

  List<int> _lineOffsets(CodeLines lines) {
    final offsets = <int>[];
    var offset = 0;
    for (final segment in lines.segments) {
      for (final line in segment.codeLines) {
        offsets.add(offset);
        offset += line.length + 1;
      }
    }
    return offsets;
  }

  int _toDisplay(int offset) {
    var delta = 0;
    for (final ref in _references) {
      if (offset <= ref.file.offset) break;
      delta += ref.end - ref.start - 1;
    }
    return (offset + delta).clamp(0, _display.length);
  }

  int _toRaw(int offset) {
    var delta = 0;
    for (final ref in _references) {
      if (offset <= ref.start) break;
      if (offset < ref.end) return ref.file.offset + (offset - ref.start > (ref.end - ref.start) / 2 ? 1 : 0);
      delta += ref.end - ref.start - 1;
    }
    return offset - delta;
  }

  ({int index, int offset}) _position(int offset) {
    var low = 0, high = _lines.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_lines[middle] <= offset) { low = middle; } else { high = middle - 1; }
    }
    return (index: low, offset: offset - _lines[low]);
  }

  TextSelection _selection(CodeLineEditingValue value, List<int> lines) => TextSelection(
    baseOffset: lines[value.selection.baseIndex] + value.selection.baseOffset,
    extentOffset: lines[value.selection.extentIndex] + value.selection.extentOffset,
    affinity: value.selection.extentAffinity,
  );

  void _pull() {
    if (_syncing) return;
    final next = widget.controller.value;
    final files = widget.controller is ComposerTextController
        ? (widget.controller as ComposerTextController).files : const <ComposerFileReference>[];
    final output = StringBuffer();
    final references = <_Reference>[];
    var offset = 0;
    for (final file in files) {
      output.write(next.text.substring(offset, file.offset));
      final label = '${file.skillName == null ? '@' : r'$'}${file.label}';
      final start = output.length;
      output.write(label);
      references.add((start: start, end: output.length, file: file));
      offset = file.offset + 1;
    }
    output.write(next.text.substring(offset));
    final display = files.isEmpty ? next.text : output.toString();
    final changed = display != _display;
    _syncing = true;
    try {
      final oldSelection = _code.selection;
      final oldLines = _lines;
      final oldDisplay = _display;
      _references = references;
      if (changed) {
        // Keep the editor's undo history for programmatic paste, dictation and
        // completion. The same history entry retains the reference identities.
        final edit = composerReplacement(TextEditingValue(text: oldDisplay,
          selection: _selection(_code.value, oldLines)),
          TextEditingValue(text: display, selection: TextSelection.collapsed(offset: display.length)));
        final from = _position(edit.start), to = _position(edit.end);
        _code.replaceSelection(display.substring(edit.start, edit.start + edit.inserted),
          CodeLineSelection(baseIndex: from.index, baseOffset: from.offset,
            extentIndex: to.index, extentOffset: to.offset));
      }
      _display = display;
      _lines = _lineOffsets(_code.codeLines);
      if (next.selection.isValid) {
        final base = _position(_toDisplay(next.selection.baseOffset));
        final extent = _position(_toDisplay(next.selection.extentOffset));
        _code.selection = CodeLineSelection(baseIndex: base.index, baseOffset: base.offset,
          extentIndex: extent.index, extentOffset: extent.offset, extentAffinity: next.selection.affinity);
      } else if (!changed) {
        _code.selection = oldSelection;
      }
      _raw = next;
      _previous = _code.value;
      _snapshots[_code.codeLines] = List.of(_references);
      if (changed) _measure();
    } finally { _syncing = false; }
    if (changed && widget.focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _code.makeCursorVisible(); });
    }
  }

  void _edited() {
    if (_syncing) return;
    var next = _code.value;
    final before = _previous!;
    if (next == before) return;
    final textChanged = !identical(next.codeLines, before.codeLines);
    final beforeSelection = _selection(before, _lines);
    if (!textChanged && _references.isNotEmpty) {
      final selection = _selection(next, _lines);
      int snap(int offset, bool end) {
        for (final ref in _references) {
          if (offset > ref.start && offset < ref.end) return end ? ref.end : ref.start;
        }
        return offset;
      }
      final forward = selection.baseOffset <= selection.extentOffset;
      final base = snap(selection.baseOffset, selection.isCollapsed
        ? selection.extentOffset > beforeSelection.extentOffset : !forward);
      final extent = selection.isCollapsed ? base : snap(selection.extentOffset, forward);
      if (base != selection.baseOffset || extent != selection.extentOffset) {
        final from = _position(base), to = _position(extent);
        _syncing = true;
        try {
          _code.selection = CodeLineSelection(baseIndex: from.index, baseOffset: from.offset,
            extentIndex: to.index, extentOffset: to.offset);
          next = _code.value;
        } finally { _syncing = false; }
      }
    }
    if (textChanged) {
      final display = _code.text;
      final lines = _lineOffsets(next.codeLines);
      final restored = _snapshots[next.codeLines];
      if (restored != null) {
        _references = List.of(restored);
      } else if (_references.isNotEmpty) {
        final edit = composerReplacement(TextEditingValue(text: _display, selection: beforeSelection),
          TextEditingValue(text: display, selection: _selection(next, lines)));
        final delta = edit.inserted - (edit.end - edit.start);
        _references = [
          for (final ref in _references)
            if (ref.end <= edit.start) ref
            else if (ref.start >= edit.end)
              (start: ref.start + delta, end: ref.end + delta, file: ref.file),
        ];
      }
      _display = display;
      _lines = lines;
    }
    final selection = _selection(next, _lines);
    final output = StringBuffer();
    final files = <ComposerFileReference>[];
    final refs = <_Reference>[];
    var offset = 0;
    for (final ref in _references) {
      output.write(_display.substring(offset, ref.start));
      final file = ComposerFileReference(output.length, ref.file.path,
        skillName: ref.file.skillName, title: ref.file.title, prompt: ref.file.prompt);
      files.add(file);
      refs.add((start: ref.start, end: ref.end, file: file));
      output.write(ComposerTextController.marker);
      offset = ref.end;
    }
    _references = refs;
    output.write(_display.substring(offset));
    final composingStart = next.composing.isValid ? _lines[next.selection.extentIndex] + next.composing.start : -1;
    final composingEnd = next.composing.isValid ? _lines[next.selection.extentIndex] + next.composing.end : -1;
    final raw = TextEditingValue(text: files.isEmpty ? _display : output.toString(),
      selection: TextSelection(baseOffset: _toRaw(selection.baseOffset), extentOffset: _toRaw(selection.extentOffset),
        affinity: selection.affinity),
      composing: composingStart >= 0 && composingEnd <= _display.length
          ? TextRange(start: _toRaw(composingStart), end: _toRaw(composingEnd)) : TextRange.empty);
    _syncing = true;
    try {
      if (widget.controller is ComposerTextController) {
        (widget.controller as ComposerTextController).applyEditorValue(raw, files);
      } else {
        widget.controller.value = raw;
      }
      _raw = raw;
      _previous = next;
      _snapshots[next.codeLines] = List.of(_references);
    } finally { _syncing = false; }
    if (textChanged) _measure();
  }

  TextSpan _span({required BuildContext context, required int index, required CodeLine codeLine,
      required TextSpan textSpan, required TextStyle style}) {
    final start = index < _lines.length ? _lines[index] : 0;
    final refs = _references.where((ref) => ref.start >= start && ref.end <= start + codeLine.length);
    if (refs.isEmpty) return textSpan;
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final ref in refs) {
      spans.add(TextSpan(text: codeLine.text.substring(offset, ref.start - start)));
      spans.add(TextSpan(text: codeLine.text.substring(ref.start - start, ref.end - start),
        style: const TextStyle(color: inlineReferenceAccent, fontWeight: FontWeight.w500)));
      offset = ref.end - start;
    }
    spans.add(TextSpan(text: codeLine.text.substring(offset)));
    return TextSpan(style: style, children: spans);
  }

  // Only measure enough text to fill the eight-line viewport. Never lay out a
  // large draft merely to decide the height of its composer.
  void _measure() {
    if (_width <= 0) return;
    if (_code.codeLines.length >= 8) { _height.value = 180; return; }
    var height = 0.0, count = 0;
    for (final segment in _code.codeLines.segments) {
      for (final line in segment.codeLines) {
        if (line.length > 1200) { _height.value = 180; return; }
        final painter = TextPainter(text: TextSpan(text: line.text.isEmpty ? ' ' : line.text,
          style: const TextStyle(fontFamily: 'Inter', fontSize: 13, height: 20 / 13)),
          textDirection: TextDirection.ltr, textScaler: _scaler)..layout(maxWidth: (_width - 32).clamp(1, double.infinity));
        height += painter.height;
        painter.dispose();
        if (++count >= 8 || height >= 156) { _height.value = 180; return; }
      }
    }
    _height.value = (height + 24).clamp(44, 180);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_pull);
    _code.dispose();
    _height.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final completing = ComposerAutocompleteScope.of(context);
    final autocomplete = ComposerAutocompleteScope.ownerOf(context);
    final toolbar = MobileSelectionToolbarController(builder: ({required context, required anchors,
        required controller, required onDismiss, required onRefresh}) => AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: [
        ContextMenuButtonItem(type: ContextMenuButtonType.cut, onPressed: () { onDismiss(); unawaited(widget.copy(cut: true)); }),
        ContextMenuButtonItem(type: ContextMenuButtonType.copy, onPressed: () { onDismiss(); unawaited(widget.copy()); }),
        ContextMenuButtonItem(type: ContextMenuButtonType.paste, onPressed: () { onDismiss(); unawaited(widget.paste(SelectionChangedCause.toolbar)); }),
        ContextMenuButtonItem(type: ContextMenuButtonType.selectAll, onPressed: () { onDismiss(); controller.selectAll(); }),
      ],
    ));
    return LayoutBuilder(builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      if (_width != constraints.maxWidth || _scaler != scaler) {
        _width = constraints.maxWidth;
        _scaler = scaler;
        _measure();
      }
      return ValueListenableBuilder<double>(valueListenable: _height, builder: (context, height, _) => SizedBox(
        height: height,
        child: Semantics(label: 'Message', textField: true, multiline: true,
          child: CodeEditor(key: const ValueKey('composer-editor'), controller: _code,
            focusNode: widget.focusNode, autofocus: true, readOnly: !widget.enabled,
            wordWrap: true, autocompleteSymbols: false, chunkAnalyzer: const NonCodeChunkAnalyzer(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            hint: 'Ask anything, / for commands, @ for context…',
            style: const CodeEditorStyle(fontFamily: 'Inter', fontSize: 13, fontHeight: 20 / 13,
              textColor: opencodeInk, hintTextColor: opencodeFaint, backgroundColor: Colors.transparent,
              cursorColor: opencodeInk, cursorWidth: 1.5, cursorLineColor: Colors.transparent,
              selectionColor: Color(0x332e82d2)),
            shortcutsActivatorsBuilder: _ComposerShortcuts(completing), toolbarController: toolbar,
            shortcutOverrideActions: {
              CodeShortcutCursorMoveIntent: _ComposerAction<CodeShortcutCursorMoveIntent>(_code, onInvoke: (intent) {
                if ((intent.direction == AxisDirection.up || intent.direction == AxisDirection.down) &&
                    autocomplete?.moveSelection(intent.direction == AxisDirection.down ? 1 : -1) == true) { return null; }
                _code.moveCursor(intent.direction);
                return null;
              }),
              CodeShortcutSelectionExtendIntent: _ComposerAction<CodeShortcutSelectionExtendIntent>(_code, onInvoke: (intent) {
                if (intent.direction == AxisDirection.up && autocomplete != null) { autocomplete.openHistory(); }
                else { _code.extendSelection(intent.direction); }
                return null;
              }),
              CodeShortcutIndentIntent: _ComposerAction<CodeShortcutIndentIntent>(_code, enabled: widget.enabled, onInvoke: (_) {
                if (autocomplete?.completeSelection() != true) _code.applyIndent();
                return null;
              }),
              CodeShortcutDeleteIntent: _ComposerAction<CodeShortcutDeleteIntent>(_code, enabled: widget.enabled, onInvoke: (intent) {
                final selection = _selection(_code.value, _lines);
                if (selection.isCollapsed) {
                  for (final ref in _references) {
                    if (selection.start == (intent.forward ? ref.start : ref.end)) {
                      final from = _position(ref.start), to = _position(ref.end);
                      _code.replaceSelection('', CodeLineSelection(baseIndex: from.index, baseOffset: from.offset,
                        extentIndex: to.index, extentOffset: to.offset));
                      return null;
                    }
                  }
                }
                if (intent.forward) { _code.deleteForward(); } else { _code.deleteBackward(); }
                return null;
              }),
              CodeShortcutPasteIntent: _ComposerAction<CodeShortcutPasteIntent>(_code, enabled: widget.enabled, onInvoke: (_) { unawaited(widget.paste(SelectionChangedCause.keyboard)); return null; }),
              CodeShortcutCopyIntent: _ComposerAction<CodeShortcutCopyIntent>(_code, onInvoke: (_) { unawaited(widget.copy()); return null; }),
              CodeShortcutCutIntent: _ComposerAction<CodeShortcutCutIntent>(_code, enabled: widget.enabled, onInvoke: (_) { unawaited(widget.copy(cut: true)); return null; }),
              ReplaceTextIntent: CallbackAction<ReplaceTextIntent>(onInvoke: (intent) {
                final value = _raw;
                if (value == intent.currentTextEditingValue) {
                  widget.controller.value = TextEditingValue(text: value.text.replaceRange(intent.replacementRange.start,
                    intent.replacementRange.end, intent.replacementText),
                    selection: TextSelection.collapsed(offset: intent.replacementRange.start + intent.replacementText.length));
                }
                return null;
              }),
            },
          ),
        ),
      ));
    });
  }
}

// Keep native IME candidate navigation outside the composer's shortcuts.
class _ComposerAction<T extends Intent> extends CallbackAction<T> {
  _ComposerAction(this.controller, {this.enabled = true, required super.onInvoke});
  final CodeLineEditingController controller;
  final bool enabled;

  @override
  bool consumesKey(T intent) => !controller.isComposing;

  @override
  Object? invoke(T intent) => enabled && !controller.isComposing ? super.invoke(intent) : null;
}

class _ComposerShortcuts extends DefaultCodeShortcutsActivatorsBuilder {
  const _ComposerShortcuts(this.completing);
  final bool completing;

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) => switch (type) {
    CodeShortcutType.newLine || CodeShortcutType.esc || CodeShortcutType.lineMoveUp ||
    CodeShortcutType.lineMoveDown || CodeShortcutType.lineDelete || CodeShortcutType.singleLineComment ||
    CodeShortcutType.multiLineComment || CodeShortcutType.save || CodeShortcutType.find ||
    CodeShortcutType.replace || CodeShortcutType.lineSelect => const [],
    CodeShortcutType.outdent when completing => const [],
    _ => super.build(type),
  };
}
