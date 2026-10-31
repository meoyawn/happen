// Ported from harness/client's current composer controls; see docs/decisions.md.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';



/// Presentation states of the shipped A4u microphone control. The recorder owns
/// all capture, cancellation, transcription and retry work outside this widget.
enum DictationUiPhase { idle, starting, recording, transcribing, retry }

class DictationButton extends StatelessWidget {
  const DictationButton({
    super.key,
    required this.phase,
    required this.onStart,
    required this.onStop,
    required this.onCancel,
    required this.onRetry,
    this.enabled = true,
    this.size = 28,
    this.palette,
    this.shortcutLabel,
    this.amplitude,
    this.statusHint,
    this.cancelOnWaveformTap,
  });

  final DictationUiPhase phase;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final bool enabled;
  final double size;
  final DictationPalette? palette;
  final String? shortcutLabel;
  final ValueListenable<double>? amplitude;
  final String? statusHint;
  final bool? cancelOnWaveformTap;

  @override
  Widget build(BuildContext context) {
    final colors = palette ?? DictationPalette.defaults;
    final label = switch (phase) {
      DictationUiPhase.idle => 'Dictate',
      DictationUiPhase.starting => 'Starting dictation; click to cancel',
      DictationUiPhase.recording => 'Stop dictation',
      DictationUiPhase.transcribing => 'Finishing dictation',
      DictationUiPhase.retry => 'Retry dictation',
    };
    final tooltip = phase == DictationUiPhase.starting
        ? 'Starting dictation…'
        : phase == DictationUiPhase.idle && shortcutLabel != null
        ? '$label ($shortcutLabel)'
        : phase == DictationUiPhase.recording && statusHint != null ? '$label · $statusHint' : label;
    final loading = phase == DictationUiPhase.starting ||
        phase == DictationUiPhase.transcribing;
    final outlined = phase == DictationUiPhase.recording ||
        phase == DictationUiPhase.transcribing;
    final callback = switch (phase) {
      DictationUiPhase.idle => onStart,
      DictationUiPhase.starting => onCancel,
      DictationUiPhase.recording => onStop,
      DictationUiPhase.transcribing => null,
      DictationUiPhase.retry => onRetry,
    };
    final compact = amplitude != null;
    final showWaveform = compact && phase == DictationUiPhase.recording;
    final icon = loading
        ? _DictationSpinner(color: colors.ink)
        : SvgPicture.string(
            phase == DictationUiPhase.recording
                ? _stopSvg
                : phase == DictationUiPhase.retry
                ? _retrySvg
                : _microphoneSvg,
            width: 16,
            height: 16,
            colorFilter: ColorFilter.mode(colors.ink, BlendMode.srcIn),
            excludeFromSemantics: true,
          );
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      alignment: AlignmentDirectional.centerEnd,
      child: _DictationControl(
      label: label,
      tooltip: tooltip,
      onPressed: enabled ? callback : null,
      size: size,
      outlined: outlined,
      palette: colors,
      uniform: !showWaveform,
      child: showWaveform ? Row(mainAxisSize: MainAxisSize.min, children: [
        _DictationWaveformAction(enabled: enabled && cancelOnWaveformTap == true, onCancel: onCancel, child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 8, end: 4),
          child: SizedBox(width: 32, height: 20,
            child: DictationLevelWaveform(amplitude: amplitude!, color: colors.foregroundTertiary)),
        )),
        SizedBox.square(dimension: size, child: Center(child: icon)),
      ]) : icon,
      ),
    );
  }
}

/// The annotation's waveform and stop icon retain separate hit targets.
class _DictationWaveformAction extends StatelessWidget {
  const _DictationWaveformAction({required this.enabled, required this.onCancel, required this.child});
  final bool enabled;
  final VoidCallback onCancel;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Semantics(label: 'Cancel dictation', button: true, child: Tooltip(message: 'Cancel dictation',
      child: FocusableActionDetector(mouseCursor: SystemMouseCursors.click,
        shortcuts: const {SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(), SingleActivator(LogicalKeyboardKey.space): ActivateIntent()},
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) { onCancel(); return null; })},
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onCancel, child: child))));
  }
}

/// l8q/o3u's six-bar audio level model, shared by compact mic and sidebar.
class DictationLevelWaveform extends StatefulWidget {
  const DictationLevelWaveform({super.key, required this.amplitude, required this.color});
  final ValueListenable<double> amplitude;
  final Color color;
  @override
  State<DictationLevelWaveform> createState() => _DictationLevelWaveformState();
}

