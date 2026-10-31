import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Window visibility is native; only an explicit quit releases the server.
class DesktopLifecycle extends StatefulWidget {
  const DesktopLifecycle({super.key, required this.onQuit, this.onResume, required this.child});

  final Future<void> Function() onQuit;
  final VoidCallback? onResume;
  final Widget child;

  @override
  State<DesktopLifecycle> createState() => _DesktopLifecycleState();
}

class _DesktopLifecycleState extends State<DesktopLifecycle> {
  static const _channel = MethodChannel('happen/lifecycle');
  late final AppLifecycleListener _lifecycle;
  Timer? _confirmation;
  Future<void>? _closing, _exiting;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'quit') throw MissingPluginException();
      await _exit();
    });
    _lifecycle = AppLifecycleListener(
      onResume: () => widget.onResume?.call(),
      onInactive: _dismissConfirmation,
      onHide: _dismissConfirmation,
      onExitRequested: () async {
        await _close();
        return AppExitResponse.exit;
      },
    );
  }

  KeyEventResult _handleKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final macOS = defaultTargetPlatform == TargetPlatform.macOS;
    final desktop = macOS || defaultTargetPlatform == TargetPlatform.windows;
    final primary = macOS ? keyboard.isMetaPressed : keyboard.isControlPressed;
    if (desktop && event.logicalKey == LogicalKeyboardKey.keyQ && primary &&
        !keyboard.isAltPressed && !keyboard.isShiftPressed &&
        !(macOS ? keyboard.isControlPressed : keyboard.isMetaPressed)) {
      // Holding the key must never confirm quitting through key repeat.
      if (event is KeyDownEvent && _closing == null) {
        if (_confirmation != null) {
          unawaited(_exit());
        } else {
          setState(() => _confirmation = Timer(const Duration(seconds: 1), _dismissConfirmation));
        }
      }
      return KeyEventResult.handled;
    }
    if (_confirmation != null && event is KeyDownEvent &&
        !{LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
          LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight}.contains(event.logicalKey)) {
      _dismissConfirmation();
      if (event.logicalKey == LogicalKeyboardKey.escape) return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _dismissConfirmation() {
    if (_confirmation == null) return;
    _confirmation!.cancel();
    setState(() => _confirmation = null);
  }

  Future<void> _close() {
    _dismissConfirmation();
    return _closing ??= widget.onQuit();
  }

  Future<void> _exit() => _exiting ??= _exitAfterClosing();

  Future<void> _exitAfterClosing() async {
    try {
      await _close();
    } finally {
      // Cleanup precedes the required native exit, including from a hidden tray.
      await ServicesBinding.instance.exitApplication(AppExitType.required);
    }
  }

  @override
  void dispose() {
    _confirmation?.cancel();
    _lifecycle.dispose();
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _dismissConfirmation(),
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(child: Center(child: AnimatedSwitcher(
          duration: Duration.zero,
          reverseDuration: const Duration(milliseconds: 200),
          child: _confirmation == null ? null : Semantics(
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
                  child: Text('Press ${defaultTargetPlatform == TargetPlatform.macOS ? '⌘Q' : 'Ctrl+Q'} again to quit',
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
