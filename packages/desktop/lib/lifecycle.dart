import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

sealed class _QuitState { const _QuitState(); }
final class _Running extends _QuitState { const _Running(); }
final class _Confirming extends _QuitState {
  const _Confirming(this.timer);
  final Timer timer;
}
final class _Quitting extends _QuitState {
  const _Quitting(this.done);
  final Future<void> done;
}

_QuitState _transition(_QuitState current, _QuitState next) => switch ((current, next)) {
  (_Running(), _Confirming() || _Quitting()) || (_Confirming(), _Running() || _Quitting()) => next,
  _ => throw StateError('Invalid desktop quit transition'),
};

/// Window visibility is native; only an explicit quit releases the server.
class DesktopLifecycle extends StatefulWidget {
  const DesktopLifecycle({super.key, required this.onQuit, this.onResume,
    required this.hasActiveLocalTasks, required this.child});

  final Future<void> Function() onQuit;
  final VoidCallback? onResume;
  final bool hasActiveLocalTasks;
  final Widget child;

  @override
  State<DesktopLifecycle> createState() => _DesktopLifecycleState();
}

class _DesktopLifecycleState extends State<DesktopLifecycle> {
  static const _channel = MethodChannel('happen/lifecycle');
  late final AppLifecycleListener _lifecycle;
  _QuitState _state = const _Running();

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'quit') throw MissingPluginException();
      await _exit();
    });
    _lifecycle = AppLifecycleListener(
      onResume: () { if (_state is! _Quitting) widget.onResume?.call(); },
      onInactive: _dismissConfirmation,
      onHide: _dismissConfirmation,
      onExitRequested: () async {
        // Flutter visits a snapshot of observers. Let that dispatch finish
        // before shutdown disposes any of the later observers.
        Timer.run(() => unawaited(_exit()));
        return AppExitResponse.cancel;
      },
    );
  }

  @override
  void didUpdateWidget(DesktopLifecycle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hasActiveLocalTasks) _dismissConfirmation();
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (_state is _Quitting) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final macOS = defaultTargetPlatform == TargetPlatform.macOS;
    final desktop = macOS || defaultTargetPlatform == TargetPlatform.windows;
    final primary = macOS ? keyboard.isMetaPressed : keyboard.isControlPressed;
    if (desktop && event.logicalKey == LogicalKeyboardKey.keyQ && primary &&
        !keyboard.isAltPressed && !keyboard.isShiftPressed &&
        !(macOS ? keyboard.isControlPressed : keyboard.isMetaPressed)) {
      // Holding the key must never confirm quitting through key repeat.
      if (event is KeyDownEvent) {
        if (!widget.hasActiveLocalTasks || _state is _Confirming) {
          unawaited(_exit());
        } else {
          _set(_Confirming(Timer(const Duration(seconds: 1), _dismissConfirmation)));
        }
      }
      return KeyEventResult.handled;
    }
    if (_state is _Confirming && event is KeyDownEvent &&
        !{LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
          LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight}.contains(event.logicalKey)) {
      _dismissConfirmation();
      if (event.logicalKey == LogicalKeyboardKey.escape) return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _set(_QuitState next) => setState(() => _state = _transition(_state, next));

  void _dismissConfirmation() {
    if (_state case _Confirming(:final timer)) {
      timer.cancel();
      _set(const _Running());
    }
  }

  Future<void> _exit() {
    if (!mounted) return Future.value();
    if (_state case _Quitting(:final done)) return done;
    if (_state case _Confirming(:final timer)) timer.cancel();
    final done = Completer<void>();
    _set(_Quitting(done.future));
    done.complete(_exitAfterClosing());
    return done.future;
  }

  Future<void> _exitAfterClosing() async {
    try {
      await widget.onQuit();
    } finally {
      // Cleanup precedes the required native exit, including from a hidden tray.
      await ServicesBinding.instance.exitApplication(AppExitType.required);
    }
  }

  @override
  void dispose() {
    if (_state case _Confirming(:final timer)) timer.cancel();
    _lifecycle.dispose();
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = switch (_state) {
      _Running() => null,
      _Confirming() => 'Press ${defaultTargetPlatform == TargetPlatform.macOS ? '⌘Q' : 'Ctrl+Q'} again to quit',
      _Quitting() => 'Quitting…',
    };
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _dismissConfirmation(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_state is _Quitting)
            ColoredBox(color: Theme.of(context).scaffoldBackgroundColor)
          else
            widget.child,
          IgnorePointer(child: Center(child: AnimatedSwitcher(
            duration: Duration.zero,
            reverseDuration: const Duration(milliseconds: 200),
            child: message == null ? null : Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xbf333333),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                    child: Text(message,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        inherit: false,
                        fontFamily: Theme.of(context).textTheme.titleLarge?.fontFamily,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        height: 1.25,
                        shadows: const [Shadow(color: Color(0x99000000), offset: Offset(0, 1), blurRadius: 1)],
                      )),
                  ),
                ),
              ),
            ),
          ))),
        ],
      ),
    );
  }
}