class _DictationLevelWaveformState extends State<DictationLevelWaveform> with SingleTickerProviderStateMixin {
  final _levels = _DictationLevels();
  late final Ticker _ticker = createTicker(_tick);
  Duration _elapsed = Duration.zero;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    widget.amplitude.addListener(_receive);
    _receive();
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(DictationLevelWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.amplitude != widget.amplitude) {
      oldWidget.amplitude.removeListener(_receive);
      widget.amplitude.addListener(_receive);
      _receive();
    }
  }

  void _receive() => _levels.receive(widget.amplitude.value, _elapsed.inMicroseconds / 1e6);
  void _tick(Duration elapsed) {
    _levels.advance((elapsed - _elapsed).inMicroseconds / 1e6, elapsed.inMicroseconds / 1e6, _reducedMotion);
    _elapsed = elapsed;
  }

  @override
  void dispose() {
    widget.amplitude.removeListener(_receive);
    _ticker.dispose();
    _levels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(child: RepaintBoundary(
    child: CustomPaint(painter: _DictationLevelPainter(_levels, widget.color), child: const SizedBox.expand()),
  ));
}

class _DictationLevels extends ChangeNotifier {
  static const shape = [.64, .88, 1.0, 1.0, .82, .58];
  final levels = List<double>.filled(6, 0);
  final _audio = List<double>.filled(6, 0);
  double _input = 0;
  double _inputTime = double.negativeInfinity;
  double _time = 0;

  void receive(double rms, double time) {
    if (!rms.isFinite) return;
    _input = rms < .0025 ? 0 : (rms * 8).clamp(0.0, 1.0);
    _inputTime = time;
  }

  void advance(double delta, double time, bool reducedMotion) {
    final dt = delta.clamp(0.0, 1 / 15);
    _time += dt;
    final input = time - _inputTime <= .3 ? _input : 0;
    for (var i = 0; i < levels.length; i++) {
      final modulation = reducedMotion ? .8 : .72 + .28 * math.sin(_time * (4.6 + .71 * i) + 1.67 * i);
      final target = (input * shape[i] * modulation).clamp(0.0, 1.0);
      final smoothing = target > _audio[i] ? .04 : .16;
      _audio[i] += (target - _audio[i]) * (1 - math.exp(-dt / smoothing));
      final t = 2 * _time - .055 * i;
      final pulse = reducedMotion || t < 0 ? 0.0 : t < .18 ? .5 - .5 * math.cos(math.pi * t / .18)
          : t < .23 ? 1.0 : t < .53 ? .5 + .5 * math.cos(math.pi * (t - .23) / .3) : 0.0;
      levels[i] = math.max(_audio[i], pulse);
    }
    notifyListeners();
  }
}

class _DictationLevelPainter extends CustomPainter {
  _DictationLevelPainter(this.levels, this.color) : super(repaint: levels);
  final _DictationLevels levels;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var i = 0; i < levels.levels.length; i++) {
      final height = 3 + levels.levels[i] * (math.min(size.height, 20) - 3);
      canvas.drawRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH((size.width - 27) / 2 + 5 * i, (size.height - height) / 2, 2, height),
        const Radius.circular(1)), paint);
    }
  }
  @override
  bool shouldRepaint(_DictationLevelPainter oldDelegate) => levels != oldDelegate.levels || color != oldDelegate.color;
}

/// The source D$e cancel action, placed in the active main composer's leading
/// slot at the user's explicit request. It aborts capture/transcription through
/// the captured owner; it never inserts text or submits a follow-up.
class DictationCancelButton extends StatelessWidget {
  const DictationCancelButton({super.key, required this.onCancel, this.palette, this.size = 28});

  final VoidCallback onCancel;
  final DictationPalette? palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = palette ?? DictationPalette.defaults;
    return _DictationControl(
      label: 'Cancel dictation',
      tooltip: 'Cancel dictation',
      onPressed: onCancel,
      size: size,
      palette: colors,
      child: SvgPicture.string(
        _dismissSvg,
        width: 16,
        height: 16,
        colorFilter: ColorFilter.mode(colors.ink, BlendMode.srcIn),
        excludeFromSemantics: true,
      ),
    );
  }
}

enum DictationRecoveryPhase { recovering, recovered, failed }

/// Xbd's composer-rail row. Its surrounding attached rail surface belongs to
/// the composer; no dialog, draft replacement, or clipboard write occurs here.
class DictationRecoveryRail extends StatelessWidget {
  const DictationRecoveryRail({
    super.key,
    required this.phase,
    required this.onDismiss,
    this.onRetry,
    this.onInsertText,
    this.onViewRecording,
    this.palette,
  });

  final DictationRecoveryPhase phase;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;
  final VoidCallback? onInsertText;
  final VoidCallback? onViewRecording;
  final DictationPalette? palette;

