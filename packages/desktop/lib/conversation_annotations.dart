import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent, SelectionStatus;
import 'package:flutter/services.dart';

import 'appearance.dart';
import 'composer_dictation.dart';
import 'dictation.dart';
import 'dictation_state.dart';
import 'dictation_controls.dart';
import 'response_annotation.dart';
import 'session.dart';

/// Each main or side composer owns its draft and the lifetime of its popover.
class ConversationAnnotationScope extends InheritedWidget {
  const ConversationAnnotationScope({super.key, required this.onAdd, required this.onEdit,
    required this.readAnnotations, required this.changes, required this.enabled, required super.child});
  final void Function(ResponseAnnotation annotation, Offset anchor) onAdd;
  final ValueChanged<ResponseAnnotation> onEdit;
  final List<ResponseAnnotation> Function() readAnnotations;
  final Listenable changes;
  final bool enabled;
  static ConversationAnnotationScope? maybeOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<ConversationAnnotationScope>();
  @override
  bool updateShouldNotify(ConversationAnnotationScope oldWidget) => onAdd != oldWidget.onAdd || onEdit != oldWidget.onEdit ||
    changes != oldWidget.changes || enabled != oldWidget.enabled;
}

class AnnotationWorkspace extends StatefulWidget {
  const AnnotationWorkspace({super.key, required this.session, required this.draftKey,
    required this.child, this.active = true, this.onReturnFocus});
  final DesktopSession session;
  final String draftKey;
  final Widget child;
  final bool active;
  final VoidCallback? onReturnFocus;
  @override
  State<AnnotationWorkspace> createState() => _AnnotationWorkspaceState();
}

class _AnnotationWorkspaceState extends State<AnnotationWorkspace> {
  OverlayEntry? _editor;
  FocusNode? _previousFocus;
  String? _editingId;

  @override
  void initState() {
    super.initState();
    widget.session.annotationChanges.addListener(_annotationsChanged);
  }

  void _annotationsChanged() {
    if (_editingId != null && !widget.session.annotationsFor(widget.draftKey).any((item) => item.id == _editingId)) {
      _close();
    }
  }

  void _close({bool restoreFocus = true}) {
    final editor = _editor;
    _editor = null;
    _editingId = null;
    editor?.remove(); editor?.dispose();
    if (editor != null && restoreFocus && mounted) {
      if (widget.onReturnFocus case final restore?) { restore(); }
      else if (_previousFocus?.context?.mounted == true) { _previousFocus?.requestFocus(); }
    }
    _previousFocus = null;
  }

  void _add(ResponseAnnotation annotation, Offset anchor) {
    if (!widget.active) return;
    widget.session.putAnnotation(widget.draftKey, annotation);
    _open(annotation, anchor, creating: true);
  }

  void _edit(ResponseAnnotation annotation) {
    final box = context.findRenderObject();
    final anchor = box is RenderBox && box.hasSize
      ? box.localToGlobal(Offset(math.max(16, box.size.width / 2 - 147), math.max(16, box.size.height - 240)))
      : const Offset(24, 80);
    _open(annotation, anchor);
  }

  void _open(ResponseAnnotation annotation, Offset anchor, {bool creating = false}) {
    if (!widget.active) return;
    _close(restoreFocus: false);
    final session = widget.session, draft = widget.draftKey;
    _editingId = annotation.id;
    _previousFocus = FocusManager.instance.primaryFocus;
    final overlay = Overlay.of(context);
    final render = overlay.context.findRenderObject();
    final point = render is RenderBox ? render.globalToLocal(anchor) : anchor;
    _editor = OverlayEntry(builder: (context) => Positioned.fill(child: CustomSingleChildLayout(
      delegate: _AnnotationEditorLayout(point), child: ResponseAnnotationEditor(
        key: ValueKey(annotation.id), service: session.dictation, liveTranscription: session.dictationMode == 'live',
        annotation: annotation, creating: creating,
        onChanged: (value) => session.putAnnotation(draft, value),
        onRemove: () => session.removeAnnotation(draft, annotation.id), onClose: _close,
      ))));
    overlay.insert(_editor!);
  }

