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
          setState(() => _confirmation = Timer(const Duration(seconds: 3), _dismissConfirmation));
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
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      if (_confirmation != null)
        BlockSemantics(child: GestureDetector(
          onTap: _dismissConfirmation,
          child: ColoredBox(
            color: const Color(0x55000000),
            child: Center(child: Semantics(
              liveRegion: true,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('Press ${defaultTargetPlatform == TargetPlatform.macOS ? '⌘Q' : 'Ctrl+Q'} again to quit',
                      style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text('Quitting stops running tasks.'),
                    const SizedBox(height: 16),
                    const Text('Escape to cancel', style: TextStyle(color: Colors.black54)),
                  ]),
                ),
              ),
            )),
          ),
        )),
    ],
  );
}
