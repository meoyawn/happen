import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

Future<Directory> miseFlutterSdk(Directory workspace, CancellationToken cancellation) async {
  const arguments = ['which', 'flutter'];
  cancellation.throwIfCancelled();
  final process = await Process.start('mise', arguments, workingDirectory: workspace.path);
  final hook = CancellationHook(cancellation, process.kill);
  try {
    final output = await Future.wait([
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
    ]).asCancellable(cancellation);
    final code = await process.exitCode.asCancellable(cancellation);
    if (code != 0) throw ProcessException('mise', arguments, output[1].trim(), code);
    final flutter = File(output[0].trim());
    return File(await flutter.resolveSymbolicLinks()).parent.parent;
  } finally { hook.dispose(); }
}