  @override
  void didUpdateWidget(AnnotationWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.annotationChanges.removeListener(_annotationsChanged);
      widget.session.annotationChanges.addListener(_annotationsChanged);
    }
    if (oldWidget.session != widget.session || oldWidget.draftKey != widget.draftKey || !widget.active) _close(restoreFocus: false);
  }
  @override
  Widget build(BuildContext context) => ConversationAnnotationScope(onAdd: _add, onEdit: _edit,
    readAnnotations: () => widget.session.annotationsFor(widget.draftKey),
    changes: widget.session.annotationChanges, enabled: widget.active, child: widget.child);
  @override
  void dispose() {
    widget.session.annotationChanges.removeListener(_annotationsChanged);
    _close(restoreFocus: false); super.dispose();
  }
}

class _AnnotationEditorLayout extends SingleChildLayoutDelegate {
  const _AnnotationEditorLayout(this.anchor);
  final Offset anchor;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints(
    maxWidth: math.max(0, math.min(294, constraints.maxWidth - 16)), maxHeight: math.max(0, constraints.maxHeight - 16));
  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    anchor.dx.clamp(8, math.max(8, size.width - childSize.width - 8)).toDouble(),
    (anchor.dy + 12).clamp(8, math.max(8, size.height - childSize.height - 8)).toDouble());
  @override
  bool shouldRelayout(_AnnotationEditorLayout oldDelegate) => anchor != oldDelegate.anchor;
}

class _AnnotationControl extends StatelessWidget {
  const _AnnotationControl({required this.child, this.onPressed, this.primary = false,
    this.enabled = true, this.uniform = false, this.padding = EdgeInsets.zero});
  final Widget child;
  final VoidCallback? onPressed;
  final bool primary, enabled, uniform;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Material(color: primary ? desktopForeground : Colors.transparent,
    borderRadius: BorderRadius.circular(999), child: InkWell(borderRadius: BorderRadius.circular(999),
      onTap: enabled ? onPressed : null, child: SizedBox(height: 28, width: uniform ? 28 : null,
        child: Padding(padding: padding, child: Center(widthFactor: 1, child: child)))));
}

class ResponseAnnotationAttachments extends StatelessWidget {
  const ResponseAnnotationAttachments({super.key, required this.annotations, this.onEdit, this.onRemove});
  final List<ResponseAnnotation> annotations;
  final ValueChanged<ResponseAnnotation>? onEdit;
  final ValueChanged<String>? onRemove;
  @override
  Widget build(BuildContext context) => ConstrainedBox(constraints: const BoxConstraints(maxHeight: 156),
    child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 0), child: Column(
      mainAxisSize: MainAxisSize.min, children: [for (final (index, annotation) in annotations.indexed)
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Material(color: desktopMuted,
          borderRadius: BorderRadius.circular(8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: InkWell(onTap: onEdit == null ? null : () => onEdit!(annotation),
              borderRadius: BorderRadius.circular(8), child: Padding(padding: const EdgeInsets.all(10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${index + 1}.', style: const TextStyle(fontSize: 12, color: desktopSecondary)), const SizedBox(width: 8),
                if (annotation.browser != null) const Padding(padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.near_me_outlined, size: 14, color: desktopSecondary)),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(annotation.text, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: desktopSecondary)),
                  if (annotation.browser case final browser?) Text(browser.pageUrl, maxLines: 1,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: desktopTertiary)),
                  if (annotation.annotation case final comment?) Padding(padding: const EdgeInsets.only(top: 4),
                    child: Text(comment, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                ])),
              ])))),
            if (onRemove != null) IconButton(tooltip: 'Remove annotation ${index + 1}',
              onPressed: () => onRemove!(annotation.id), visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 14, color: desktopSecondary)),
          ]))),
    ])));
}

/// One selection owner per conversation, with ranges scoped to response bodies.
class ConversationAnnotationSelection extends StatefulWidget {
  const ConversationAnnotationSelection({super.key, required this.child, this.onAdd, this.onSideChat, this.onSelectionChanged});
  final Widget child;
  final void Function(ResponseAnnotation annotation, Offset point)? onAdd;
  final ValueChanged<String>? onSideChat;
  final ValueChanged<String>? onSelectionChanged;
  static bool contains(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_AnnotationSelectionScope>() != null;
  @override
  State<ConversationAnnotationSelection> createState() => _ConversationAnnotationSelectionState();
}

class _ConversationAnnotationSelectionState extends State<ConversationAnnotationSelection> {
  final _area = GlobalKey<SelectionAreaState>();
  final _targets = <_ConversationAnnotationTargetState>{};
  String _selected = '';
  OverlayEntry? _toolbar;
  bool _dragging = false;
  int _generation = 0;
  SelectionContainerDelegate? _selectionContent;
  Timer? _settling;

