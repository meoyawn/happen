import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:config/config.dart';
import 'package:opencode/opencode.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:telemetry/telemetry.dart';

ArgParser parser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('version', negatable: false)
    ..addOption('data-dir', defaultsTo: defaultDataDirectory())
    ..addOption(
      'config',
      help: 'Global YAML config (default: ~/.config/happen/config.yaml)',
    );
  parser.addCommand('config-schema', ArgParser());
  parser.addCommand(
    'login',
    ArgParser()
      ..addOption('provider', allowed: ['openai', 'gpt', 'opencode'], defaultsTo: 'openai')
      ..addFlag('device', negatable: false)
      ..addFlag('from-codex', negatable: false)
      ..addOption('codex-auth'),
  );
  parser.addCommand(
    'exec',
    ArgParser()
      ..addOption('cwd', defaultsTo: Directory.current.path)
      ..addOption('provider', allowed: ['openai', 'gpt', 'deepseek', 'opencode'])
      ..addOption('model')
      ..addOption('reasoning')
      ..addOption('endpoint', help: 'Local Responses API URL (including /responses); no ChatGPT login needed')
      ..addOption('api-key-env', defaultsTo: 'OPENAI_API_KEY')
      ..addOption('resume')
      ..addFlag('json', negatable: false)
      ..addFlag('telemetry',
        help: 'Record local telemetry and export a JSON trace after the turn; print its absolute path (off by default)'),
  );
  parser.addCommand(
    'request',
    ArgParser(),
  );
  final mcp = parser.addCommand('mcp', ArgParser());
  mcp.addCommand('list', ArgParser()..addFlag('verbose', negatable: false)..addFlag('json', negatable: false));
  mcp.addCommand('login', ArgParser()..addFlag('no-browser', negatable: false,
    help: 'Print the sign-in link and accept the final callback URL without opening a browser'));
  mcp.addCommand('logout', ArgParser());
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
  if (parsed['version'] == true) {
    stdout.writeln('happen 0.1.0');
    return;
  }
  if (parsed['help'] == true && command?.name == 'exec') {
    stdout.writeln('Usage: happen exec [options] "task"\n\n${options.commands['exec']!.usage}');
    return;
  }
  if (parsed['help'] == true || command == null) {
    stdout.writeln(
      'Happen\n\n  happen login [--device | --from-codex | --provider opencode]\n  happen exec "task"\n  happen mcp list [--verbose | --json]\n  happen mcp login SERVER [--no-browser]\n  happen mcp logout SERVER\n  happen request METHOD \'{"parameter":"value"}\'\n  happen config-schema\n\n${options.usage}',
    );
    return;
  }
  final directory = Directory(parsed['data-dir'] as String).absolute.path;
  switch (command.name) {
    case 'mcp':
      await _mcp(command, directory, parsed['config'] as String?);
      return;
    case 'config-schema':
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(globalConfigSchema),
      );
    case 'login':
      if (command['provider'] == 'opencode') {
        if (command['from-codex'] == true || command.wasParsed('codex-auth')) {
          throw ArgumentError(
            'Codex credentials are only for the GPT provider',
          );
        }
        final auth = OpenCodeAuthManager(directory);
        final cancellation = CancellationToken();
        final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
            .map(
              (signal) => signal.watch().listen((_) => cancellation.cancel()),
            )
            .toList();
        try {
          await auth.login(
            cancellation: cancellation,
            notify: (url, code) => stdout.writeln(
              'Open this URL and authorize device $code:\n$url',
            ),
          );
          stdout.writeln('OpenCode Console login ready.');
        } finally {
          cancellation.cancel();
          for (final signal in signals) {
            await signal.cancel();
          }
          auth.close();
        }
        return;
      }
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
    case 'exec':
      final prompt = command.rest.isEmpty
          ? (stdin.hasTerminal ? '' : await utf8.decoder.bind(stdin).join())
          : command.rest.join(' ');
      if (prompt.trim().isEmpty) {
        throw ArgumentError('Provide a prompt or pipe it on stdin');
      }
      AgentServer? embedded;
      AgentClient? client;
      StreamSubscription<Json>? events;
      TraceStore? traces;
      String? taskId = command['resume'] as String?;
      String? activeTurnId;
      final outputItems = <String, Json>{};
      final terminal = Completer<Json>();
      final cancellation = CancellationToken();
      CancellationToken? exportCancellation;
      final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
        .map((signal) => signal.watch().listen((_) {
          if (cancellation.isCancelled) { exportCancellation?.cancel(); }
          else { cancellation.cancel(); }
        })).toList();
      try {
        final endpoint = _localResponsesEndpoint(command);
        if (endpoint != null && command.wasParsed('provider') && !{'openai', 'gpt'}.contains(command['provider'])) {
          throw ArgumentError('--endpoint is only available for the OpenAI provider');
        }
        embedded = await AgentServer.startLocal(
          directory: directory,
          configPath: parsed['config'] as String? ?? defaultConfigPath(),
          telemetry: command['telemetry'] as bool,
          endpoint: endpoint,
          apiKeyEnv: endpoint == null ? null : command['api-key-env'] as String,
        );
        cancellation.throwIfCancelled();
        client = AgentClient.local(embedded);
        final trace = command['telemetry'] == true
          ? TraceContext(sink: (traces = await embedded.traces).sink, service: 'cli', session: taskId)
          : null;
        events = client.events.stream.listen(
          (event) {
            if (taskId != null && event['params']?['threadId'] != taskId) return;
            if (command['json'] == true) stdout.writeln(jsonEncode(event));
            if (event['method'] == 'item/completed') {
              final item = jsonObject(event['params']['item']); outputItems[item['id'] as String] = item;
            }
            if (event['method'] == 'turn/completed' &&
                !terminal.isCompleted) {
              terminal.complete(event);
            }
          },
          onDone: () {
            if (!terminal.isCompleted) {
              terminal.completeError(
                StateError('Disconnected before turn completion'),
              );
            }
          },
        );
        if (taskId == null) {
          final result = jsonObject(await withTrace(trace, () => client!.request('thread/start', {
            if (taskId == null || command.wasParsed('cwd'))
              'cwd': command['cwd'],
            if (endpoint != null) 'provider': 'openai'
            else if (command.wasParsed('provider')) 'provider': command['provider'],
            if (command.wasParsed('model')) 'model': command['model'],
            if (command.wasParsed('reasoning'))
              'reasoning': command['reasoning'],
            'telemetry': command['telemetry'],
            'tracing': command['telemetry'],
          })).asCancellable(cancellation));
          taskId = result['thread']['id'] as String;
        } else {
          await client.request('thread/resume', {'threadId': taskId, 'excludeTurns': true}).asCancellable(cancellation);
        }
        final started = jsonObject(await withTrace(trace, () => client!.request('turn/start', {
          'threadId': taskId, 'input': [{'type': 'text', 'text': prompt}],
          if (command.wasParsed('reasoning')) 'effort': command['reasoning'],
        })).asCancellable(cancellation));
        activeTurnId = started['turn']['id'] as String;
        withTrace(trace, () => bindTraceSession(taskId!));
        final completed = await terminal.future.asCancellable(cancellation);
        if (command['json'] == false) {
          if (completed['params']['turn']['status'] == 'completed') {
            stdout.writeln(outputItems.values.where((item) => item['type'] == 'agentMessage').lastOrNull?['text'] ?? '');
          } else {
            stderr.writeln(completed['params']['turn']['error'] ?? 'Turn failed');
          }
        }
        if (completed['params']['turn']['status'] != 'completed') exitCode = 1;
      } on CancelledException {
        exitCode = 130;
      } finally {
        cancellation.cancel();
        try {
          if (traces != null && taskId != null) {
            final exporting = exportCancellation = TimeoutCancellationToken(const Duration(seconds: 30));
            if (!terminal.isCompleted) {
              await client!.request('turn/interrupt', {'threadId': taskId, 'turnId': activeTurnId}).asCancellable(exporting);
              await terminal.future.asCancellable(exporting);
            }
            final file = await _saveTelemetry(traces, directory, taskId, cancellation: exporting);
            if (command['json'] == true) {
              stdout.writeln(jsonEncode({
                'type': 'telemetry.exported', 'task_id': taskId, 'data': {'path': file.path},
              }));
            } else {
              stdout.writeln('Telemetry: ${file.path}');
            }
          }
        } finally {
          exportCancellation?.cancel();
          await events?.cancel();
          await client?.close();
          await embedded?.close();
          for (final signal in signals) { await signal.cancel(); }
        }
      }
    case 'request':
      if (command.rest.isEmpty) {
        throw ArgumentError(
          'Provide a protocol method and optional JSON parameters',
        );
      }
      final server = await AgentServer.startLocal(directory: directory,
        configPath: parsed['config'] as String? ?? defaultConfigPath());
      final client = AgentClient.local(server);
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
        await server.close();
      }
    default:
      throw ArgumentError('Unknown command');
  }
}

