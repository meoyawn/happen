import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'conversation_markdown.dart';

/// Network chunks update only this message. Reveal catches up within roughly
/// 120ms, on display frames, rather than making transport boundaries visible.
class SmoothConversationText extends StatefulWidget {
  const SmoothConversationText({super.key, required this.text, required this.directory,
    required this.streaming, this.source});
  final String text, directory;
  final bool streaming;
  final ValueListenable<String>? source;

  @override
  State<SmoothConversationText> createState() => _SmoothConversationTextState();
}

class _SmoothConversationTextState extends State<SmoothConversationText> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late String _target = widget.text;
  late int _visible = _target.length;
  Duration _last = Duration.zero;
  double _fraction = 0;
  bool _active = true, _motion = true;
  String? _rendered;
  Widget? _markdown;

  @override
  void initState() {
    super.initState();
    widget.source?.addListener(_receive);
    _receive();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.of(context);
    _motion = _active && !MediaQuery.disableAnimationsOf(context);
    if (!_motion) {
      _ticker.stop();
      _visible = _target.length;
    } else {
      _start();
    }
  }

  @override
  void didUpdateWidget(SmoothConversationText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      oldWidget.source?.removeListener(_receive);
      widget.source?.addListener(_receive);
    }
    if (oldWidget.directory != widget.directory) _rendered = null;
    final live = widget.source?.value;
    _setTarget(live != null && live.isNotEmpty ? live : widget.text);
  }

  void _receive() {
    final value = widget.source?.value;
    // Reset events are followed by a durable projection in the same event turn.
    if (value == null || value.isEmpty || value == _target) return;
    _setTarget(value);
    if (_active && !_ticker.isActive && mounted) setState(() {});
  }

  void _setTarget(String value) {
    if (value == _target) return;
    final append = value.startsWith(_target);
    _target = value;
    if (!append || !_motion) _visible = value.length;
    _start();
  }

  void _start() {
    if (!_motion || _visible >= _target.length || _ticker.isActive) return;
    _last = Duration.zero;
    _fraction = 0;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final seconds = ((elapsed - _last).inMicroseconds / Duration.microsecondsPerSecond).clamp(0.0, .05);
    _last = elapsed;
    final remaining = _target.length - _visible;
    final speed = (remaining / .12).clamp(widget.streaming ? 90.0 : 180.0, 12000.0);
    _fraction += seconds * speed;
    final count = _fraction.floor();
    if (count == 0) return;
    _fraction -= count;
    var next = _visible;
    // Never reveal half of an emoji, combining sequence or surrogate pair.
    for (final character in _target.substring(_visible).characters) {
      next += character.length;
      if (next - _visible >= count) break;
    }
    if (next != _visible) setState(() => _visible = next);
    if (_visible >= _target.length) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    final text = _target.substring(0, _visible);
    if (text != _rendered) {
      _rendered = text;
      _markdown = ConversationMarkdown(text: text, directory: widget.directory);
    }
    return RepaintBoundary(child: _markdown!);
  }

  @override
  void dispose() {
    widget.source?.removeListener(_receive);
    _ticker.dispose();
    super.dispose();
  }
}