  void _bindSelectionContent(BuildContext targetContext) {
    SelectionContainerDelegate? content;
    targetContext.visitAncestorElements((element) {
      if (element.widget is SelectableRegion) return false;
      final widget = element.widget;
      if (widget is SelectionContainer && widget.delegate != null) content = widget.delegate;
      return true;
    });
    if (identical(content, _selectionContent)) return;
    _selectionContent?.removeListener(_refreshSelectionContent);
    _selectionContent = content;
    _selectionContent?.addListener(_refreshSelectionContent);
  }

  void _refreshSelectionContent() {
    if (mounted) _selectionChanged(_selectionContent?.getSelectedContent());
  }

  void _selectionChanged(SelectedContent? content) {
    final selected = content?.plainText ?? '';
    if (selected == _selected) return;
    _selected = selected;
    widget.onSelectionChanged?.call(selected);
    if (_selected.trim().isEmpty) { _generation++; _hide(); } else if (!_dragging) { _schedule(); }
  }

  void _hide() { _toolbar?.remove(); _toolbar?.dispose(); _toolbar = null; }
  void _schedule() {
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || _dragging) return;
      // Nested selection delegates finish their post-frame updates in
      // microtasks. Read their ranges after that work has settled.
      _settling?.cancel();
      _settling = Timer(Duration.zero, () {
        _settling = null;
        if (mounted && generation == _generation && !_dragging) _show();
      });
    });
  }

  ResponseAnnotation? _selectionAnnotation() {
    final candidates = <(_ConversationAnnotationTargetState, int, int)>[];
    for (final target in _targets) {
      if (!target.mounted || !target.notifier.registered) continue;
      final selection = target.notifier.selection;
      if (selection.status != SelectionStatus.uncollapsed) continue;
      final range = selection.range;
      if (range != null && range.startOffset != range.endOffset) candidates.add((target, range.startOffset, range.endOffset));
    }
    if (candidates.length != 1 || _selected.trim().isEmpty) return null;
    final (target, start, end) = candidates.single;
    return target.widget.annotatable == false || target.widget.messageId.isEmpty ? null : ResponseAnnotation(
      id: UniqueKey().toString(), text: _selected.trim(), messageId: target.widget.messageId,
      startOffset: math.min(start, end), endOffset: math.max(start, end));
  }

  void _show() {
    _hide();
    if (_selected.trim().isEmpty || _area.currentState == null) return;
    final region = _area.currentState!.selectableRegion;
    final anchor = region.contextMenuAnchors.primaryAnchor;
    final selected = _selected;
    final annotation = _selectionAnnotation();
    void clear() { _hide(); region.hideToolbar(); region.clearSelection(); }
    _toolbar = OverlayEntry(builder: (context) => Positioned.fill(child: CustomSingleChildLayout(
      delegate: _AnnotationToolbarLayout(anchor),
      child: TapRegion(onTapOutside: (_) => _hide(), child: DecoratedBox(
        decoration: BoxDecoration(color: desktopSurface, borderRadius: BorderRadius.circular(999),
          border: Border.all(color: desktopBorder),
          boxShadow: const [BoxShadow(color: Color(0x1a000000), blurRadius: 15, spreadRadius: -3, offset: Offset(0, 10)),
            BoxShadow(color: Color(0x1a000000), blurRadius: 6, spreadRadius: -4, offset: Offset(0, 4))]),
        child: Padding(padding: const EdgeInsets.all(4), child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (annotation != null && widget.onAdd != null) _AnnotationTextAction(onPressed: () {
            clear(); widget.onAdd!(annotation, anchor);
          }, label: 'Add to chat'),
          if (widget.onSideChat != null) _AnnotationTextAction(onPressed: () {
            clear(); widget.onSideChat!(selected);
          }, label: 'Ask in side chat'),
          _AnnotationTextAction(onPressed: () { unawaited(Clipboard.setData(ClipboardData(text: selected))); clear(); }, label: 'Copy'),
        ])),
      )),
    )));
    Overlay.of(context).insert(_toolbar!);
  }

  @override
  Widget build(BuildContext context) => _AnnotationSelectionScope(owner: this, child: Listener(
    onPointerDown: (_) { _dragging = true; _generation++; _hide(); },
    onPointerUp: (_) { _dragging = false; _schedule(); },
    onPointerCancel: (_) { _dragging = false; _hide(); },
    onPointerSignal: (_) => _hide(),
    child: Focus(onKeyEvent: (_, event) {
      if (event.logicalKey == LogicalKeyboardKey.escape) { _hide(); return KeyEventResult.ignored; }
      if (event is KeyUpEvent) _schedule();
      return KeyEventResult.ignored;
    }, child: SelectionArea(key: _area,
      onSelectionChanged: _selectionChanged,
      contextMenuBuilder: (context, state) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors, buttonItems: [
          if (widget.onAdd != null && _selectionAnnotation() != null) ContextMenuButtonItem(label: 'Add to chat', onPressed: () {
            final annotation = _selectionAnnotation();
            final anchor = state.contextMenuAnchors.primaryAnchor;
            _hide(); state.hideToolbar(); state.clearSelection();
            if (annotation != null) widget.onAdd!(annotation, anchor);
          }),
          ...state.contextMenuButtonItems,
        ]), child: widget.child)),
  ));

  @override
  void dispose() {
    _settling?.cancel();
    _selectionContent?.removeListener(_refreshSelectionContent);
    _selectionContent = null;
    _generation++; _hide(); super.dispose();
  }
}

