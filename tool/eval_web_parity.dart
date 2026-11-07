import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import '../test/contracts/codex_context_test.dart' as contract;
import '../test/fixtures/context_contract/environment.dart';

// An opt-in live evaluation, separate from deterministic CI. Both harnesses
// receive the same freshly discovered catalog and real backend responses. No
// model output, search command, answer, or number of research steps is supplied.
Future<void> main(List<String> arguments) async {
  if (arguments.length > 1) throw ArgumentError('Usage: dart run tool/eval_web_parity.dart [auth-directory]');
  final authDirectory = arguments.firstOrNull ?? defaultDataDirectory();
  final reportRoot = Platform.environment['HAPPEN_TEST_REPORT_ROOT'] ?? Directory.current.path;
  final output = '$reportRoot/.local/web-parity-eval/${DateTime.now().microsecondsSinceEpoch}';
  final temporary = await Directory.systemTemp.createTemp('happen-live-web-');
  final cwd = '${temporary.path}/work', home = '${temporary.path}/home', codexHome = '${temporary.path}/codex';
  for (final path in [output, cwd, home, codexHome]) { await Directory(path).create(recursive: true); }
  const model = 'gpt-6-luna', effort = 'max', prompt = 'google youtube to rss podcast tools';
  final lifetime = TimeoutCancellationToken(const Duration(minutes: 5));
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((signal) => signal.watch().listen((_) => lifetime.cancel())).toList();
  final http = HttpClient(), auth = AuthManager(authDirectory);
  HttpServer? proxy;
  AgentServer? host;
  AgentClient? client;
  StreamSubscription<Json>? subscription;
  final pending = <Future<void>>[], requests = <String, List<Json>>{}, searches = <String, List<Json>>{};
  final searchOutputs = <String, List<String>>{}, messages = <Json>[], errors = <String>[];
  try {
    final credentials = await auth.credentials().asCancellable(lifetime);
    final remote = ResponsesClient(http: http, credentials: ({bool refresh = false}) => auth.credentials(refresh: refresh));
    final catalog = await remote.models(credentials, cancellation: lifetime);
    final catalogPath = '$output/models.json';
    await contract.save(catalogPath, catalog.body);
    proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Future<void> forward(HttpRequest incoming) async {
      var background = false;
      try {
        if (WebSocketTransformer.isUpgradeRequest(incoming)) { incoming.response.statusCode = 426; return; }
        final engine = incoming.uri.pathSegments.first;
        if (!{'codex', 'happen'}.contains(engine)) throw const FormatException('Unknown evaluation client');
        if (incoming.method == 'GET' && incoming.uri.path.endsWith('/models')) {
          incoming.response.headers.contentType = ContentType.json;
          incoming.response.headers.set('etag', catalog.etag ?? 'evaluation-catalog');
          incoming.response.write(jsonEncode(catalog.body));
          return;
        }
        final search = incoming.uri.path.endsWith('/alpha/search');
        if (incoming.method != 'POST' || !search && !incoming.uri.path.endsWith('/responses')) throw const FormatException('Unexpected evaluation endpoint');
        final bytes = await incoming.fold<BytesBuilder>(BytesBuilder(copy: false), (buffer, chunk) {
          if (buffer.length + chunk.length > 2 * 1024 * 1024) throw const FormatException('Evaluation input exceeds 2 MiB');
          return buffer..add(chunk);
        }).asCancellable(lifetime);
        final body = bytes.takeBytes();
        final decoded = jsonObject(jsonDecode(utf8.decode(body)));
        background = !search && decoded['tool_choice'] == 'none';
        final owner = background ? '$engine-background' : engine;
        final captured = (search ? searches : requests).putIfAbsent(owner, () => [])..add(decoded);
        final path = '$output/$owner/${search ? 'search' : 'responses'}-${captured.length}';
        await File('$path.request.json').parent.create(recursive: true);
        await File('$path.request.json').writeAsBytes(body);
        final current = await auth.credentials().asCancellable(lifetime);
        final headers = <String, String>{
          'authorization': 'Bearer ${current['access_token']}',
          if (current['account_id'] case final String account) 'chatgpt-account-id': account,
          'originator': 'agent', 'content-type': 'application/json',
          for (final key in ['accept', 'session-id', 'x-client-request-id', 'openai-beta', 'x-openai-internal-codex-responses-lite'])
            if (incoming.headers.value(key) case final String value) key: value,
        };
        final reply = await httpRequest(http, 'POST', search ? remote.endpoint.resolve('alpha/search') : remote.endpoint,
          headers: headers, body: body, cancellation: lifetime);
        incoming.response.statusCode = reply.statusCode;
        if (reply.headers['content-type'] case final String type) incoming.response.headers.set('content-type', type);
        final response = BytesBuilder(copy: false);
        var connected = true;
        await for (final chunk in reply) {
          if (response.length + chunk.length > 16 * 1024 * 1024) throw const FormatException('Evaluation response exceeds 16 MiB');
          response.add(chunk);
          if (connected) {
            try { incoming.response.add(chunk); await incoming.response.flush(); }
            on SocketException { connected = false; }
            on HttpException { connected = false; }
          }
        }
        final received = response.takeBytes();
        await File('$path.response.${search ? 'json' : 'sse'}').writeAsBytes(received);
        if (search) searchOutputs.putIfAbsent(engine, () => []).add(utf8.decode(received, allowMalformed: true));
      } catch (error) {
        if (!background && !lifetime.isCancelled) errors.add(error.runtimeType.toString());
        try { incoming.response.statusCode = 502; } on StateError { /* The client may already have its response headers. */ }
      } finally {
        try { await incoming.response.close(); }
        on SocketException { /* A client can close after its terminal SSE item. */ }
        on HttpException { /* The request owner may already have closed. */ }
      }
    }
    proxy.listen((incoming) {
      final operation = forward(incoming);
      pending.add(operation);
      unawaited(operation.then<void>((_) { pending.remove(operation); },
        onError: (Object error, StackTrace _) { pending.remove(operation); errors.add(error.runtimeType.toString()); }));
    });
    final endpoint = 'http://127.0.0.1:${proxy.port}';
    final env = isolatedEnvironment(home, codexHome);
    await contract.run(['git', 'init', '--quiet', cwd], env, '$output/git.log', lifetime);
    await File('$codexHome/config.toml').writeAsString('''
model_catalog_json = ${jsonEncode(catalogPath)}
openai_base_url = "$endpoint/codex/backend-api/codex"
model = "$model"
model_reasoning_effort = "$effort"
web_search = "live"
approval_policy = "never"
sandbox_mode = "danger-full-access"
include_permissions_instructions = false
include_apps_instructions = false
include_collaboration_mode_instructions = false
[agents]
enabled = false
[skills.bundled]
enabled = false
[features]
code_mode_tool_search = true
deferred_tool_world_state = true
multi_agent = false
plugins = false
apps = false
''');
    final data = '${temporary.path}/happen';
    await Directory(data).create();
    await contract.save('$data/config.yaml', {});
    await contract.save('$data/auth.json', {'type': 'chatgpt', 'access_token': 'local-evaluation',
      'account_id': 'local-evaluation', 'refresh_token': 'unused',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch});
    host = await AgentServer.startLocal(directory: data, configPath: '$data/config.yaml', skillsHome: home,
      endpoint: '$endpoint/happen/backend-api/codex/responses', telemetry: false);
    client = AgentClient.local(host);
    subscription = client.events.stream.listen(messages.add);
    await contract.run(['codex', '-C', cwd, 'exec', '--skip-git-repo-check', '--json', prompt],
      {...env, 'OPENAI_API_KEY': 'local-evaluation'}, '$output/codex.jsonl', lifetime, timeout: const Duration(minutes: 3));
    final started = jsonObject(await client.request('thread/start', {'cwd': cwd, 'model': model, 'reasoning': effort,
      'settings': {'image_generation': false}}).asCancellable(lifetime));
    final id = started['thread']['id'];
    final completion = client.events.stream.firstWhere((event) => event['method'] == 'turn/completed' && event['params']['threadId'] == id);
    await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': prompt}]}).asCancellable(lifetime);
    final turn = (await completion.asCancellable(lifetime))['params']['turn'];
    final codexEvents = (await File('$output/codex.jsonl').readAsLines()).map((line) => jsonObject(jsonDecode(line))).toList();
    final answers = {
      'codex': codexEvents.where((event) => event['type'] == 'item.completed' && event['item']?['type'] == 'agent_message')
        .map((event) => event['item']['text'] as String).lastOrNull ?? '',
      'happen': messages.where((event) => event['method'] == 'item/completed' && event['params']?['item']?['type'] == 'agentMessage')
        .map((event) => event['params']['item']['text'] as String).lastOrNull ?? '',
    };
    Set<String> domains(String value) => RegExp(r'''https?://[^\s\]\[()<>"']+''').allMatches(value)
      .map((match) => Uri.tryParse(match[0]!)?.host).whereType<String>().toSet();
    final checks = <String, bool>{'happen_completed': turn['status'] == 'completed', 'proxy_succeeded': errors.isEmpty};
    checks['same_initial_model_request'] = requests['codex']?.isNotEmpty == true && requests['happen']?.isNotEmpty == true &&
      await contract.compare(requests['codex']!.first, requests['happen']!.first, '$output/comparison');
    for (final engine in ['codex', 'happen']) {
      checks['$engine:searched_without_scripted_calls'] = searches[engine]?.isNotEmpty == true;
      final sources = domains((searchOutputs[engine] ?? []).join('\n'));
      checks['$engine:cited_received_source'] = domains(answers[engine]!).intersection(sources).isNotEmpty;
    }
    checks['happen_native_search_completion'] = messages.where((event) => event['method'] == 'item/completed' &&
      event['params']?['item']?['type'] == 'webSearch').length == (searches['happen'] ?? []).length;
    await contract.save('$output/report.json', {'model': model, 'effort': effort, 'prompt': prompt,
      'passed': checks.values.every((value) => value), 'checks': checks, 'answers': answers,
      'search_commands': {for (final engine in ['codex', 'happen']) engine: (searches[engine] ?? []).map((request) => request['commands']).toList()},
      'proxy_errors': errors});
    if (checks.values.any((value) => !value)) exitCode = 1;
  } catch (error) {
    await contract.save('$output/report.json', {'passed': false, 'error_type': error.runtimeType.toString()});
    rethrow;
  } finally {
    lifetime.cancel();
    await subscription?.cancel(); await client?.close(); await host?.close();
    await proxy?.close(force: true); http.close(force: true); auth.close();
    await Future.wait(pending);
    for (final signal in signals) { await signal.cancel(); }
    await temporary.delete(recursive: true);
    print('Live web parity evidence: $output/report.json');
  }
}
