import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Code shares the paragraph's text and selection offsets. Its fill is painted
/// behind selection rather than by a span background on top of the highlight.
class InlineCodeTextSpan extends TextSpan {
  const InlineCodeTextSpan({required super.text, required super.style, required this.backgroundColor,
    super.recognizer, super.mouseCursor});
  final Color backgroundColor;
}

/// Inline controls belong to the same paragraph for triple-click selection.
class ParagraphSelection extends StatefulWidget {
  const ParagraphSelection({super.key, required this.child});
  final Widget child;

  @override
  State<ParagraphSelection> createState() => _ParagraphSelectionState();
}

class _ParagraphSelectionState extends State<ParagraphSelection> {
  final _delegate = _ParagraphSelectionDelegate();

  @override
  Widget build(BuildContext context) {
    _delegate.textDirection = Directionality.of(context);
    return SelectionContainer.maybeOf(context) == null
      ? widget.child : SelectionContainer(delegate: _delegate, child: widget.child);
  }

  @override
  void dispose() { _delegate.dispose(); super.dispose(); }
}

class _ParagraphSelectionDelegate extends StaticSelectionContainerDelegate {
  TextDirection textDirection = TextDirection.ltr;
  SelectAllSelectionEvent? _deferredSelectAll;
  bool _replayScheduled = false;
  bool _disposed = false;

  @override
  Comparator<Selectable> get compareOrder => _compareInlineOrder;

  int _compareInlineOrder(Selectable a, Selectable b) {
    final firstA = a.boundingBoxes.firstOrNull, firstB = b.boundingBoxes.firstOrNull;
    if (firstA == null || firstB == null) return 0;
    final rectA = MatrixUtils.transformRect(a.getTransformTo(null), firstA);
    final rectB = MatrixUtils.transformRect(b.getTransformTo(null), firstB);
    if (rectA.bottom <= rectB.top) return -1;
    if (rectB.bottom <= rectA.top) return 1;
    return textDirection == TextDirection.ltr
      ? rectA.left.compareTo(rectB.left) : rectB.right.compareTo(rectA.right);
  }

  @override
  SelectionResult handleSelectParagraph(SelectParagraphSelectionEvent event) {
    handleSelectAll(const SelectAllSelectionEvent());
    return SelectionResult.end;
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    _deferredSelectAll = null;
    return super.dispatchSelectionEvent(event);
  }

  @override
  SelectionResult dispatchSelectionEventToChild(Selectable selectable, SelectionEvent event) {
    final result = super.dispatchSelectionEventToChild(selectable, event);
    if (event is SelectAllSelectionEvent && result == SelectionResult.pending) _deferredSelectAll = event;
    return result;
  }

  @override
  SelectionResult handleSelectAll(SelectAllSelectionEvent event) {
    _deferredSelectAll = null;
    final result = super.handleSelectAll(event);
    if (_deferredSelectAll == null) return result;
    _scheduleDeferredSelection();
    return SelectionResult.pending;
  }

  void _scheduleDeferredSelection() {
    if (_deferredSelectAll == null || _replayScheduled || _disposed) return;
    _replayScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _replayScheduled = false;
      final event = _deferredSelectAll;
      if (event == null || _disposed) return;
      if (selectables.any((child) => child is _LaidOutSelectable && !child.ready())) return;
      selectables.sort(compareOrder);
      dispatchSelectionEvent(event);
    });
    // Retry once after layout; lazy children notify us when they are laid out.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() { _disposed = true; _deferredSelectAll = null; super.dispose(); }
}

/// Lazy transcript children must not expose selection geometry before layout.
class LaidOutSelectableRichText extends RichText {
  LaidOutSelectableRichText({super.key, required super.text, super.textAlign, super.softWrap,
    super.overflow, super.textScaler, super.maxLines, super.textWidthBasis, super.strutStyle,
    super.textHeightBehavior, super.selectionRegistrar, super.selectionColor});

  @override
  RenderParagraph createRenderObject(BuildContext context) => _LaidOutSelectionParagraph(
    text, textAlign: textAlign, textDirection: Directionality.of(context),
    softWrap: softWrap, overflow: overflow, textScaler: textScaler, maxLines: maxLines,
    textWidthBasis: textWidthBasis, textHeightBehavior: textHeightBehavior, strutStyle: strutStyle,
    locale: Localizations.maybeLocaleOf(context), selectionColor: selectionColor,
    registrar: selectionRegistrar,
    devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? View.of(context).devicePixelRatio);
}

class _LaidOutSelectionParagraph extends RenderParagraph {
  _LaidOutSelectionParagraph(super.text, {required super.textDirection, super.textAlign,
    super.softWrap, super.overflow, super.textScaler, super.maxLines, super.textWidthBasis,
    super.textHeightBehavior, super.strutStyle, super.locale, super.selectionColor, super.devicePixelRatio,
    SelectionRegistrar? registrar}) : super(registrar: null) { this.registrar = registrar; }

  SelectionRegistrar? _selectionOwner;
  final _fragments = _LaidOutSelectionRegistrar();
  bool _selectionLayoutReady = false;
  InlineSpan? _codeSpanTree;
  List<({TextRange range, Color color})> _cachedCodeRanges = const [];
  String _codePlainText = '';

