import 'package:flutter/material.dart';

import 'appearance.dart';

/// OpenCode's repeating text-shimmer.css sweep.
class ThinkingLabel extends StatefulWidget {
  const ThinkingLabel({super.key, this.label = 'Thinking', this.fontSize = 14, this.lineHeight});
  final String label;
  final double fontSize;
  final double? lineHeight;

  @override
  State<ThinkingLabel> createState() => _ThinkingLabelState();
}

class _ThinkingLabelState extends State<ThinkingLabel>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _synchronize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _synchronize();

  void _synchronize() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final visible = lifecycle == null || lifecycle == AppLifecycleState.resumed || lifecycle == AppLifecycleState.inactive;
    if (!visible || !TickerMode.valuesOf(context).enabled || MediaQuery.disableAnimationsOf(context)) {
      _sweep.reset();
      return;
    }
    if (!_sweep.isAnimating) _sweep.repeat();
  }

  @override
  void deactivate() {
    _sweep.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    WidgetsBinding.instance.addObserver(this);
  }

  TextStyle _style(Color color) => TextStyle(fontSize: widget.fontSize,
    height: (widget.lineHeight ?? 16) / widget.fontSize, color: color, letterSpacing: 0,
    fontVariations: const [FontVariation('wght', 530)]);

  Widget _text(Color color) => Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _style(color));

  @override
  Widget build(BuildContext context) {
    final double ch;
    {
      final measure = TextPainter(text: TextSpan(text: '0',
        style: DefaultTextStyle.of(context).style.merge(_style(opencodeInk))),
        textDirection: Directionality.of(context))..layout();
      ch = measure.width;
      measure.dispose();
    }
    return RepaintBoundary(child: Stack(children: [
    _text(const Color(0xff8f8f8f)),
    Positioned.fill(child: ExcludeSemantics(child: IgnorePointer(child: AnimatedBuilder(
      animation: _sweep,
      child: _text(const Color(0xff171717)),
      builder: (context, child) => !_sweep.isAnimating ? const SizedBox.shrink() : ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          final spread = 5.2 * ch;
          final gutter = spread + ch;
          final peak = -gutter + (rect.width + 2 * gutter) * _sweep.value;
          return const LinearGradient(colors: [Colors.transparent, Colors.black, Colors.transparent], stops: [0, .5, 1])
            .createShader(Rect.fromLTWH(peak - spread, 0, spread * 2, rect.height));
        }, child: child,
      ),
    )))),
  ]));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sweep.dispose();
    super.dispose();
  }
}

/// A text-height disclosure, without ListTile's implicit insets or minimum size.
class ConversationDisclosure extends StatefulWidget {
  const ConversationDisclosure({super.key, required this.label, required this.builder,
    this.onExpand, this.icon, this.summary, this.shimmer = false, this.initiallyExpanded = false,
    this.color, this.fontSize = 14, this.ruled = false, this.maxHeight, this.labelContent, this.action});
  final String label;
  final WidgetBuilder builder;
  final VoidCallback? onExpand;
  final Widget? icon, summary, labelContent, action;
  final bool shimmer, initiallyExpanded, ruled;
  final Color? color;
  final double fontSize;
  final double? maxHeight;

  @override
  State<ConversationDisclosure> createState() => _ConversationDisclosureState();
}

class _ConversationDisclosureState extends State<ConversationDisclosure> {
  bool? _expanded;
  final _header = GlobalKey();

  void _toggle() {
    final box = _header.currentContext?.findRenderObject();
    final top = box is RenderBox ? box.localToGlobal(Offset.zero).dy : null;
    final position = Scrollable.maybeOf(context)?.position;
    setState(() => _expanded = !(_expanded ?? widget.initiallyExpanded));
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: ('disclosure', widget.key));
    widget.onExpand?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || top == null || position == null || !position.hasPixels || position.isScrollingNotifier.value) return;
      final next = _header.currentContext?.findRenderObject();
      if (next is! RenderBox || !next.attached) return;
      final delta = next.localToGlobal(Offset.zero).dy - top;
      // Opening a disclosure should leave its label in place in either axis.
      if (delta.abs() > .5) position.jumpTo((position.pixels + (position.axisDirection == AxisDirection.up ? -delta : delta))
        .clamp(position.minScrollExtent, position.maxScrollExtent).toDouble());
    });
  }

  @override
  Widget build(BuildContext context) {
    _expanded ??= PageStorage.maybeOf(context)?.readState(context, identifier: ('disclosure', widget.key)) as bool?
      ?? widget.initiallyExpanded;
    final expanded = _expanded!;
    final color = widget.color ?? opencodeInk;
    final header = MouseRegion(
        child: Semantics(button: true, expanded: expanded, child: InkWell(
          key: _header,
          onTap: _toggle,
          borderRadius: BorderRadius.circular(4),
          hoverColor: Colors.transparent, highlightColor: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(minHeight: 24),
            padding: widget.ruled ? const EdgeInsets.only(bottom: 6) : EdgeInsets.zero,
            decoration: widget.ruled ? const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xffe8e9eb)))) : null,
            child: Row(mainAxisSize: widget.ruled || widget.summary != null ? MainAxisSize.max : MainAxisSize.min, children: [
              if (widget.icon != null) ...[widget.icon!, const SizedBox(width: 4)],
              Flexible(child: widget.labelContent ?? (widget.shimmer ? ThinkingLabel(label: widget.label, fontSize: widget.fontSize)
                : Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: widget.fontSize, height: 16 / 13,
                      letterSpacing: -.04, color: color)))),
              if (widget.summary != null) ...[const SizedBox(width: 8), Flexible(flex: 3, child: widget.summary!)],
              const SizedBox(width: 4),
              Opacity(opacity: 1,
                child: Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded, size: 14, color: color)),
            ]),
          ),
        )));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.action == null) header
      else Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: header), const SizedBox(width: 2), widget.action!]),
      if (expanded) Padding(padding: const EdgeInsets.only(top: 4), child: widget.maxHeight == null
        ? widget.builder(context)
        : ConstrainedBox(constraints: BoxConstraints(maxHeight: widget.maxHeight!),
            child: SingleChildScrollView(key: const PageStorageKey('activity-viewport'), child: widget.builder(context)))),
    ]);
  }
}
