import 'dart:js_interop';
import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;

Future<bool> requestDesktopNotificationPermission({required CancellationToken cancellation}) async =>
  (await web.Notification.requestPermission().toDart.asCancellable(cancellation)).toDart == 'granted';
