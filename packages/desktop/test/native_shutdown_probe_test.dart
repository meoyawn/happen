import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:desktop/main_native.dart' as desktop;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native shutdown detaches the view before requesting process exit', () async {
    final binding = _ShutdownProbeBinding();
    desktop.main();
    await binding.endOfFrame.timeout(const Duration(seconds: 5));
    expect(binding.renderViews, hasLength(1));

    expect(await binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(await binding.exitRequested.future.timeout(const Duration(seconds: 10)), AppExitType.required);
    expect(binding.renderViews, isEmpty);
  });
}

class _ShutdownProbeBinding extends WidgetsFlutterBinding {
  final exitRequested = Completer<AppExitType>();

  @override
  Future<AppExitResponse> exitApplication(AppExitType type, [int exitCode = 0]) async {
    exitRequested.complete(type);
    return AppExitResponse.exit;
  }
}
