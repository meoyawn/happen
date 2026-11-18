import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import 'appearance.dart';
import 'conversation_activity_icon.dart';

class ThinkingLabel extends StatefulWidget {
  const ThinkingLabel({super.key, this.label = 'Thinking', this.fontSize = 14, this.lineHeight, this.baseColor});
  final String label;
  final double fontSize;
  final double? lineHeight;
  final Color? baseColor;

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
    _text(widget.baseColor ?? const Color(0x461a1c1f)),
    Positioned.fill(child: ExcludeSemantics(child: IgnorePointer(child: AnimatedBuilder(
      animation: _sweep,
      child: _text(const Color(0xbfffffff)),
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

const _disclosureDuration = Duration(milliseconds: 300);
const _turnCloseDuration = Duration(milliseconds: 150);
const _detailCurve = Cubic(.19, 1, .22, 1);
const _turnCloseCurve = Cubic(.23, 1, .32, 1);
const _chevronCurve = Cubic(.4, 0, .2, 1);
const _activityColor = Color(0x751a1c1f);

class ConversationActivityHeader extends StatefulWidget {
  const ConversationActivityHeader({super.key, required this.label, this.expanded = false, this.onToggle,
    this.icon, this.fontSize = 14, this.shimmer = false, this.toolActivity = true, this.alwaysShowChevron = true,
    this.inlineLabel});
  final String label;
  final bool expanded, shimmer, toolActivity, alwaysShowChevron;
  final VoidCallback? onToggle;
  final Widget? icon;
  final double fontSize;
  final Widget Function(TextStyle)? inlineLabel;

  @override
  State<ConversationActivityHeader> createState() => _ConversationActivityHeaderState();
}

class _ConversationActivityHeaderState extends State<ConversationActivityHeader> {
  bool _hovered = false, _focused = false;

  Widget _button(BuildContext context, Widget child, String label) =>
    Semantics(button: widget.onToggle != null, expanded: widget.onToggle == null ? null : widget.expanded,
      liveRegion: widget.shimmer, onTap: widget.onToggle, excludeSemantics: true, label: label,
      child: DecoratedBox(position: DecorationPosition.foreground, decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6), border: Border.all(width: 2,
          color: _focused ? DesktopAccent.of(context).color : Colors.transparent)),
        child: InkWell(onTap: widget.onToggle, excludeFromSemantics: true,
          mouseCursor: widget.onToggle == null ? null : SystemMouseCursors.click,
          onFocusChange: (value) => setState(() => _focused = value &&
            FocusManager.instance.highlightMode == FocusHighlightMode.traditional),
          borderRadius: BorderRadius.circular(6), hoverColor: Colors.transparent,
          focusColor: Colors.transparent, splashColor: Colors.transparent, highlightColor: Colors.transparent,
          child: child)));

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final color = _hovered || _focused ? ink : widget.toolActivity ? _activityColor : ink.withValues(alpha: .5);
    final style = TextStyle(fontSize: widget.fontSize, height: 1.5, color: color);
    final inline = widget.inlineLabel;
    final label = inline?.call(style) ?? (widget.shimmer ? ThinkingLabel(label: widget.label,
      fontSize: widget.fontSize, lineHeight: widget.fontSize * 1.5, baseColor: color)
      : Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style));
    final chevron = widget.onToggle == null ? null : Opacity(
      opacity: widget.alwaysShowChevron || widget.expanded || _hovered || _focused ? 1 : 0,
      child: AnimatedRotation(turns: widget.expanded ? .25 : 0, curve: _chevronCurve,
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero
          : widget.toolActivity ? _disclosureDuration : _turnCloseDuration,
        child: ConversationActivityIcon(ConversationActivityGlyph.chevronRight, size: 12, color: color)));
    final row = ConstrainedBox(constraints: BoxConstraints(minHeight: widget.toolActivity ? 23 : 0),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (widget.icon != null) ...[
          IconTheme.merge(data: IconThemeData(color: color), child: widget.icon!),
          const SizedBox(width: 6),
        ],
        Flexible(child: label),
        if (chevron != null) ...[
          const SizedBox(width: 4),
          if (inline == null) chevron
          else _button(context, SizedBox(width: 22, height: 23, child: Center(child: chevron)),
            '${widget.expanded ? 'Hide' : 'Show'} details for ${widget.label}'),
        ],
      ]));
    return MouseRegion(onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SelectionContainer.disabled(child: inline == null ? _button(context, row, widget.label) : row));
  }
}

class ConversationActivityDetails extends StatefulWidget {
  const ConversationActivityDetails({super.key, required this.expanded, required this.builder, this.turn = false});
  final bool expanded, turn;
  final WidgetBuilder builder;

  @override
  State<ConversationActivityDetails> createState() => _ConversationActivityDetailsState();
}