  List<({TextRange range, Color color})> get _codeRanges {
    if (identical(_codeSpanTree, text)) return _cachedCodeRanges;
    final ranges = <({TextRange range, Color color})>[];
    var offset = 0;
    void visit(InlineSpan span) {
      if (span is TextSpan) {
        final start = offset;
        offset += span.text?.length ?? 0;
        if (span is InlineCodeTextSpan && offset > start) {
          ranges.add((range: TextRange(start: start, end: offset), color: span.backgroundColor));
        }
        for (final child in span.children ?? const <InlineSpan>[]) { visit(child); }
      } else if (span is PlaceholderSpan) { offset++; }
    }
    visit(text);
    _codeSpanTree = text;
    _codePlainText = text.toPlainText(includeSemanticsLabels: false);
    return _cachedCodeRanges = ranges;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final ranges = _codeRanges;
    if (ranges.isNotEmpty) {
      final canvas = context.canvas;
      canvas.save();
      if (overflow != TextOverflow.visible) canvas.clipRect(offset & size);
      for (final code in ranges) {
        final range = code.range;
        final whitespace = <Rect>[];
        for (final index in [range.start - 1, range.end]) {
          if (index < 0 || index >= _codePlainText.length || _codePlainText[index].trim().isNotEmpty) continue;
          whitespace.addAll(getBoxesForSelection(TextSelection(baseOffset: index, extentOffset: index + 1))
            .map((box) => box.toRect()));
        }
        for (final box in getBoxesForSelection(TextSelection(baseOffset: range.start, extentOffset: range.end))) {
          final rect = box.toRect();
          var left = rect.left, right = rect.right;
          for (final space in whitespace) {
            if (space.bottom <= rect.top || space.top >= rect.bottom) continue;
            if ((space.right - rect.left).abs() < .01) left = math.max(rect.left - 6, space.center.dx);
            if ((space.left - rect.right).abs() < .01) right = math.min(rect.right + 6, space.center.dx);
          }
          final bounds = Rect.fromLTRB(left, rect.top - 1, right, rect.bottom + 1).shift(offset);
          canvas.drawRRect(RRect.fromRectAndRadius(bounds, const Radius.circular(6)), Paint()..color = code.color);
        }
      }
      canvas.restore();
    }
    super.paint(context, offset);
  }

  @override
  SelectionRegistrar? get registrar => _selectionOwner;

  @override
  set registrar(SelectionRegistrar? value) {
    _selectionOwner = value;
    _fragments.ready = () => _selectionLayoutReady && attached;
    super.registrar = value == null ? null : _fragments;
    _fragments.publishTo(attached && (_selectionLayoutReady || _fragments.hasOwner) ? value : null);
  }

  @override
  void markNeedsLayout() { _selectionLayoutReady = false; super.markNeedsLayout(); }

  @override
  void performLayout() {
    super.performLayout();
    _selectionLayoutReady = true;
    _fragments.ready = () => _selectionLayoutReady && attached;
    super.registrar = _selectionOwner == null ? null : _fragments;
    _fragments.publishTo(_selectionOwner);
    final owner = _selectionOwner;
    if (owner is _ParagraphSelectionDelegate) owner._scheduleDeferredSelection();
  }

  @override
  void attach(PipelineOwner owner) { super.attach(owner); markNeedsLayout(); }

  @override
  void detach() { _selectionLayoutReady = false; _fragments.publishTo(null); super.detach(); }

  @override
  void dispose() { _selectionOwner = null; super.dispose(); }
}

/// Retain fragment identities through relayout, but withhold invalid geometry.
class _LaidOutSelectionRegistrar implements SelectionRegistrar {
  final _selectables = <Selectable, _LaidOutSelectable>{};
  SelectionRegistrar? _owner;
  bool Function()? ready;
  bool get hasOwner => _owner != null;

  void publishTo(SelectionRegistrar? owner) {
    if (identical(owner, _owner)) return;
    for (final fragment in _selectables.values) { _owner?.remove(fragment); }
    _owner = owner;
    for (final fragment in _selectables.values) { _owner?.add(fragment); }
  }

  @override
  void add(Selectable selectable) {
    if (_selectables.containsKey(selectable)) return;
    final fragment = _LaidOutSelectable(selectable, () => ready?.call() ?? false);
    _selectables[selectable] = fragment;
    _owner?.add(fragment);
  }

  @override
  void remove(Selectable selectable) {
    final fragment = _selectables.remove(selectable);
    if (fragment == null) return;
    _owner?.remove(fragment);
    fragment.dispose();
  }
}

class _LaidOutSelectable extends ChangeNotifier with Selectable {
  _LaidOutSelectable(this.fragment, this.ready) { fragment.addListener(notifyListeners); }
  final Selectable fragment;
  final bool Function() ready;

  @override
  SelectionGeometry get value => fragment.value;
  @override
  int get contentLength => fragment.contentLength;
  @override
  Size get size => ready() ? fragment.size : Size.zero;
  @override
  List<Rect> get boundingBoxes => ready() ? fragment.boundingBoxes : const [];
  @override
  Matrix4 getTransformTo(RenderObject? ancestor) => fragment.getTransformTo(ancestor);
  @override
  SelectedContent? getSelectedContent() => fragment.getSelectedContent();
  @override
  SelectedContentRange? getSelection() => fragment.getSelection();
  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) =>
    fragment.pushHandleLayers(startHandle, endHandle);
  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) =>
    ready() || event is ClearSelectionEvent ? fragment.dispatchSelectionEvent(event) : SelectionResult.pending;

  @override
  void dispose() { fragment.removeListener(notifyListeners); super.dispose(); }
}
