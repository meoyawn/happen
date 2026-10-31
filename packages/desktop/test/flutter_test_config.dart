import 'dart:async';

import 'package:cross_file_io/cross_file_io.dart';
import 'package:desktop_drop/src/native_transport.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Widget tests have no native Flutter engine. Keep the actual drop widget
  // and coordinator; substitute only the OS transport's view registration.
  setUpAll(() {
    CrossFileIO.registerWith();
    NativeTransport.debugOverride = NativeTransport.testing()
      ..invokeHandler = (call) async => switch (call.method) {
        'initialize' => {'view': (call.arguments as Map)['view']},
        'dispose' => null,
        _ => throw StateError('Unexpected native drop call: ${call.method}'),
      };
  });
  tearDownAll(() => NativeTransport.debugOverride = null);
  await testMain();
}
