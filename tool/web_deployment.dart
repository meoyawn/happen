import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

Future<Json> readWebDeployment(CancellationToken cancellation, {bool optional = false}) async {
  cancellation.throwIfCancelled();
  final userHome = Platform.environment['HOME'];
  if (userHome == null) throw StateError('HOME is required to locate private deployment settings');
  final file = File('$userHome/.secrets/happen/deployment.json');
  if (!await file.exists()) {
    if (optional) return {};
    throw StateError('Configure ~/.secrets/happen/deployment.json before deploying; see packages/server/README.md');
  }
  return jsonObject(jsonDecode(await file.readAsString().asCancellable(cancellation)));
}