class _AnnotationToolbarLayout extends SingleChildLayoutDelegate {
  const _AnnotationToolbarLayout(this.anchor);
  final Offset anchor;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen().copyWith(maxWidth: math.max(0, constraints.maxWidth - 16));
  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (anchor.dx - childSize.width / 2).clamp(8, math.max(8, size.width - childSize.width - 8)).toDouble(),
    anchor.dy - childSize.height - 8 >= 8 ? anchor.dy - childSize.height - 8 : anchor.dy + 8);
  @override
  bool shouldRelayout(_AnnotationToolbarLayout oldDelegate) => oldDelegate.anchor != anchor;
}

class _AnnotationTextAction extends StatelessWidget {
  const _AnnotationTextAction({required this.label, this.onPressed, this.primary = false});
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  @override
  Widget build(BuildContext context) => Semantics(label: label, child: _AnnotationControl(
    onPressed: onPressed, primary: primary, enabled: onPressed != null,
    padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(label,
      style: TextStyle(inherit: false, decoration: TextDecoration.none, fontFamily: '.AppleSystemUIFont', fontFamilyFallback: const ['SF Pro Text', 'Segoe UI'],
        fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500,
        color: primary ? Colors.white : desktopForeground))));
}

class _AnnotationSelectionScope extends InheritedWidget {
  const _AnnotationSelectionScope({required this.owner, required super.child});
  final _ConversationAnnotationSelectionState owner;
  @override
  bool updateShouldNotify(_AnnotationSelectionScope oldWidget) => owner != oldWidget.owner;
}

class ConversationAnnotationTarget extends StatefulWidget {
  const ConversationAnnotationTarget({super.key, required this.messageId, required this.child, this.annotatable = true});
  final String messageId;
  final Widget child;
  final bool? annotatable;
  @override
  State<ConversationAnnotationTarget> createState() => _ConversationAnnotationTargetState();
}

class _ConversationAnnotationTargetState extends State<ConversationAnnotationTarget> {
  final notifier = SelectionListenerNotifier();
  _ConversationAnnotationSelectionState? _owner;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context.dependOnInheritedWidgetOfExactType<_AnnotationSelectionScope>()?.owner;
    if (identical(owner, _owner)) return;
    _owner?._targets.remove(this); _owner = owner; _owner?._targets.add(this);
  }
  @override
  Widget build(BuildContext context) {
    // Reuse the existing region's root delegate: deferred child selection can
    // finish after SelectableRegion's gesture-only onSelectionChanged callback.
    _owner?._bindSelectionContent(context);
    return SelectionListener(selectionNotifier: notifier, child: widget.child);
  }
  @override
  void dispose() { _owner?._targets.remove(this); notifier.dispose(); super.dispose(); }
}

class _DismissAnnotationIntent extends Intent {
  const _DismissAnnotationIntent();
}

