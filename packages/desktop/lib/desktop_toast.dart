import 'dart:async';

import 'package:flutter/material.dart';

import 'appearance.dart';

final _toastRegions = Expando<({OverlayEntry entry, List<_DesktopToast> toasts})>();

VoidCallback? showDesktopToast(BuildContext context, String title, {
  Object? tag,
  String? description,
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 5),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;
  var region = _toastRegions[overlay];
  if (region == null) {
    final toasts = <_DesktopToast>[];
    final entry = OverlayEntry(builder: (context) => Positioned.fill(
      child: LayoutBuilder(builder: (context, bounds) {
        final compact = bounds.maxWidth <= 600;
        return SafeArea(child: Padding(
          padding: EdgeInsets.fromLTRB(compact ? 16 : 32, 48, compact ? 16 : 32, compact ? 16 : 48),
          child: Align(alignment: AlignmentDirectional.bottomEnd, child: SizedBox(width: 320,
            child: SingleChildScrollView(reverse: true, clipBehavior: Clip.none, child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final toast in toasts)
                Padding(key: toast.key, padding: EdgeInsets.only(top: toast == toasts.first ? 0 : 12), child: toast)],
            )),
          )),
        ));
      }),
    ));
    region = (entry: entry, toasts: toasts);
    _toastRegions[overlay] = region;
    overlay.insert(entry);
  }

  final toasts = region.toasts, entry = region.entry;
  final key = UniqueKey();
  void dismiss() {
    final index = toasts.indexWhere((toast) => toast.key == key);
    if (index < 0) return;
    toasts.removeAt(index);
    if (toasts.isEmpty) {
      _toastRegions[overlay] = null;
      entry.remove();
      entry.dispose();
    } else {
      entry.markNeedsBuild();
    }
  }

  toasts.removeWhere((toast) => tag != null ? toast.tag == tag
    : toast.tag == null && toast.title == title && toast.description == description && toast.actionLabel == actionLabel);
  if (toasts.length == 3) toasts.removeAt(0);
  toasts.add(_DesktopToast(key: key, tag: tag, title: title, description: description, icon: icon,
    actionLabel: actionLabel, onAction: onAction, duration: duration, onDismiss: dismiss));
  entry.markNeedsBuild();
  return dismiss;
}

class _DesktopToast extends StatefulWidget {
  const _DesktopToast({super.key, this.tag, required this.title, this.description, this.icon,
    this.actionLabel, this.onAction, required this.duration, required this.onDismiss});
  final String title;
  final Object? tag;
  final String? description, actionLabel;
  final IconData? icon;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onDismiss;

  @override
  State<_DesktopToast> createState() => _DesktopToastState();
}

class _DesktopToastState extends State<_DesktopToast> {
  Timer? _timer;
  final _elapsed = Stopwatch();
  late Duration _remaining = widget.duration;
  bool _hovered = false, _focused = false;

  @override
  void initState() { super.initState(); _resume(); }

  void _pause() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _remaining -= _elapsed.elapsed;
    _elapsed..stop()..reset();
  }

  void _resume() {
    if (_hovered || _focused || _timer != null) return;
    _elapsed.start();
    _timer = Timer(_remaining, widget.onDismiss);
  }

  @override
  void dispose() { _timer?.cancel(); _elapsed.stop(); super.dispose(); }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) { _hovered = true; _pause(); },
    onExit: (_) { _hovered = false; _resume(); },
    child: Focus(
      onFocusChange: (focused) { _focused = focused; if (focused) { _pause(); } else { _resume(); } },
      child: Semantics(container: true, liveRegion: true, child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (context, value, child) => Opacity(opacity: value,
          child: Transform.translate(offset: Offset(0, (1 - value) * 8), child: child)),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xfffafafa), borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(color: Color(0x0a000000), offset: Offset(0, 8), blurRadius: 16),
              BoxShadow(color: Color(0x14000000), offset: Offset(0, 4), blurRadius: 8),
              BoxShadow(color: Color(0x1f000000), spreadRadius: .5),
            ],
          ),
          child: Material(type: MaterialType.transparency, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.icon case final icon?) ...[
              SizedBox(width: 16, height: 20, child: Icon(icon, size: 16, color: opencodeInk)),
              const SizedBox(width: 12),
            ],
            Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(
                fontSize: 13, height: 20 / 13, letterSpacing: -.04, color: opencodeInk,
                fontWeight: FontWeight.w500, fontVariations: [FontVariation('wght', 530)])),
              if (widget.description case final description?) ...[
                const SizedBox(height: 4),
                Text(description, maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(
                  fontSize: 13, height: 20 / 13, letterSpacing: -.04, color: opencodeMuted,
                  fontVariations: [FontVariation('wght', 440)])),
              ],
              if (widget.actionLabel case final label?) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () { widget.onDismiss(); widget.onAction?.call(); },
                  style: TextButton.styleFrom(
                    foregroundColor: opencodeInk, backgroundColor: Colors.white,
                    visualDensity: VisualDensity.standard,
                    minimumSize: const Size(0, 24), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(fontSize: 13, height: 20 / 13, letterSpacing: -.04,
                      fontWeight: FontWeight.w500, fontVariations: [FontVariation('wght', 530)]),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4),
                      side: const BorderSide(color: opencodeBorder, width: .5)),
                  ),
                  child: Text(label),
                ),
              ],
            ])),
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Dismiss notification', onPressed: widget.onDismiss,
              style: IconButton.styleFrom(
                visualDensity: VisualDensity.standard,
                minimumSize: const Size.square(20), maximumSize: const Size.square(20),
                padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
              icon: const Icon(Icons.close_rounded, size: 16, color: opencodeFaint),
            ),
          ])),
        ),
      )),
    ),
  );
}
