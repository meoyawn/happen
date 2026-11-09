import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectionRegistrar;
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;

import 'response_annotation.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'appearance.dart';

/// Inline references ported from harness/client.
/// Let Markdown own escaping, code spans and fenced blocks before rendering.
class ResponseAnnotationSyntax extends md.InlineSyntax {
  ResponseAnnotationSyntax() : super(r':codex-annotation\{([^}\n]*)\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final attributes = RegExp(r'''(?:^|\s)index\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"']+))''').firstMatch(match[1]!);
    final node = md.Element.empty('codex-annotation');
    node.attributes['index'] = attributes?[1] ?? attributes?[2] ?? attributes?[3] ?? '';
    parser.addNode(node);
    return true;
  }
}

ResponseAnnotation? resolveResponseAnnotation(String? index, List<ResponseAnnotation> annotations) {
  final number = int.tryParse(index ?? '');
  if (number == null || number < 1 || number > 9007199254740991 || '$number' != index || number > annotations.length) return null;
  return annotations[number - 1];
}

class ResponseAnnotationReference extends StatefulWidget {
  const ResponseAnnotationReference({super.key, required this.number, required this.annotation, required this.style, this.onNavigate,
    this.selectionRegistrar});
  final int number;
  final ResponseAnnotation annotation;
  final TextStyle style;
  final Future<bool> Function(ResponseAnnotation annotation)? onNavigate;
  final SelectionRegistrar? selectionRegistrar;
  @override
  State<ResponseAnnotationReference> createState() => _ResponseAnnotationReferenceState();
}