class ResponseAnnotationEditor extends StatefulWidget {
  const ResponseAnnotationEditor({super.key, required this.service, required this.liveTranscription, required this.annotation,
    required this.onChanged, required this.onClose, required this.onRemove, this.creating = false});
  final DictationService service;
  final bool liveTranscription;
  final ResponseAnnotation annotation;
  final ValueChanged<ResponseAnnotation> onChanged;
  final VoidCallback onClose;
  final VoidCallback onRemove;
  final bool creating;
  @override
  State<ResponseAnnotationEditor> createState() => _ResponseAnnotationEditorState();
}

class _ResponseAnnotationEditorState extends State<ResponseAnnotationEditor> {
  late final _text = TextEditingController()..text = widget.annotation.annotation ?? '';
  final _focus = FocusNode();
  final _owner = Object();
  ComposerDictationSession? _session;
  bool _finishing = false;
  DictationService get _service => widget.service;
  bool get _owns => identical(_service.owner, _owner);
  bool get _busy => _owns && (_service.active || _finishing);
  @override
  void initState() {
    super.initState(); _service.addListener(_changed);
    _text.addListener(_bodyChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _focus.requestFocus(); });
  }
  void _bodyChanged() {
    widget.onChanged(widget.annotation.withComment(_text.text));
    if (mounted) setState(() {});
  }
  void _changed() {
    if (!mounted) return;
    if (_owns && (_service.state is DictationRecording || _service.state is DictationTranscribing)) {
      _session?.update(_service.transcript);
    } else if (_owns && _service.canRetry) { _session?.pauseForRecovery(); }
    setState(() {});
  }
  Future<void> _start() async {
    if (_service.active || _finishing) return;
    _session?.dispose();
    _session = ComposerDictationSession(_text, (range, value) {
      if (!mounted) return;
      _text.value = _text.value.copyWith(text: _text.text.replaceRange(range.start, range.end, value),
        selection: TextSelection.collapsed(offset: range.start + value.length), composing: TextRange.empty);
    });
    _focus.requestFocus();
    await _service.start(owner: _owner, liveTranscription: widget.liveTranscription, onRecordingLimit: () => unawaited(_finish()));
  }
  Future<void> _cancel() async {
    if (!_owns) return;
    _session?.dispose(cancel: true); _session = null;
    await _service.cancel();
    if (mounted) _focus.requestFocus();
  }
  Future<void> _finish({bool retry = false}) async {
    if (!_owns || _finishing) return;
    _finishing = true;
    setState(() {});
    try {
      final result = retry ? await _service.retry(DictationAction.insert) : await _service.stop(DictationAction.insert);
      if (!mounted || !_owns) return;
      if (result != null) {
        await _session?.finish(result.text);
        if (!mounted || !_owns) return;
        _session?.dispose(); _session = null;
      }
    } finally {
      _finishing = false;
      if (mounted) { setState(() {}); _focus.requestFocus(); }
    }
  }
  void _save() { if (!_busy) { widget.onChanged(widget.annotation.withComment(_text.text)); widget.onClose(); } }
  void _dismiss() {
    // Closing owns cancellation; preserve words already inserted by the stream.
    widget.onChanged(widget.annotation.withComment(_text.text)); widget.onClose();
  }
  @override
  Widget build(BuildContext context) {
    final phase = !_owns ? DictationUiPhase.idle : switch (_service.state) {
      DictationIdle() => _finishing ? DictationUiPhase.transcribing : DictationUiPhase.idle,
      DictationStarting() => DictationUiPhase.starting,
      DictationRecording() => DictationUiPhase.recording,
      DictationTranscribing() => DictationUiPhase.transcribing,
      DictationDisposed() => DictationUiPhase.idle,
      DictationFailed() => _service.canRetry ? DictationUiPhase.retry : DictationUiPhase.idle,
    };
    const style = TextStyle(inherit: false, fontFamily: '.AppleSystemUIFont', fontFamilyFallback: ['SF Pro Text', 'Segoe UI'],
      fontSize: 13, height: 24 / 13, letterSpacing: 0, wordSpacing: 0, fontWeight: FontWeight.w400,
      textBaseline: TextBaseline.alphabetic, leadingDistribution: TextLeadingDistribution.even,
      decoration: TextDecoration.none, color: Color(0xff1a1c1f));
    final text = _text.text;
    final hasText = text.trim().isNotEmpty;
    final measure = TextPainter(text: TextSpan(text: text, style: style), textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context))..layout();
    final error = _owns ? _service.error : null;
    final expanded = !widget.creating || error != null || hasText && (text.contains('\n') || measure.width + 12 > (_busy ? 188 : 234));
    measure.layout(maxWidth: 262);
    final height = expanded ? 60 + measure.height.clamp(24, 180).toDouble() + (error == null ? 0 : 36) : 44.0;
    measure.dispose();
    final showMicrophone = expanded || !hasText || _busy || _owns && _service.canRetry;
    final showSave = !_busy && (expanded || hasText);
    return TapRegion(onTapOutside: (_) { if (!_busy) _save(); }, child: Shortcuts(
      shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): _DismissAnnotationIntent()},
      child: Actions(actions: {_DismissAnnotationIntent: CallbackAction<_DismissAnnotationIntent>(onInvoke: (_) { _dismiss(); return null; })},
      child: Focus(onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || _text.value.composing.isValid && !_text.value.composing.isCollapsed) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _dismiss();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
        if (_owns && _service.state is DictationRecording) { unawaited(_finish()); } else { _save(); }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }, child: Material(type: MaterialType.transparency, child: DecoratedBox(
      decoration: BoxDecoration(color: desktopSurface, border: Border.all(color: desktopBorder, strokeAlign: BorderSide.strokeAlignOutside),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, spreadRadius: -1, offset: Offset(0, 2))]),
      child: SizedBox(width: 294, height: height, child: Stack(children: [
        Positioned(left: 16, right: expanded ? 16 : _busy ? 90 : 44, top: 10, bottom: expanded ? error == null ? 50 : 86 : 10,
          child: Stack(fit: StackFit.expand, children: [
            if (text.isEmpty) IgnorePointer(child: Text('Add an optional comment…', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: style.copyWith(color: desktopTertiary),
              strutStyle: const StrutStyle(fontFamily: '.AppleSystemUIFont', fontSize: 13, height: 24 / 13,
                leadingDistribution: TextLeadingDistribution.even, forceStrutHeight: true))),
            TextField(controller: _text, focusNode: _focus, minLines: null, maxLines: expanded ? null : 1, expands: expanded,
            textAlignVertical: TextAlignVertical.top, readOnly: _busy, showCursor: !_busy, style: style,
            cursorWidth: 1, cursorHeight: 15, cursorRadius: Radius.zero, cursorColor: desktopForeground,
            strutStyle: const StrutStyle(fontFamily: '.AppleSystemUIFont', fontSize: 13, height: 24 / 13,
              leadingDistribution: TextLeadingDistribution.even, forceStrutHeight: true),
            decoration: null),
          ])),
        if (error != null) Positioned(left: 16, right: 16, bottom: 46, height: 32,
          child: Text(error, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: desktopError))),
        Positioned(left: 8, right: expanded && !widget.creating ? 12 : 8, bottom: expanded ? 0 : 8, height: expanded ? 48 : 28, child: Row(children: [
          if (!widget.creating && !_busy) Tooltip(message: 'Remove annotation', child: _AnnotationControl(uniform: true,
            enabled: !_busy, onPressed: _busy ? null : () { widget.onRemove(); widget.onClose(); },
            child: const Icon(Icons.delete_outline_rounded, size: 16, color: desktopSecondary))),
          const Spacer(),
          if (!_busy && error != null) DictationCancelButton(onCancel: () => unawaited(_cancel())),
          if (showMicrophone) DictationButton(phase: phase, enabled: _owns || !_service.active, amplitude: _service.amplitude,
            cancelOnWaveformTap: true,
            onStart: () => unawaited(_start()), onStop: () => unawaited(_finish()), onCancel: () => unawaited(_cancel()),
            onRetry: () => unawaited(_finish(retry: true))),
          if (showMicrophone && showSave) const SizedBox(width: 8),
          if (showSave && widget.creating) Tooltip(message: 'Save annotation', child: Semantics(label: 'Save annotation',
            child: _AnnotationControl(primary: true, uniform: true, enabled: !_busy, onPressed: _busy ? null : _save,
              child: const Icon(Icons.check_rounded, size: 16, color: Colors.white))))
          else if (showSave) _AnnotationTextAction(label: 'Save', primary: true, onPressed: _busy ? null : _save),
        ])),
      ])),
    ),
    )))));
  }
  @override
  void dispose() {
    _service.removeListener(_changed);
    _session?.dispose(); _session = null;
    if (_owns) unawaited(_service.cancel());

    _text.removeListener(_bodyChanged); _text.dispose(); _focus.dispose(); super.dispose();
  }
}

