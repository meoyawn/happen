import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appearance.dart';

// OpenCode's ui/src/components/image-preview and image-zoom: the image itself
// is the surface, with a fitted view, bounded pan, and zoom in natural pixels.
typedef PreviewImage = ({ImageProvider provider, String label, Rect origin, double originRadius});

class ImagePreview extends StatefulWidget {
  const ImagePreview({super.key, required this.images, required this.initialIndex, required this.onChanged});
  final List<PreviewImage> images;
  final int initialIndex;
  final ValueChanged<int> onChanged;

  @override
  State<ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<ImagePreview> with SingleTickerProviderStateMixin {
  late int _index = widget.initialIndex;
  PreviewImage get _current => widget.images[_index];
  ImageStream? _stream;
  ImageInfo? _info;
  bool _failed = false;
  final _focus = FocusNode();
  late final _listener = ImageStreamListener(_loaded, onError: (Object _, StackTrace? _) {
    if (mounted) setState(() => _failed = true);
  });
  late final AnimationController _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))..addListener(() {
    final t = Curves.easeOutCubic.transform(_glide.value);
    setState(() {
      _scale = lerpDouble(_from.$1, _goal.$1, t)!;
      _offset = Offset.lerp(_from.$2, _goal.$2, t)!;
    });
  });
  double _scale = 1, _gestureScale = 1, _fitRatio = 1;
  Offset _offset = Offset.zero, _focal = Offset.zero, _doubleTap = Offset.zero;
  (double, Offset) _from = (1, Offset.zero), _goal = (1, Offset.zero);
  Size _viewport = Size.zero, _fitted = Size.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  void _resolve() {
    final stream = _current.provider.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) return;
    _stream?.removeListener(_listener);
    _info?.dispose();
    _info = null;
    _failed = false;
    _stream = stream..addListener(_listener);
  }

  void _move(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.images.length) return;
    _glide.stop();
    setState(() {
      _index = next;
      _scale = _gestureScale = 1;
      _offset = _focal = Offset.zero;
      _from = _goal = (1, Offset.zero);
      _resolve();
    });
    widget.onChanged(next);
  }

  void _loaded(ImageInfo info, bool synchronous) {
    final previous = _info;
    if (mounted) {
      setState(() { _info = info; _failed = false; });
    } else {
      info.dispose();
    }
    previous?.dispose();
  }

  (double, Offset) _bounded(double scale, Offset offset) {
    scale = scale.clamp(1.0, math.max(1.0, 8 / _fitRatio));
    final x = math.max(0.0, (_fitted.width * scale - _viewport.width) / 2);
    final y = math.max(0.0, (_fitted.height * scale - _viewport.height) / 2);
    return (scale, Offset(offset.dx.clamp(-x, x), offset.dy.clamp(-y, y)));
  }

  void _show((double, Offset) view, {bool animate = false}) {
    final target = _bounded(view.$1, view.$2);
    _glide.stop();
    _goal = target;
    if (animate && !MediaQuery.disableAnimationsOf(context)) {
      _from = (_scale, _offset);
      _glide.forward(from: 0);
    } else {
      setState(() { _scale = target.$1; _offset = target.$2; });
    }
  }

  void _zoom(double scale, Offset anchor, {bool animate = false}) {
    final before = animate ? _goal : (_scale, _offset);
    final next = scale.clamp(1.0, math.max(1.0, 8 / _fitRatio)).toDouble();
    _show((next, anchor - (anchor - before.$2) * (next / before.$1)), animate: animate);
  }

  void _fit() => _show((1, Offset.zero), animate: true);
  void _step(double factor) => _zoom(_goal.$1 * factor, Offset.zero, animate: true);

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_goal.$1 > 1) { _fit(); } else { Navigator.of(context).pop(); }
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final primary = keyboard.isMetaPressed || keyboard.isControlPressed;
    if (!primary && !keyboard.isAltPressed && !keyboard.isShiftPressed &&
        (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight)) {
      _move(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit0 && !HardwareKeyboard.instance.isAltPressed) {
      _fit();
    } else if (primary && (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add)) {
      _step(1.25);
    } else if (primary && (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract)) {
      _step(1 / 1.25);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    _glide.dispose();
    _focus.dispose();
    super.dispose();
  }

  Widget _button(String label, IconData icon, VoidCallback? action, {bool autofocus = false}) => IconButton(
    tooltip: label, autofocus: autofocus, onPressed: action,
    style: IconButton.styleFrom(minimumSize: const Size.square(28), maximumSize: const Size.square(28),
      padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
    icon: Icon(icon, size: 16, color: action == null ? opencodeFaint : opencodeMuted));

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)!.animation!;
    return Focus(focusNode: _focus, onKeyEvent: _key, child: Material(type: MaterialType.transparency,
      child: AnimatedBuilder(animation: animation, builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
        final inset = (constraints.maxWidth * .03).clamp(8.0, 36.0);
        final body = Rect.fromLTRB(inset + 12, 56, constraints.maxWidth - inset - 12, constraints.maxHeight - 56);
        _viewport = body.size;
        final image = _info?.image;
        if (image != null) {
          _fitRatio = math.min(1, math.min(body.width / image.width, body.height / image.height));
          _fitted = Size(image.width * _fitRatio, image.height * _fitRatio);
        }
        final view = _bounded(_scale, _offset);
        final target = Rect.fromCenter(center: body.center + view.$2,
          width: _fitted.width * view.$1, height: _fitted.height * view.$1);
        final t = Curves.easeOutCubic.transform(animation.value);
        final rect = Rect.lerp(_current.origin, target, t)!;
        final radius = lerpDouble(_current.originRadius, 6, t)!;
        return Stack(children: [
          Positioned.fill(child: GestureDetector(onTap: () => Navigator.of(context).pop(),
            child: ColoredBox(color: Colors.black.withValues(alpha: .4 * t)))),
          if (image != null) Positioned.fill(child: Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent || !body.contains(event.localPosition)) return;
              GestureBinding.instance.pointerSignalResolver.register(event, (event) {
                final scroll = event as PointerScrollEvent;
                if (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) {
                  _zoom(_scale * math.exp(-scroll.scrollDelta.dy.clamp(-30, 30) / 100), scroll.localPosition - body.center);
                } else {
                  _show((_scale, _offset - scroll.scrollDelta));
                }
              });
            },
            child: GestureDetector(behavior: HitTestBehavior.opaque,
              onTapUp: (event) { if (!target.contains(event.localPosition)) Navigator.of(context).pop(); },
              onDoubleTapDown: (event) => _doubleTap = event.localPosition - body.center,
              onDoubleTap: () {
                if (_goal.$1 > 1) { _fit(); }
                else { _zoom(1 / _fitRatio >= 1.5 ? 1 / _fitRatio : 2, _doubleTap, animate: true); }
              },
              onScaleStart: (event) { _glide.stop(); _gestureScale = _scale; _focal = event.localFocalPoint; },
              onScaleUpdate: (event) {
                final anchor = _focal - body.center;
                final scale = (_gestureScale * event.scale).clamp(1.0, math.max(1.0, 8 / _fitRatio)).toDouble();
                _show((scale, anchor - (anchor - _offset) * (scale / _scale) + event.localFocalPoint - _focal));
                _focal = event.localFocalPoint;
              },
              child: MouseRegion(cursor: _scale > 1 ? SystemMouseCursors.grab : MouseCursor.defer,
                child: ClipRect(child: Stack(children: [Positioned.fromRect(rect: rect,
                  child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .35 * 4 * t * (1 - t)),
                      blurRadius: 45, offset: const Offset(0, 15))]),
                    child: ClipRRect(borderRadius: BorderRadius.circular(radius),
                      child: Semantics(image: true, label: widget.images.length == 1 ? _current.label
                        : '${_current.label}, image ${_index + 1} of ${widget.images.length}',
                        child: RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium))))),
                ]))),
            ),
          ))
          else if (_failed) const Center(child: Text('Could not load image', style: TextStyle(color: Colors.white)))
          else const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          Positioned(bottom: 12, left: 0, right: 0, child: Center(child: Opacity(opacity: t,
            child: Container(padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: const Color(0xfffafafa), borderRadius: BorderRadius.circular(8),
                boxShadow: const [BoxShadow(color: Color(0x24000000), blurRadius: 12, offset: Offset(0, 4))]),
              child: Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: [
                if (widget.images.length > 1) ...[
                  _button('Previous image', Icons.chevron_left, _index > 0 ? () => _move(-1) : null),
                  Text('${_index + 1} / ${widget.images.length}',
                    style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: opencodeMuted,
                      fontFeatures: [FontFeature.tabularFigures()])),
                  _button('Next image', Icons.chevron_right, _index + 1 < widget.images.length ? () => _move(1) : null),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 2),
                    child: SizedBox(width: .5, height: 16, child: ColoredBox(color: opencodeBorder))),
                ],
                _button('Zoom out', Icons.remove, () => _step(1 / 1.25)),
                SizedBox(width: 52, height: 28, child: TextButton(onPressed: _fit,
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: opencodeMuted,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
                  child: Text('${(view.$1 * _fitRatio * 100).round()}%',
                    semanticsLabel: 'Zoom to fit', style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])))),
                _button('Zoom in', Icons.add, () => _step(1.25)),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 2),
                  child: SizedBox(width: .5, height: 16, child: ColoredBox(color: opencodeBorder))),
                _button('Close image', Icons.close, () => Navigator.of(context).pop(), autofocus: true),
              ])),
          ))),
        ]);
      }))),
    );
  }
}
