import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/daemon.dart';

Future<void> main(List<String> arguments) async {
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  try {
    final parser = ArgParser()
      ..addOption('data-dir', defaultsTo: defaultDataDirectory())
      ..addOption('config')
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addFlag('version', negatable: false);
    final args = parser.parse(arguments);
    if (args['version'] == true) { stdout.writeln('happen-server 0.1.0'); return; }
    if (args['help'] == true || args.rest.isEmpty) {
      stdout.writeln('happen-server daemon <start|status|stop|restart>\n'
        'happen-server login-from-codex\n\n${parser.usage}');
      return;
    }
    final directory = Directory(args['data-dir'] as String).absolute.path;
    if (args.rest.length == 2 && args.rest.first == 'daemon') {
      stdout.writeln(jsonEncode(await daemonCommand(args.rest[1], directory,
        configPath: args['config'] as String?, cancellation: cancellation)));
    } else if (args.rest.length == 1 && args.rest.first == '_serve') {
      await serveDaemon(directory, configPath: args['config'] as String?, cancellation: cancellation);
    } else if (args.rest.length == 1 && args.rest.first == 'login-from-codex') {
      final auth = AuthManager(directory);
      try { await auth.useCodex(); stdout.writeln('Using the existing remote Codex login.'); }
      finally { auth.close(); }
    } else { throw ArgumentError('Unknown command. Use --help.'); }
  } on CancelledException { exitCode = 130; }
  catch (error) { stderr.writeln(error); exitCode = 1; }
  finally {
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
  }
}
