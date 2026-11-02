import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:args/args.dart';
import 'package:config/config.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void addDebugCommands(ArgParser parser) {
  final commands = parser.addCommand('debug', ArgParser());
  commands.addCommand('prompt-input', ArgParser()
    ..addOption('cwd', defaultsTo: Directory.current.path)
    ..addOption('model')
    ..addOption('reasoning')
    ..addOption('endpoint', help: 'Local Responses API URL (including /responses)')
    ..addOption('api-key-env', defaultsTo: 'OPENAI_API_KEY')
    ..addOption('output', abbr: 'o'));
  commands.addCommand('context', ArgParser()..addOption('output', abbr: 'o'));
  commands.addCommand('trace-reduce', ArgParser()..addOption('output', abbr: 'o'));
}

Future<void> debug(ArgResults options, String directory, String? configPath) async {
  final command = options.command;
  if (command == null) {
    stdout.writeln('Usage: happen debug prompt-input [--cwd DIR] [PROMPT]\n       happen debug context SESSION [--output FILE]');
    return;
  }
  if (command.name == 'context' && command.rest.length != 1) throw ArgumentError('Provide exactly one session ID');
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  AgentServer? server;
  AgentClient? client;
  try {
    if (command.name == 'trace-reduce') {
      if (command.rest.length != 1) throw ArgumentError('Provide exactly one trace bundle directory');
      final bundle = Directory(command.rest.single);
      final manifest = jsonObject(jsonDecode(await File('${bundle.path}/manifest.json').readAsString()));
      if (manifest['schema_version'] != 1 || manifest['provider'] != 'openai') throw const FormatException('Unsupported Happen trace');
      final calls = <String, Json>{};
      await for (final line in File('${bundle.path}/trace.jsonl').openRead().transform(utf8.decoder).transform(const LineSplitter())) {
        cancellation.throwIfCancelled();
        final event = jsonObject(jsonDecode(line));
        final id = requiredString(event, 'id');
        final path = requiredString(event, 'payload');
        if (!RegExp(r'^payloads/[A-Za-z0-9_-]+\.json$').hasMatch(path)) throw const FormatException('Invalid trace payload path');
        final payload = jsonObject(jsonDecode(await File('${bundle.path}/$path').readAsString()));
        (calls[id] ??= {'id': id})[requiredString(event, 'type')] = payload;
      }
      final output = command['output'] as String? ?? '${bundle.path}/state.json';
      await writeContextJson({...manifest, 'inference_calls': calls.values.toList()}, output);
      if (output != '-') stdout.writeln(File(output).absolute.path);
      return;
    }
    final endpoint = command.name == 'prompt-input' ? localResponsesEndpoint(command) : null;
    server = await AgentServer.startLocal(directory: directory, configPath: configPath ?? defaultConfigPath(), telemetry: false,
      endpoint: endpoint, apiKeyEnv: endpoint == null ? null : command['api-key-env'] as String);
    cancellation.throwIfCancelled();
    client = AgentClient.local(server);
    final Object context;
    if (command.name == 'prompt-input') {
      final snapshot = jsonObject(await client.request('debug.prompt-input', {
        'cwd': command['cwd'], 'provider': 'openai', 'prompt': command.rest.join(' '),
        if (command.wasParsed('model')) 'model': command['model'],
        if (command.wasParsed('reasoning')) 'reasoning': command['reasoning'],
      }).asCancellable(cancellation, onCancel: () => client!.close()));
      context = gptInput((snapshot['input'] as List).map((item) => ConversationItem.fromJson(jsonObject(item))));
    } else {
      context = await readContextSnapshot(client, command.rest.single, cancellation: cancellation);
    }
    await writeContextJson(context, command['output'] as String?);
  } on CancelledException {
    exitCode = 130;
  } finally {
    cancellation.cancel();
    await client?.close();
    await server?.close();
    for (final signal in signals) { await signal.cancel(); }
  }
}

String? localResponsesEndpoint(ArgResults command) {
  final endpoint = command['endpoint'] as String?;
  if (endpoint == null) {
    if (command.wasParsed('api-key-env')) throw ArgumentError('--api-key-env requires --endpoint');
    return null;
  }
  final uri = Uri.tryParse(endpoint);
  if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.userInfo.isNotEmpty || uri.hasFragment ||
      !(uri.host == 'localhost' || (InternetAddress.tryParse(uri.host)?.isLoopback ?? false))) {
    throw ArgumentError('--endpoint must be an HTTP(S) loopback Responses API URL');
  }
  if ((command['api-key-env'] as String).isEmpty) throw ArgumentError('--api-key-env must not be empty');
  return endpoint;
}

Future<void> writeContextJson(Object value, String? path) async {
  final text = '${const JsonEncoder.withIndent('  ').convert(value)}\n';
  if (path == null || path == '-') { stdout.write(text); return; }
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(text, flush: true);
}
