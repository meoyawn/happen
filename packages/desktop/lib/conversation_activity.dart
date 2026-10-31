import 'dart:async';

import 'package:flutter/material.dart';

import 'appearance.dart';

/// The Codex label keeps its baseline still while a highlight crosses the text.
class ThinkingLabel extends StatefulWidget {
  const ThinkingLabel({super.key, this.label = 'Thinking', this.fontSize = 14});
  final String label;
  final double fontSize;

  @override
  State<ThinkingLabel> createState() => _ThinkingLabelState();
}

class _ThinkingLabelState extends State<ThinkingLabel>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _sweep = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  Timer? _first, _cadence;

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
    if (!visible || !TickerMode.of(context) || MediaQuery.disableAnimationsOf(context)) {
      _first?.cancel(); _first = null;
      _cadence?.cancel(); _cadence = null;
      _sweep.reset();
      return;
    }
    if (_first != null || _cadence != null) return;
    _first = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _sweep.forward(from: 0);
      _cadence = Timer.periodic(const Duration(seconds: 4), (_) {
        if (mounted) _sweep.forward(from: 0);
      });
    });
  }

  @override
  void deactivate() {
    _first?.cancel(); _first = null;
    _cadence?.cancel(); _cadence = null;
    _sweep.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    WidgetsBinding.instance.addObserver(this);
  }

  Widget _text(Color color) => Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: widget.fontSize, height: 1.625, color: color, letterSpacing: 0));

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: Stack(children: [
    _text(const Color(0x461a1c1f)),
    Positioned.fill(child: ExcludeSemantics(child: IgnorePointer(child: AnimatedBuilder(
      animation: _sweep,
      child: _text(const Color(0xbfffffff)),
      builder: (context, child) => !_sweep.isAnimating ? const SizedBox.shrink() : ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          final step = (_sweep.value * 48).floor() / 48;
          return const LinearGradient(colors: [Colors.transparent, Colors.black, Colors.black,
            Colors.transparent, Colors.transparent], stops: [0, .2, .3, .5, 1])
            .createShader(Rect.fromLTWH((-.5 + 1.75 * step) * rect.width, 0, rect.width, rect.height));
        }, child: child,
      ),
    )))),
  ]));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _first?.cancel();
    _cadence?.cancel();
    _sweep.dispose();
    super.dispose();
  }
}

/// A text-height disclosure, without ListTile's implicit insets or minimum size.
class ConversationDisclosure extends StatefulWidget {
  const ConversationDisclosure({super.key, required this.label, required this.builder,
    this.onExpand, this.icon, this.summary, this.shimmer = false, this.initiallyExpanded = false,
    this.color, this.fontSize = 14, this.ruled = false, this.maxHeight});
  final String label;
  final WidgetBuilder builder;
  final VoidCallback? onExpand;
  final Widget? icon, summary;
  final bool shimmer, initiallyExpanded, ruled;
  final Color? color;
  final double fontSize;
  final double? maxHeight;

  @override
  State<ConversationDisclosure> createState() => _ConversationDisclosureState();
}

class _ConversationDisclosureState extends State<ConversationDisclosure> {
  bool? _expanded;
  bool _hovered = false, _focused = false;
  final _header = GlobalKey();

  void _toggle() {
    final box = _header.currentContext?.findRenderObject();
    final top = box is RenderBox ? box.localToGlobal(Offset.zero).dy : null;
    final position = Scrollable.maybeOf(context)?.position;
    setState(() => _expanded = !(_expanded ?? widget.initiallyExpanded));
    PageStorage.maybeOf(context)?.writeState(context, _expanded);
    widget.onExpand?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || top == null || position == null || !position.hasPixels || position.isScrollingNotifier.value) return;
      final next = _header.currentContext?.findRenderObject();
      if (next is! RenderBox || !next.attached) return;
      final delta = next.localToGlobal(Offset.zero).dy - top;
      // Transcripts grow upwards: opening a row should leave its label in place.
      if (delta.abs() > .5) position.jumpTo((position.pixels + (position.axisDirection == AxisDirection.up ? -delta : delta))
        .clamp(position.minScrollExtent, position.maxScrollExtent).toDouble());
    });
  }

  @override
  Widget build(BuildContext context) {
    _expanded ??= PageStorage.maybeOf(context)?.readState(context) as bool? ?? widget.initiallyExpanded;
    final expanded = _expanded!;
    final codex = ConversationAppearance.of(context) == ConversationStyle.harness;
    final color = widget.color ?? (_hovered || _focused ? const Color(0xff1a1c1f) : const Color(0x991a1c1f));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      MouseRegion(onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() => _hovered = false),
        child: Semantics(button: true, expanded: expanded, child: InkWell(
          key: _header,
          onTap: _toggle,
          onFocusChange: (value) => setState(() => _focused = value),
          borderRadius: BorderRadius.circular(4),
          hoverColor: Colors.transparent, highlightColor: Colors.transparent,
          child: Container(
            padding: widget.ruled ? const EdgeInsets.only(bottom: 6) : EdgeInsets.zero,
            decoration: widget.ruled ? const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xffe8e9eb)))) : null,
            child: Row(mainAxisSize: widget.ruled || widget.summary != null ? MainAxisSize.max : MainAxisSize.min, children: [
              if (widget.icon != null) ...[widget.icon!, const SizedBox(width: 4)],
              Flexible(child: widget.shimmer ? ThinkingLabel(label: widget.label, fontSize: widget.fontSize)
                : Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: widget.fontSize, height: codex ? 1.625 : 20 / 13,
                      letterSpacing: 0, color: color))),
              if (widget.summary != null) ...[const SizedBox(width: 8), Flexible(flex: 3, child: widget.summary!)],
              const SizedBox(width: 4),
              Opacity(opacity: !codex || _hovered || _focused || expanded ? 1 : 0,
                child: Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded, size: 14, color: color)),
            ]),
          ),
        ))),
      if (expanded) Padding(padding: const EdgeInsets.only(top: 4), child: widget.maxHeight == null
        ? widget.builder(context)
        : ConstrainedBox(constraints: BoxConstraints(maxHeight: widget.maxHeight!),
            child: SingleChildScrollView(child: widget.builder(context)))),
    ]);
  }
}
