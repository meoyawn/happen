import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop_notice.dart';

export 'desktop_notice.dart';

final _toastRegions = Expando<({OverlayEntry entry, List<_DesktopToast> toasts})>();

VoidCallback? showDesktopToast(BuildContext context, String title, {
  Object? tag,
  String? description,
  DesktopToastType type = DesktopToastType.info,
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;
  var region = _toastRegions[overlay];
  if (region == null) {
    final toasts = <_DesktopToast>[];
    final entry = OverlayEntry(builder: (context) => Positioned.fill(
      child: LayoutBuilder(builder: (context, bounds) {
        final inset = bounds.maxWidth < 640 ? 16.0 : 32.0;
        return SafeArea(child: Padding(
          padding: EdgeInsets.fromLTRB(inset, 50 + inset, inset - 6, inset),
          child: Align(alignment: AlignmentDirectional.topEnd, child: SizedBox(width: 366,
            child: SingleChildScrollView(clipBehavior: Clip.none,
              child: _DesktopToastStack(toasts: toasts)),
          )),
        ));
      }),
    ));
    region = (entry: entry, toasts: toasts);
    _toastRegions[overlay] = region;
    overlay.insert(entry);
  }

  final toasts = region.toasts, entry = region.entry;
  final key = GlobalKey<_DesktopToastState>();
  void remove() {
    toasts.removeWhere((toast) => toast.key == key);
    if (toasts.isEmpty) {
      if (_toastRegions[overlay]?.entry != entry) return;
      _toastRegions[overlay] = null;
      entry.remove();
      entry.dispose();
    } else {
      entry.markNeedsBuild();
    }
  }

  toasts.removeWhere((toast) => tag != null ? toast.tag == tag
    : toast.tag == null && toast.title == title && toast.description == description &&
      toast.type == type && toast.actionLabel == actionLabel);
  while (toasts.length >= 3) { toasts.removeLast(); }
  toasts.insert(0, _DesktopToast(key: key, tag: tag, title: title, description: description, type: type, icon: icon,
    actionLabel: actionLabel, onAction: onAction,
    duration: duration ?? Duration(seconds: type == DesktopToastType.error ? 10 : 5), onDismiss: remove));
  entry.markNeedsBuild();
  return () {
    if (!toasts.any((toast) => toast.key == key)) return;
    if (key.currentState case final state?) { state.dismiss(); }
    else { remove(); }
  };
}

class DesktopToastListener extends StatefulWidget {
  const DesktopToastListener({super.key, required this.notices, required this.child});
  final Stream<DesktopNotice> notices;
  final Widget child;

  @override
  State<DesktopToastListener> createState() => _DesktopToastListenerState();
}

class _DesktopToastListenerState extends State<DesktopToastListener> {
  late StreamSubscription<DesktopNotice> _subscription;

  void _listen() {
    _subscription = widget.notices.listen((notice) {
      if (!mounted) return;
      showDesktopToast(context, notice.title, type: notice.type, tag: notice.tag,
        description: notice.description, actionLabel: notice.actionLabel, onAction: notice.onAction);
    });
  }

  @override
  void initState() { super.initState(); _listen(); }

  @override
  void didUpdateWidget(DesktopToastListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notices == widget.notices) return;
    unawaited(_subscription.cancel());
    _listen();
  }

  @override
  void dispose() { unawaited(_subscription.cancel()); super.dispose(); }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DesktopToastStack extends StatefulWidget {
  const _DesktopToastStack({required this.toasts});
  final List<_DesktopToast> toasts;

  @override
  State<_DesktopToastStack> createState() => _DesktopToastStackState();
}

class _DesktopToastStackState extends State<_DesktopToastStack> with WidgetsBindingObserver {
  bool _hovered = false, _focused = false;
  bool _active = WidgetsBinding.instance.lifecycleState == null ||
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool get _expanded => _hovered || _focused;

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _active = state == AppLifecycleState.resumed);
  }

  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Focus(
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: _DesktopToastActivity(paused: _expanded || !_active, child: AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
        alignment: Alignment.topCenter, curve: Curves.easeOutCubic, clipBehavior: Clip.none,
        child: Stack(clipBehavior: Clip.none, children: [
          if (!_expanded)
            for (var index = widget.toasts.length - 1; index > 0; index--)
              Positioned(top: 6 + index * 12, bottom: (widget.toasts.length - 1 - index) * 12,
                left: index * 18, right: 6 + index * 18,
                child: IgnorePointer(child: _toastSurface(context, const SizedBox.expand()))),
          Padding(padding: EdgeInsets.only(bottom: _expanded ? 0 : (widget.toasts.length - 1) * 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final (index, toast) in widget.toasts.indexed)
                KeyedSubtree(key: ValueKey(toast.key),
                  child: ExcludeFocus(excluding: !_expanded && index > 0,
                    child: Offstage(offstage: !_expanded && index > 0,
                      child: Padding(padding: EdgeInsets.only(top: index == 0 ? 0 : 6),
                        child: toast,
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      )),
    ),
  );
}

class _DesktopToastActivity extends InheritedWidget {
  const _DesktopToastActivity({required this.paused, required super.child});
  final bool paused;

  @override
  bool updateShouldNotify(_DesktopToastActivity oldWidget) => paused != oldWidget.paused;
}

Widget _toastSurface(BuildContext context, Widget child) {
  final colors = Theme.of(context).colorScheme;
  return DecoratedBox(
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), boxShadow: const [
      BoxShadow(color: Color(0x40000000), offset: Offset(0, 12), blurRadius: 32, spreadRadius: -8),
    ]),
    child: ClipRRect(borderRadius: BorderRadius.circular(8), child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: DecoratedBox(decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: .94), borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.onSurface.withValues(alpha: .10))),
        child: child),
    )),
  );
}

