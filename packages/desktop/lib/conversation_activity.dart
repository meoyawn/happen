import 'dart:async';

import 'package:flutter/material.dart';

import 'appearance.dart';

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
  late final _sweep = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  Timer? _first, _cadence;
  bool? _inTree;

  @override
  void initState() {
    super.initState();
    _inTree = true;
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
    if (_inTree == false || !visible || !TickerMode.valuesOf(context).enabled || MediaQuery.disableAnimationsOf(context)) {
      _first?.cancel(); _first = null;
      _cadence?.cancel(); _cadence = null;
      if (_inTree == false) { _sweep.stop(); }
      else { _sweep.reset(); }
      return;
    }
    if (_first != null || _cadence != null) return;
    _first = Timer(const Duration(milliseconds: 600), () {
      _first = null;
      if (!mounted || _inTree == false) return;
      _sweep.forward(from: 0);
      _cadence = Timer.periodic(const Duration(seconds: 4), (_) {
        if (mounted && _inTree != false) _sweep.forward(from: 0);
      });
    });
  }

  @override
  void deactivate() {
    _inTree = false;
    _synchronize();
    WidgetsBinding.instance.removeObserver(this);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _inTree = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void reassemble() {
    super.reassemble();
    _sweep..duration = const Duration(seconds: 1)..reset();
    _synchronize();
  }

  TextStyle _style(Color color) => TextStyle(fontSize: widget.fontSize,
    height: (widget.lineHeight ?? widget.fontSize * 1.625) / widget.fontSize, color: color, letterSpacing: 0);

  Widget _text(Color color) => Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _style(color));

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: Stack(children: [
    _text(desktopSecondary),
    Positioned.fill(child: ExcludeSemantics(child: IgnorePointer(child: AnimatedBuilder(
      animation: _sweep,
      child: _text(desktopForeground),
      builder: (context, child) => !_sweep.isAnimating ? const SizedBox.shrink() : ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          final step = (_sweep.value * 48).floor() / 48;
          final left = (-.5 + 1.75 * step) * rect.width;
          return const LinearGradient(colors: [Colors.transparent, Colors.black, Colors.black,
            Colors.transparent, Colors.transparent], stops: [0, .2, .3, .5, 1])
            .createShader(Rect.fromLTWH(left, 0, rect.width, rect.height));
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
    this.onExpand, this.icon, this.shimmer = false, this.initiallyExpanded = false,
    this.color, this.fontSize = 14, this.labelContent, this.timestamp});
  final String label;
  final WidgetBuilder builder;
  final VoidCallback? onExpand;
  final Widget? icon, labelContent;
  final bool shimmer, initiallyExpanded;
  final Color? color;
  final double fontSize;
  final DateTime? timestamp;

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
    final color = widget.color ?? desktopSecondary;
    final header = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(button: true, expanded: expanded, child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          key: _header,
          onTap: _toggle,
          onFocusChange: (focused) => setState(() => _focused = focused),
          borderRadius: BorderRadius.circular(6),
          hoverColor: Colors.transparent, focusColor: Colors.transparent,
          highlightColor: Colors.transparent, splashColor: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(minHeight: 24),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (widget.icon != null) ...[
                SizedBox.square(dimension: 16, child: Center(child: widget.icon!)),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: widget.labelContent ?? (widget.shimmer ? ThinkingLabel(label: widget.label, fontSize: widget.fontSize)
                : Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: widget.fontSize, height: 1.625,
                      letterSpacing: 0, color: color)))),
              if ((_hovered || _focused) && widget.timestamp != null) Padding(
                padding: const EdgeInsets.only(left: 6, right: 4),
                child: Tooltip(message: widget.timestamp!.toLocal().toString(),
                  child: Text(MaterialLocalizations.of(context).formatTimeOfDay(
                    TimeOfDay.fromDateTime(widget.timestamp!.toLocal()), alwaysUse24HourFormat: true),
                    style: const TextStyle(fontSize: 12, color: desktopSecondary,
                      fontFeatures: [FontFeature.tabularFigures()])))),
              const SizedBox(width: 4),
              Opacity(opacity: _hovered || _focused || expanded ? 1 : 0,
                child: RotatedBox(quarterTurns: expanded ? 1 : 0,
                  child: Icon(Icons.chevron_right_rounded, size: 14, color: color))),
            ]),
          ),
        )));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      if (expanded) Padding(padding: const EdgeInsets.only(top: 4), child: widget.builder(context)),
    ]);
  }
}
