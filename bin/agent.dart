import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

ArgParser parser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption('data-dir', defaultsTo: defaultDataDirectory());
  parser.addCommand(
    'login',
    ArgParser()
      ..addFlag('device', negatable: false)
      ..addFlag('from-codex', negatable: false)
      ..addOption('codex-auth'),
  );
  parser.addCommand(
    'serve',
    ArgParser()
      ..addOption('host', defaultsTo: '127.0.0.1')
      ..addOption('port', defaultsTo: '8765')
      ..addOption('socket')
      ..addOption('token')
      ..addOption('max-agents', defaultsTo: '256')
      ..addFlag('telemetry', defaultsTo: true),
  );
  parser.addCommand(
    'exec',
    ArgParser()
      ..addOption('url')
      ..addOption('token')
      ..addOption('cwd', defaultsTo: Directory.current.path)
      ..addOption('provider', allowed: ['gpt', 'deepseek'])
      ..addOption('model')
      ..addOption('reasoning')
      ..addOption('max-steps', defaultsTo: '64')
      ..addOption('resume')
      ..addFlag('json', negatable: false)
      ..addFlag('telemetry', defaultsTo: true),
  );
  parser.addCommand(
    'request',
    ArgParser()
      ..addOption('url', defaultsTo: 'ws://127.0.0.1:8765/ws')
      ..addOption('token'),
  );
  return parser;
}

Future<void> main(List<String> arguments) async {
  try {
    await run(arguments);
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

Future<void> run(List<String> arguments) async {
  final options = parser();
  final parsed = options.parse(arguments);
  final command = parsed.command;
  if (parsed['help'] == true || command == null) {
    stdout.writeln(
      'Agent server\n\n  agent login [--device | --from-codex]\n  agent serve [--port 8765]\n  agent exec [--url ws://127.0.0.1:8765/ws] "task"\n  agent request METHOD \'{"parameter":"value"}\'\n\n${options.usage}',
    );
    return;
  }
  final directory = Directory(parsed['data-dir'] as String).absolute.path;
  switch (command.name) {
    case 'login':
      final auth = AuthManager(directory);
      try {
        if (command['from-codex'] == true) {
          await auth.useCodex(command['codex-auth'] as String?);
          await auth.credentials();
        } else {
          await auth.login(
            device: command['device'] as bool,
            notify: (url, message) {
              stdout.writeln('$message\n$url');
              if (command['device'] == false && Platform.isMacOS) {
                unawaited(Process.run('open', [url]));
              }
            },
          );
        }
        stdout.writeln('ChatGPT login ready.');
      } finally {
        auth.close();
      }
    case 'serve':
      final server = await AgentServer.start(
        directory: directory,
        host: command['host'] as String,
        port: int.parse(command['port'] as String),
        socketPath: command['socket'] as String?,
        token: command['token'] as String?,
        maxAgents: int.parse(command['max-agents'] as String),
        telemetry: command['telemetry'] as bool,
      );
      stdout.writeln(server.uri);
      final done = Completer<void>();
      final subscriptions = [ProcessSignal.sigint, ProcessSignal.sigterm]
          .map(
            (signal) => signal.watch().listen((_) {
              if (!done.isCompleted) done.complete();
            }),
          )
          .toList();
      try {
        await done.future;
      } finally {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        await server.close();
      }
    case 'exec':
      final prompt = command.rest.isEmpty
          ? (stdin.hasTerminal ? '' : await utf8.decoder.bind(stdin).join())
          : command.rest.join(' ');
      if (prompt.trim().isEmpty)
        throw ArgumentError('Provide a prompt or pipe it on stdin');
      AgentServer? embedded;
      AgentClient? client;
      StreamSubscription<Json>? events;
      StreamSubscription<ProcessSignal>? interrupt;
      try {
        final url = command['url'] as String?;
        if (url == null) {
          embedded = await AgentServer.startEmbedded(
            directory: directory,
            telemetry: command['telemetry'] as bool,
          );
        }
        client = await AgentClient.connect(
          url == null ? embedded!.uri : Uri.parse(url),
          token: command['token'] as String?,
        );
        final terminal = Completer<Json>();
        String? taskId = command['resume'] as String?;
        events = client.events.stream.listen(
          (event) {
            if (taskId != null && event['task_id'] != taskId) return;
            if (command['json'] == true) stdout.writeln(jsonEncode(event));
            if ([
                  'turn.completed',
                  'turn.failed',
                  'turn.cancelled',
                ].contains(event['type']) &&
                !terminal.isCompleted) {
              terminal.complete(event);
            }
          },
          onDone: () {
            if (!terminal.isCompleted)
              terminal.completeError(
                StateError('Disconnected before turn completion'),
              );
          },
        );
        final result = jsonObject(
          await client.request(taskId == null ? 'task.start' : 'task.send', {
            'task_id': ?taskId,
            'prompt': prompt,
            if (taskId == null || command.wasParsed('cwd'))
              'cwd': command['cwd'],
            if (command.wasParsed('provider')) 'provider': command['provider'],
            if (command.wasParsed('model')) 'model': command['model'],
            if (command.wasParsed('reasoning'))
              'reasoning': command['reasoning'],
            'max_steps': int.parse(command['max-steps'] as String),
            'telemetry': command['telemetry'],
          }),
        );
        taskId = result['task_id'] as String;
        interrupt = ProcessSignal.sigint.watch().listen((_) {
          unawaited(client!.request('task.cancel', {'task_id': taskId}));
        });
        final completed = await terminal.future;
        if (command['json'] == false) {
          if (completed['type'] == 'turn.completed') {
            stdout.writeln(completed['data']?['text'] ?? '');
          } else {
            stderr.writeln(completed['data']?['error'] ?? 'Turn failed');
          }
        }
        if (completed['type'] != 'turn.completed') exitCode = 1;
      } finally {
        await interrupt?.cancel();
        await events?.cancel();
        await client?.close();
        await embedded?.close();
      }
    case 'request':
      if (command.rest.isEmpty)
        throw ArgumentError(
          'Provide a protocol method and optional JSON parameters',
        );
      final client = await AgentClient.connect(
        Uri.parse(command['url'] as String),
        token: command['token'] as String?,
      );
      try {
        final result = await client.request(
          command.rest.first,
          command.rest.length > 1
              ? jsonObject(jsonDecode(command.rest[1]))
              : {},
        );
        stdout.writeln(jsonEncode(result));
      } finally {
        await client.close();
      }
    default:
      throw ArgumentError('Unknown command');
  }
}
