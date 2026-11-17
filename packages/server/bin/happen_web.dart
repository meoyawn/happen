import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:protocol/protocol.dart';
import 'package:server/web_gateway.dart';
import 'package:config/web.dart';

Future<void> main(List<String> arguments) async {
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  WebGateway? gateway;
  try {
    final home = Platform.environment['HOME']!;
    final args = (ArgParser()
      ..addOption('socket', defaultsTo: '$home/.local/share/agent-server/server.sock')
      ..addOption('config')
      ..addOption('owner-key-file')
      ..addOption('public-url')
      ..addMultiOption('allowed-origin', help: 'Additional web client origins allowed to authenticate directly')
      ..addOption('port')).parse(arguments);
    final config = await loadWebConfiguration(path: args['config'] as String?, cancellation: cancellation);
    final publicUrl = args['public-url'] as String? ?? config.publicUrl;
    if (publicUrl == null) throw ArgumentError('Set web.public_url in Happen config or pass --public-url');
    gateway = await WebGateway.start(socketPath: args['socket'] as String,
      publicUrl: publicUrl,
      ownerKeyFile: args['owner-key-file'] as String? ?? config.ownerKeyFile,
      allowedOrigins: {...config.allowedOrigins, ...args['allowed-origin'] as List<String>},
      port: args['port'] == null ? config.port : int.parse(args['port'] as String));
    stdout.writeln('Happen web listening on 127.0.0.1:${gateway.http.port} for $publicUrl');
    await CancellableCompleter<void>(cancellation).future;
  } on CancelledException { /* Process shutdown. */ }
  finally {
    cancellation.cancel();
    await gateway?.close();
    for (final signal in signals) { await signal.cancel(); }
  }
}