Future<File> _saveTelemetry(TraceStore traces, String directory, String sessionID, {
  required CancellationToken cancellation,
}) async {
  cancellation.throwIfCancelled();
  final file = File('$directory/telemetry/$sessionID-${newId()}.json').absolute;
  await file.parent.create(recursive: true);
  final partial = File('${file.path}.part');
  final output = partial.openWrite();
  var closed = false;
  try {
    output.write('{"displayTimeUnit":"ms","metadata":${jsonEncode({
      'source': 'Happen', 'sessionID': sessionID,
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'capture': 'snapshot',
    })},"traceEvents":[');
    output.write(traceProcessMetadata().map(jsonEncode).join(','));
    var after = 0;
    int? through;
    while (true) {
      final page = await traces.page(sessionID, after: after, through: through, cancellation: cancellation);
      through ??= page['through'] as int;
      after = page['after'] as int;
      final events = traceExportEvents((page['events'] as List).map(jsonObject));
      for (final event in events) { output.write(',${jsonEncode(event)}'); }
      await output.flush();
      if (page['done'] == true) break;
    }
    output.write(']}\n');
    await output.flush();
    await output.close();
    closed = true;
    cancellation.throwIfCancelled();
    return await partial.rename(file.path);
  } finally {
    if (!closed) await output.close();
    if (await partial.exists()) await partial.delete();
  }
}