  @override
  Widget build(BuildContext context) {
    final colors = palette ?? DictationPalette.defaults;
    final label = switch (phase) {
      DictationRecoveryPhase.recovering => 'Recovering text…',
      DictationRecoveryPhase.recovered => 'Text recovered',
      DictationRecoveryPhase.failed => 'Dictation stopped',
    };
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 28),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (phase == DictationRecoveryPhase.recovering) ...[
                    _DictationSpinner(color: colors.foregroundTertiary, size: 16),
                    const SizedBox(width: 8),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        height: 20 / 14,
                        color: colors.foregroundTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                if (phase == DictationRecoveryPhase.recovered && onInsertText != null)
                  _RecoveryAction(label: 'Add to message', onPressed: onInsertText!, palette: colors),
                if (onViewRecording != null)
                  _RecoveryAction(label: 'View recording', onPressed: onViewRecording!, palette: colors),
                if (phase == DictationRecoveryPhase.failed && onRetry != null)
                  _RecoveryAction(label: 'Retry', onPressed: onRetry!, palette: colors),
                _DictationControl(
                  label: 'Dismiss',
                  tooltip: 'Dismiss',
                  onPressed: onDismiss,
                  size: 24,
                  palette: colors,
                  child: SvgPicture.string(
                    _dismissSvg,
                    width: 16,
                    height: 16,
                    colorFilter: ColorFilter.mode(colors.foregroundTertiary, BlendMode.srcIn),
                    excludeFromSemantics: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryAction extends StatelessWidget {
  const _RecoveryAction({required this.label, required this.onPressed, required this.palette});

  final String label;
  final VoidCallback onPressed;
  final DictationPalette palette;

  @override
  Widget build(BuildContext context) => _DictationControl(
    label: label,
    tooltip: label,
    onPressed: onPressed,
    size: 28,
    uniform: false,
    palette: palette,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(label, style: TextStyle(fontSize: 13, color: palette.ink)),
    ),
  );
}

class _DictationControl extends StatefulWidget {
  const _DictationControl({
    required this.label,
    required this.tooltip,
    required this.onPressed,
    required this.size,
    required this.palette,
    required this.child,
    this.uniform = true,
    this.outlined = false,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final bool uniform;
  final bool outlined;
  final DictationPalette palette;
  final Widget child;

  @override
  State<_DictationControl> createState() => _DictationControlState();
}

class _DictationControlState extends State<_DictationControl> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final colors = widget.palette;
    return TextFieldTapRegion(child: Tooltip(
      message: widget.tooltip,
      child: Opacity(
        opacity: enabled ? 1 : .4,
        child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          label: widget.label,
          enabled: enabled,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: Container(
              width: widget.uniform ? widget.size : null,
              height: widget.size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.size / 2),
                color: enabled && _pressed
                    ? colors.secondaryActive
                    : enabled && _hovered
                    ? colors.secondaryHover
                    : Colors.transparent,
                border: _focused
                    ? Border.all(color: colors.ink, width: 2)
                    : widget.outlined
                    ? Border.all(color: colors.border)
                    : null,
              ),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
      ),
    ));
  }
}

class _DictationSpinner extends StatefulWidget {
  const _DictationSpinner({required this.color, this.size = 12});

  final Color color;
  final double size;

  @override
  State<_DictationSpinner> createState() => _DictationSpinnerState();
}

class _DictationSpinnerState extends State<_DictationSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _rotation.stop();
    } else if (!_rotation.isAnimating) {
      _rotation.repeat();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RotationTransition(
      turns: _rotation,
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(painter: _SpinnerPainter(widget.color)),
      ),
    ),
  );
}

class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [color.withValues(alpha: 0), color],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawCircle(rect.center, math.max(0, size.shortestSide / 2 - 1), paint);
  }

  @override
  bool shouldRepaint(_SpinnerPainter oldDelegate) => color != oldDelegate.color;
}

