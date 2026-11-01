import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Empty header space behaves like a native title bar; controls keep their taps.
class DesktopWindowDragRegion extends StatelessWidget {
  const DesktopWindowDragRegion({super.key, required this.child});
  final Widget child;
  static const _desktop = MethodChannel('happen/desktop');

  @override
  Widget build(BuildContext context) => defaultTargetPlatform != TargetPlatform.macOS ? child : GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => unawaited(_desktop.invokeMethod<void>('startWindowDrag')),
    onDoubleTap: () => unawaited(_desktop.invokeMethod<void>('titlebarDoubleClick')),
    child: child,
  );
}