String? _localResponsesEndpoint(ArgResults command) {
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

Future<void> _mcp(ArgResults command, String directory, String? configPath) async {
  final operation = command.command;
  if (operation == null) {
    stdout.writeln('Usage: happen mcp list [--verbose | --json]\n       happen mcp login SERVER [--no-browser]\n       happen mcp logout SERVER');
    return;
  }
  if (operation.name == 'list' ? operation.rest.isNotEmpty : operation.rest.length != 1) {
    throw ArgumentError(operation.name == 'list' ? 'mcp list takes no server name' : 'Provide exactly one configured MCP server name');
  }
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  AgentServer? embedded;
  AgentClient? client;
  StreamSubscription<Json>? events;
  Future<void>? browser;
  Object? browserError;
  try {
    embedded = await AgentServer.startLocal(directory: directory, configPath: configPath);
    cancellation.throwIfCancelled();
    final connected = client = AgentClient.local(embedded);
    if (operation.name == 'list') {
      final inventory = await connected.mcpInventory(verbose: operation['verbose'] as bool, cancellation: cancellation);
      if (operation['json'] == true || operation['verbose'] == true) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(inventory));
      } else {
        for (final row in (inventory['servers'] as List).map(jsonObject)) {
          stdout.writeln('${row['name']}\t${row['state']}\t${row['auth_status']}\t${row['tool_count']} tools');
        }
        if ((inventory['servers'] as List).isEmpty) stdout.writeln('No MCP servers configured.');
      }
      return;
    }
    final server = operation.rest.single;
    if (operation.name == 'logout') {
      await connected.mcpLogout(server, cancellation: cancellation);
      stdout.writeln('Signed out of $server.');
      return;
    }
    final inventory = await connected.mcpInventory(server: server, cancellation: cancellation);
    final rows = (inventory['servers'] as List).map(jsonObject).toList();
    if (rows.isEmpty) throw StateError('Unknown configured MCP server: $server');
    if (rows.single['oauth_supported'] != true) {
      throw StateError('Browser sign-in is unavailable for $server. Local servers use their configured environment; HTTP Authorization headers take precedence over OAuth.');
    }
    final loginId = newId();
    events = connected.events.stream.listen((event) {
      if (event['type'] != 'mcp.auth.login' || event['server'] != server || event['login_id'] != loginId || browser != null) return;
      browser = () async {
        try {
          final authorizationUrl = requiredString(event, 'url');
          stdout.writeln('Authorize $server:\n$authorizationUrl');
          if (operation['no-browser'] == true) {
            final callback = await _readMcpCallback(cancellation);
            cancellation.throwIfCancelled();
            await connected.request('mcp.auth.callback', {
              'server': server, 'login_id': loginId, 'callback_url': callback,
            }).asCancellable(cancellation);
          } else {
            await _openMcpBrowser(authorizationUrl, cancellation);
          }
        } on CancelledException { /* The command owns this operation. */
        } catch (_) {
          browserError = StateError(operation['no-browser'] == true
            ? 'MCP callback input failed; retry sign-in.'
            : 'Could not open the browser. Retry with --no-browser.');
          cancellation.cancel();
        }
      }();
    });
    final result = await connected.mcpLogin(server, loginId, cancellation: cancellation);
    if (result['state'] != 'ready') throw StateError('Sign-in completed, but $server is unavailable. Check mcp list.');
    stdout.writeln('Connected to $server (${result['tool_count']} tools).');
  } on CancelledException {
    if (browserError != null) throw browserError!;
    stdout.writeln('MCP authentication cancelled.');
    exitCode = 130;
  } finally {
    cancellation.cancel();
    await browser;
    await events?.cancel();
    await client?.close();
    await embedded?.close();
    for (final signal in signals) { await signal.cancel(); }
  }
}