class _ResponseAnnotationReferenceState extends State<ResponseAnnotationReference> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  Timer? _delay;
  bool _hovered = false;

  void _enter() {
    _delay?.cancel();
    if (!_portal.isShowing) _delay = Timer(const Duration(milliseconds: 200), () { if (mounted) _portal.show(); });
  }

  void _leave() {
    _delay?.cancel();
    _delay = Timer(const Duration(milliseconds: 100), _hide);
  }

  void _hide() {
    _delay?.cancel();
    if (mounted && _portal.isShowing) _portal.hide();
  }

  Future<void> _activate() async {
    final showing = _portal.isShowing;
    if (widget.annotation.messageId != null && widget.onNavigate != null) {
      _hide();
      if (await widget.onNavigate!(widget.annotation) || !mounted) return;
    }
    _delay?.cancel();
    if (showing) { _portal.hide(); } else { _portal.show(); }
  }

  Widget _preview(BuildContext context) {
    final target = this.context.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (target is! RenderBox || !target.hasSize || overlay is! RenderBox || !overlay.hasSize) return const SizedBox.shrink();
    final origin = overlay.globalToLocal(target.localToGlobal(Offset.zero));
    final multiline = widget.annotation.text.contains('\n');
    final width = math.min(multiline ? 448.0 : 320.0, math.max(0.0, overlay.size.width - 16));
    final below = overlay.size.height - origin.dy - target.size.height - 10;
    final above = origin.dy - 10;
    final down = below >= math.min(320.0, above);
    final height = math.max(0.0, math.min(320.0, down ? below : above));
    final left = origin.dx.clamp(8.0, math.max(8.0, overlay.size.width - width - 8));
    return Positioned(left: 0, top: 0, child: CompositedTransformFollower(link: _link, showWhenUnlinked: false,
      targetAnchor: down ? Alignment.bottomLeft : Alignment.topLeft,
      followerAnchor: down ? Alignment.topLeft : Alignment.bottomLeft,
      offset: Offset(left - origin.dx, down ? 2 : -2),
      child: CallbackShortcuts(bindings: {const SingleActivator(LogicalKeyboardKey.escape): _hide},
      child: TapRegion(groupId: this, onTapOutside: (_) => _hide(), child: MouseRegion(
        onEnter: (_) => _delay?.cancel(), onExit: (_) => _leave(),
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: width, maxHeight: height), child: IntrinsicWidth(
          child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(15),
            boxShadow: const [BoxShadow(color: Color(0x1f000000), offset: Offset(0, 8), blurRadius: 16, spreadRadius: -4)]),
          child: Material(color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: const BorderSide(color: Color(0x1f1a1c1f), width: .5)),
            child: DefaultTextStyle(style: const TextStyle(color: Color(0xff1a1c1f), fontSize: 13, height: 20 / 13),
              child: SelectionArea(child: SingleChildScrollView(primary: false, padding: const EdgeInsets.all(12),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Selected text:', style: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, color: Color(0x801a1c1f))),
                  const SizedBox(height: 2),
                  if (multiline) ConstrainedBox(constraints: const BoxConstraints(maxHeight: 192),
                    child: DecoratedBox(decoration: BoxDecoration(color: const Color(0x0d1a1c1f), borderRadius: BorderRadius.circular(6)),
                      child: SingleChildScrollView(primary: false, child: SingleChildScrollView(primary: false, scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Text(widget.annotation.text,
                          style: const TextStyle(fontFamily: 'Menlo', fontSize: 12, height: 16 / 12))))))
                  else Text(widget.annotation.text),
                  if (widget.annotation.annotation?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    const Text('User comment:', style: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, color: Color(0x801a1c1f))),
                    const SizedBox(height: 2), Text(widget.annotation.annotation!),
                  ],
                ])))),
          ))),
        ),
      )))));
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.annotation.text.split('\n').length;
    final label = 'Annotation ${widget.number}';
    final text = Text(label, style: widget.style.copyWith(color: DesktopAccent.of(context).reference,
      decoration: _hovered ? TextDecoration.underline : TextDecoration.none,
      decorationStyle: TextDecorationStyle.dashed, decorationThickness: .5));
    // Only the visible label belongs to the paragraph. The portal/preview keep
    // their existing selection boundary and mounted interaction state.
    final selectableLabel = widget.selectionRegistrar == null ? text
      : SelectionRegistrarScope(registrar: widget.selectionRegistrar!,
          child: DefaultSelectionStyle.merge(mouseCursor: SystemMouseCursors.click, child: text));
    return OverlayPortal(controller: _portal, overlayChildBuilder: _preview,
      child: CompositedTransformTarget(link: _link, child: TapRegion(groupId: this,
        child: MouseRegion(onEnter: (_) { setState(() => _hovered = true); _enter(); },
          onExit: (_) { setState(() => _hovered = false); _leave(); },
          child: Semantics(button: true, label: '$label: ${lines > 1 ? 'selected text, $lines lines' : widget.annotation.text}',
            excludeSemantics: true, child: CallbackShortcuts(bindings: {const SingleActivator(LogicalKeyboardKey.escape): _hide},
              child: InkWell(onTap: _activate, onFocusChange: (value) {
                if (!value) { _hide(); }
                else if (FocusManager.instance.highlightMode == FocusHighlightMode.traditional) { _portal.show(); }
              },
                hoverColor: Colors.transparent, highlightColor: Colors.transparent, splashColor: Colors.transparent,
                child: selectableLabel))),
        ),
      )),
    );
  }

  @override
  void dispose() { _delay?.cancel(); super.dispose(); }
}

class ResponseAnnotationContext extends InheritedWidget {
  const ResponseAnnotationContext({super.key, required this.annotations, required super.child});
  final List<ResponseAnnotation> annotations;
  static List<ResponseAnnotation> of(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<ResponseAnnotationContext>()?.annotations ?? const [];
  @override
  bool updateShouldNotify(ResponseAnnotationContext oldWidget) => annotations != oldWidget.annotations;
}

class ResponseAnnotationBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final index = element.attributes['index'];
    final annotation = resolveResponseAnnotation(index, ResponseAnnotationContext.of(context));
    final style = parentStyle ?? preferredStyle ?? DefaultTextStyle.of(context).style;
    if (annotation == null) return Text('Annotation ${index ?? ''}', style: style);
    return ResponseAnnotationReference(number: int.parse(index!), annotation: annotation, style: style,
      selectionRegistrar: SelectionContainer.maybeOf(context));
  }
}