// Exact static vector carriers: b4u/y4u, clr/slr, and Zwo/Xwo in the retained
// app-initial bundle. Dismiss resolves Xbd/fa → app-shared SJ/i2 → H0,
// xmark-md-light-16. These SVGs never execute reference application JS.
const _microphoneSvg = '''<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20" fill="currentColor"><g transform="scale(0.8333333333333334)"><path d="M18.5848 13.4121C18.7715 12.9516 19.2961 12.7296 19.7567 12.916C20.217 13.1027 20.4391 13.6274 20.2528 14.0879C19.0405 17.0826 16.2438 19.2675 12.9003 19.6035V22C12.9003 22.4971 12.4969 22.9004 11.9999 22.9004C11.5029 22.9003 11.0995 22.497 11.0995 22V19.6035C7.75618 19.2673 4.96018 17.0823 3.74791 14.0879C3.56144 13.6272 3.78344 13.1026 4.244 12.916C4.70458 12.7298 5.22933 12.9517 5.41588 13.4121C6.46985 16.0157 9.02264 17.8496 12.0008 17.8496C14.9787 17.8493 17.531 16.0155 18.5848 13.4121Z"/><path fill-rule="evenodd" clip-rule="evenodd" d="M11.9999 1.34961C14.7061 1.34961 16.9003 3.5438 16.9003 6.25V10.7334C16.9003 13.4396 14.7061 15.6338 11.9999 15.6338C9.29371 15.6337 7.09947 13.4396 7.09947 10.7334V6.25C7.09947 3.54384 9.29372 1.34967 11.9999 1.34961ZM11.9999 3.15039C10.2878 3.15045 8.90025 4.53795 8.90025 6.25V10.7334C8.90025 12.4454 10.2878 13.8339 11.9999 13.834C13.7119 13.834 15.0995 12.4455 15.0995 10.7334V6.25C15.0995 4.53792 13.7119 3.15039 11.9999 3.15039Z"/></g></svg>''';
const _stopSvg = '''<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20" fill="currentColor"><path d="M4.5 5.75C4.5 5.05964 5.05964 4.5 5.75 4.5H14.25C14.9404 4.5 15.5 5.05964 15.5 5.75V14.25C15.5 14.9404 14.9404 15.5 14.25 15.5H5.75C5.05964 15.5 4.5 14.9404 4.5 14.25V5.75Z"/></svg>''';
const _retrySvg = '''<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20" fill="none"><path d="M3.50205 16.6664V13.3333C3.50205 12.9661 3.79982 12.6683 4.16709 12.6683H7.5001L7.63389 12.682C7.93696 12.7439 8.16514 13.0119 8.16514 13.3333C8.16514 13.6547 7.93696 13.9227 7.63389 13.9847L7.5001 13.9984H5.47471C6.58687 15.2249 8.21848 16.0013 10.0001 16.0013C13.06 16.0013 15.586 13.711 15.9552 10.7513L15.9854 10.6195C16.0846 10.3266 16.3786 10.1335 16.6974 10.1732C17.0617 10.2186 17.3198 10.551 17.2745 10.9154L17.2247 11.2523C16.6301 14.7051 13.6225 17.3313 10.0001 17.3314C8.01108 17.3314 6.17193 16.5383 4.83213 15.2474V16.6664C4.83213 17.0335 4.53416 17.3312 4.16709 17.3314C3.79982 17.3314 3.50205 17.0336 3.50205 16.6664ZM4.04502 9.24936C3.99941 9.61354 3.66706 9.87179 3.30283 9.82651C2.93839 9.78106 2.67926 9.44877 2.72471 9.08432L4.04502 9.24936ZM10.0001 2.6683C11.994 2.66834 13.8372 3.46552 15.1778 4.76205V3.33334C15.1778 2.96617 15.4757 2.66846 15.8429 2.6683C16.2101 2.6683 16.5079 2.96607 16.5079 3.33334V6.66635C16.5079 7.03362 16.2101 7.33139 15.8429 7.33139H12.5099C12.1426 7.33139 11.8448 7.03362 11.8448 6.66635C11.845 6.29923 12.1427 6.00131 12.5099 6.00131H14.5255C13.4134 4.77489 11.7816 3.99842 10.0001 3.99838C6.94004 3.99838 4.41411 6.28948 4.04502 9.24936L3.38486 9.16635L2.72471 9.08432C3.1758 5.46703 6.26081 2.6683 10.0001 2.6683Z" fill="currentColor"/></svg>''';
const _dismissSvg = '''<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M10.962 4.29539C11.1669 4.09057 11.4992 4.09076 11.7042 4.29539C11.9092 4.50039 11.9091 4.83255 11.7042 5.03758L8.74229 7.99949L11.7052 10.9624C11.9097 11.1673 11.9097 11.4996 11.7052 11.7046C11.5003 11.9095 11.168 11.9093 10.963 11.7046L8.0001 8.74168L5.03721 11.7046C4.83216 11.9093 4.49994 11.9095 4.29502 11.7046C4.09047 11.4996 4.09045 11.1673 4.29502 10.9624L7.25791 7.99949L4.296 5.03758C4.09101 4.83255 4.09099 4.5004 4.296 4.29539C4.50105 4.09079 4.8333 4.09054 5.03819 4.29539L8.0001 7.2573L10.962 4.29539Z" fill="currentColor"/></svg>''';

class DictationPalette {
  const DictationPalette();
  static const defaults = DictationPalette();
  Color get ink => const Color(0xff1a1c1f);
  Color get foregroundTertiary => ink.withValues(alpha: .495);
  Color get border => ink.withValues(alpha: .078);
  Color get secondaryHover => ink.withValues(alpha: .054);
  Color get secondaryActive => ink.withValues(alpha: .039);
}