Future<String> _readMcpCallback(CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  stdout.write('Paste the complete callback URL from your browser (input hidden): ');
  final echo = stdin.hasTerminal ? stdin.echoMode : null;
  final lines = StreamIterator(boundedLines(stdin, maxBytes: 16384));
  try {
    if (echo != null) stdin.echoMode = false;
    if (!await lines.moveNext().asCancellable(cancellation, onCancel: () => unawaited(lines.cancel()))) {
      throw StateError('No callback URL was supplied');
    }
    return lines.current.trim();
  } finally {
    if (echo != null) stdin.echoMode = echo;
    stdout.writeln();
    await lines.cancel();
  }
}

Future<void> _openMcpBrowser(String value, CancellationToken cancellation) async {
  final url = Uri.parse(value);
  if (url.userInfo.isNotEmpty || url.host.isEmpty || url.hasFragment ||
      url.scheme != 'https' && !(url.scheme == 'http' &&
        (url.host == 'localhost' || (InternetAddress.tryParse(url.host)?.isLoopback ?? false)))) {
    throw StateError('Invalid MCP sign-in URL');
  }
  cancellation.throwIfCancelled();
  final process = await Process.start(Platform.isMacOS ? 'open' : Platform.isWindows ? 'rundll32.exe' : 'xdg-open',
    [if (Platform.isWindows) 'url.dll,FileProtocolHandler', value]);
  final hook = CancellationHook(cancellation, () => process.kill());
  try {
    await Future.wait([process.stdout.drain<void>(), process.stderr.drain<void>()]).asCancellable(cancellation);
    if (await process.exitCode.asCancellable(cancellation) != 0) throw StateError('Browser launch failed');
  } finally { hook.dispose(); }
}