class _DesktopToast extends StatefulWidget {
  const _DesktopToast({super.key, this.tag, required this.title, this.description, required this.type,
    this.icon, this.actionLabel, this.onAction, required this.duration, required this.onDismiss});
  final Object? tag;
  final String title;
  final String? description, actionLabel;
  final DesktopToastType type;
  final IconData? icon;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onDismiss;

  @override
  State<_DesktopToast> createState() => _DesktopToastState();
}

class _DesktopToastState extends State<_DesktopToast> with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 500),
    reverseDuration: const Duration(milliseconds: 180))..forward();
  Timer? _timer;
  final _elapsed = Stopwatch();
  late Duration _remaining = widget.duration;
  bool _copied = false, _paused = true, _closing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _animation.duration = reduceMotion ? Duration.zero : const Duration(milliseconds: 500);
    _animation.reverseDuration = reduceMotion ? Duration.zero : const Duration(milliseconds: 180);
    if (reduceMotion && !_closing) _animation.value = 1;
    _paused = context.dependOnInheritedWidgetOfExactType<_DesktopToastActivity>()!.paused;
    if (_paused) { _pause(); }
    else { _resume(); }
  }

  void dismiss() {
    if (_closing) return;
    _closing = true;
    _pause();
    unawaited(_animation.reverse().then((_) { if (mounted) widget.onDismiss(); }));
  }

  void _pause() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _remaining -= _elapsed.elapsed;
    _elapsed..stop()..reset();
  }

  void _resume() {
    if (_paused || _closing || _timer != null) return;
    _elapsed.start();
    _timer = Timer(_remaining, dismiss);
  }

  Future<void> _copyError() async {
    try {
      await Clipboard.setData(ClipboardData(text: [widget.title, widget.description].nonNulls.join('\n\n')));
      if (mounted) setState(() => _copied = true);
    } on PlatformException catch (error) {
      if (mounted) showDesktopToast(context, 'Could not copy error', type: DesktopToastType.error, description: error.message);
    }
  }

  @override
  void dispose() { _timer?.cancel(); _elapsed.stop(); _animation.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final toast = widget;
    final colors = Theme.of(context).colorScheme;
    final (icon, color) = switch (toast.type) {
      DesktopToastType.success => (Icons.check_circle_outline_rounded, const Color(0xff10b981)),
      DesktopToastType.error => (Icons.error_outline_rounded, colors.error),
      DesktopToastType.warning => (Icons.warning_amber_rounded, const Color(0xfff59e0b)),
      DesktopToastType.info => (Icons.info_outline_rounded, const Color(0xff3b82f6)),
    };
    final animation = _animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return FadeTransition(opacity: animation, child: SlideTransition(
      position: Tween(begin: const Offset(1.12, 0), end: Offset.zero).animate(animation),
      child: Semantics(container: true, liveRegion: true, child: Stack(clipBehavior: Clip.none, children: [
        Padding(padding: const EdgeInsets.only(top: 6, right: 6),
          child: _toastSurface(context, Material(type: MaterialType.transparency, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 16, height: 20, child: Icon(toast.icon ?? icon, size: 16, color: color)),
                const SizedBox(width: 8),
                Expanded(child: Text(toast.title, style: TextStyle(fontSize: 13, height: 20 / 13,
                  color: colors.onSurface, fontWeight: FontWeight.w500))),
              ]),
              if (toast.description case final description?) Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(description, maxLines: toast.type == DesktopToastType.error ? 4 : 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, height: 20 / 13, color: colors.onSurfaceVariant))),
            ])),
            if (toast.type == DesktopToastType.error) ...[
              const SizedBox(width: 6),
              IconButton(tooltip: _copied ? 'Copied error' : 'Copy error',
                onPressed: _copyError,
                style: IconButton.styleFrom(minimumSize: const Size.square(24), padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                icon: Icon(_copied ? Icons.check_rounded : Icons.copy_outlined, size: 13,
                  color: _copied ? const Color(0xff10b981) : colors.onSurfaceVariant)),
            ],
            if (toast.actionLabel case final label? when toast.onAction != null) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () { dismiss(); toast.onAction!(); },
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.onSurface, backgroundColor: colors.surface,
                  minimumSize: const Size(0, 26), padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  side: BorderSide(color: colors.onSurface.withValues(alpha: .12)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                child: Text(label)),
            ],
          ]),
        )))),
        Positioned(top: 0, right: 0, child: Material(
          color: colors.surface, shape: CircleBorder(side: BorderSide(color: colors.onSurface.withValues(alpha: .12))),
          elevation: 1, child: IconButton(
            tooltip: 'Dismiss notification', onPressed: dismiss,
            style: IconButton.styleFrom(minimumSize: const Size.square(24), maximumSize: const Size.square(24),
              padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            icon: Icon(Icons.close_rounded, size: 12, color: colors.onSurfaceVariant),
          ),
        )),
      ])),
    ));
  }
}
