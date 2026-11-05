import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

// A real server process, not an isolate restart or a special restoration API.
Future<void> main(List<String> arguments) async {
  final options = jsonObject(jsonDecode(arguments.single));
  final lifetime = TimeoutCancellationToken(const Duration(minutes: 3));
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((s) => s.watch().listen((_) => lifetime.cancel())).toList();
  final commands = utf8.decoder.bind(stdin).transform(const LineSplitter()).listen((_) => lifetime.cancel());
  final server = await AgentServer.start(directory: options['directory'] as String, port: 0,
    configPath: '${options['directory']}/config.yaml', skillsHome: options['directory'] as String,
    endpoint: options['endpoint'] as String, telemetry: false);
  stdout.writeln(jsonEncode({'uri': server.uri.toString(), 'pid': pid}));
  try { await Completer<void>().future.asCancellable(lifetime); }
  on CancelledException { /* Parent requested graceful shutdown. */ }
  finally {
    await server.close(); await commands.cancel(); for (final signal in signals) { await signal.cancel(); }
  }
}