class _ConversationActivityDetailsState extends State<ConversationActivityDetails> with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(vsync: this, animationBehavior: AnimationBehavior.preserve,
    value: widget.expanded ? 1 : 0)..addStatusListener(_statusChanged);
  bool _reducedMotion = false;

  void _statusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.expanded && mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion == reducedMotion) return;
    _reducedMotion = reducedMotion;
    if (_progress.isAnimating) _transition();
  }

  @override
  void didUpdateWidget(ConversationActivityDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) _transition();
  }

  void _transition() {
    if (_reducedMotion && !widget.turn) {
      _progress.value = widget.expanded ? 1 : 0;
    } else if (widget.expanded) {
      _progress.animateTo(1, curve: _detailCurve,
        duration: _reducedMotion ? _turnCloseDuration : _disclosureDuration);
    } else {
      _progress.animateBack(0, curve: widget.turn ? _turnCloseCurve : _detailCurve,
        duration: widget.turn ? _turnCloseDuration : _disclosureDuration);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded && _progress.isDismissed) return const SizedBox.shrink();
    Widget body = FadeTransition(opacity: _progress, child: Builder(builder: widget.builder));
    if (widget.turn) {
      body = AnimatedBuilder(animation: _progress, child: body, builder: (context, child) =>
        Transform.translate(offset: Offset(0, _reducedMotion ? 0 : -8 * (1 - _progress.value)), child: child));
    }
    final height = widget.turn && _reducedMotion ? const AlwaysStoppedAnimation(1.0) : _progress;
    return IgnorePointer(ignoring: !widget.expanded, child: ExcludeFocus(excluding: !widget.expanded,
      child: ExcludeSemantics(excluding: !widget.expanded,
        child: SizeTransition(sizeFactor: height, alignment: AlignmentDirectional.topStart, child: body))));
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }
}

final _activeDisclosureAnchors = Expando<Object>();

bool hasConversationDisclosureAnchor(ScrollPosition position) => _activeDisclosureAnchors[position] != null;

void cancelConversationDisclosureAnchor(ScrollPosition position) => _activeDisclosureAnchors[position] = null;

void toggleConversationDisclosure(BuildContext context, BuildContext? header, VoidCallback toggle, {bool turn = false}) {
  final position = Scrollable.maybeOf(context)?.position;
  double? headerTop() {
    if (header?.mounted != true) return null;
    final box = header!.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final top = box.localToGlobal(Offset.zero, ancestor: RenderAbstractViewport.maybeOf(box)).dy;
    return top.isFinite ? top : null;
  }
  final top = headerTop();
  final duration = MediaQuery.disableAnimationsOf(context)
    ? (turn ? _turnCloseDuration : Duration.zero) : _disclosureDuration;
  toggle();
  if (top == null || position == null) return;

  final anchor = _activeDisclosureAnchors[position] = Object();
  Duration? started;
  void restore(Duration timestamp) {
    if (!identical(_activeDisclosureAnchors[position], anchor)) return;
    if (!context.mounted || !position.hasPixels || !position.hasContentDimensions ||
        position.isScrollingNotifier.value || !identical(Scrollable.maybeOf(context)?.position, position)) {
      cancelConversationDisclosureAnchor(position);
      return;
    }
    final next = headerTop();
    if (next == null) {
      cancelConversationDisclosureAnchor(position);
      return;
    }
    final delta = next - top;
    final target = (position.pixels + (position.axisDirection == AxisDirection.up ? -delta : delta))
      .clamp(position.minScrollExtent, position.maxScrollExtent);
    final moved = (target - position.pixels).abs() > .5;
    if (moved) position.jumpTo(target);
    started ??= timestamp;
    final elapsed = timestamp - started!;
    // Let the last correction reach layout before releasing scroll ownership.
    if (elapsed < duration || moved && elapsed < const Duration(milliseconds: 700)) {
      WidgetsBinding.instance.addPostFrameCallback(restore);
      WidgetsBinding.instance.ensureVisualUpdate();
    } else {
      cancelConversationDisclosureAnchor(position);
    }
  }
  WidgetsBinding.instance.addPostFrameCallback(restore);
}

/// A text-height disclosure, without ListTile's implicit insets or minimum size.
class ConversationDisclosure extends StatefulWidget {
  const ConversationDisclosure({super.key, required this.label, required this.builder,
    this.onExpand, this.icon, this.shimmer = false, this.initiallyExpanded = false,
    this.color, this.fontSize = 14, this.labelContent, this.timestamp, this.toolActivity = false,
    this.inlineLabel});
  final String label;
  final WidgetBuilder builder;
  final VoidCallback? onExpand;
  final Widget? icon, labelContent;
  final bool shimmer, initiallyExpanded, toolActivity;
  final Color? color;
  final double fontSize;
  final DateTime? timestamp;
  final Widget Function(TextStyle)? inlineLabel;

  @override
  State<ConversationDisclosure> createState() => _ConversationDisclosureState();
}

class _ConversationDisclosureState extends State<ConversationDisclosure> {
  bool? _expanded;
  bool _hovered = false, _focused = false;
  final _header = GlobalKey();

  void _toggle() => toggleConversationDisclosure(context, _header.currentContext, () {
    setState(() => _expanded = !(_expanded ?? widget.initiallyExpanded));
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: ('disclosure', widget.key));
    widget.onExpand?.call();
  });

  @override
  Widget build(BuildContext context) {
    _expanded ??= PageStorage.maybeOf(context)?.readState(context, identifier: ('disclosure', widget.key)) as bool?
      ?? widget.initiallyExpanded;
    final expanded = _expanded!;
    if (widget.toolActivity) return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConversationActivityHeader(key: _header, label: widget.label, expanded: expanded, onToggle: _toggle,
          icon: widget.icon, fontSize: widget.fontSize, alwaysShowChevron: false, inlineLabel: widget.inlineLabel),
        ConversationActivityDetails(expanded: expanded, builder: widget.builder),
      ]);
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
                child: AnimatedRotation(turns: expanded ? .25 : 0, curve: _chevronCurve,
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : _disclosureDuration,
                  child: Icon(Icons.chevron_right_rounded, size: 14, color: color))),
            ]),
          ),
        )));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      ConversationActivityDetails(expanded: expanded, builder: (context) =>
        Padding(padding: const EdgeInsets.only(top: 4), child: widget.builder(context))),
    ]);
  }
}
