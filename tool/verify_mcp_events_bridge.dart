import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';

/// Runs the upstream bridge's real HTTP server and GitHub source against a
/// disposable local Event Gateway API. No GitHub or Hookdeck account is used.
/// Usage: dart tool/verify_mcp_events_bridge.dart <bridge-checkout> [report.json]
/// Install its dependencies first with: aube install --ignore-scripts
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) throw ArgumentError('Provide the bridge checkout and optional report path');
  final source = Directory(arguments.first).absolute;
  final root = await Directory.systemTemp.createTemp('happen-events-bridge-');
  final token = TimeoutCancellationToken(const Duration(minutes: 2));
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm].map((s) => s.watch().listen((_) => token.cancel())).toList();
  final http = HttpClient(), notifications = <Json>[], stored = <Json>[], checks = <String, bool>{};
  final gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final pending = <Future<void>>{};
  const secret = 'happen-synthetic-github-signing-key';
  const principal = 'happen-synthetic-mcp-principal';
  const eventName = 'github.workflow_run';
  const filters = {'repository': 'happen-fixture/demo', 'actions': ['completed'], 'sender': 'github-actions[bot]'};
  final report = <String, dynamic>{
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'fixture': 'synthetic signed GitHub Actions workflow_run webhooks',
    'gateway': 'local fixture API; bridge and Happen use real HTTP',
    'launcher': 'aube exec tsx',
    'checks': checks,
  };
  McpManager? manager;
  Process? bridge;
  StreamSubscription<String>? output, diagnostics;
  CancellationHook? processHook;

  Future<void> serve(HttpRequest request) async {
    try {
      Object result;
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/github') {
        final bytes = await request.fold(<int>[], (all, chunk) => all..addAll(chunk)).asCancellable(token);
        final expected = 'sha256=${Hmac(sha256, utf8.encode(secret)).convert(bytes)}';
        if (request.headers.value('x-hub-signature-256') != expected) {
          request.response.statusCode = 401;
          result = {'error': 'Invalid fixture signature'};
        } else {
          stored.add({
            'id': 'req-${stored.length + 1}', 'source_id': 'src_github',
            'created_at': DateTime.now().toUtc().toIso8601String(), 'verified': true,
            'rejection_cause': 'NO_CONNECTION', 'events_count': 0, 'ignored_count': 0,
            'data': {'headers': {
              'x-github-event': request.headers.value('x-github-event'),
              'x-github-delivery': request.headers.value('x-github-delivery'),
            }, 'body': jsonDecode(utf8.decode(bytes))},
          });
          request.response.statusCode = 202;
          result = {'accepted': true};
        }
      } else if (path == '/sources') {
        result = {'models': [{'id': 'src_github', 'name': 'bridge-github', 'type': 'GITHUB', 'url': 'http://127.0.0.1:${gateway.port}/github'}]};
      } else if (path == '/requests') {
        final from = request.uri.queryParameters['created_at[gte]'];
        final models = stored.where((r) => from == null || (r['created_at'] as String).compareTo(from) >= 0).toList();
        models.sort((a, b) => request.uri.queryParameters['dir'] == 'asc'
            ? (a['created_at'] as String).compareTo(b['created_at'] as String)
            : (b['created_at'] as String).compareTo(a['created_at'] as String));
        result = {'models': models, 'pagination': <String, Object?>{}};
      } else if (path == '/connections' || RegExp(r'^/requests/[^/]+/ignored_events$').hasMatch(path)) {
        result = {'models': <Object?>[], 'pagination': <String, Object?>{}};
      } else {
        request.response.statusCode = 404;
        result = {'error': 'Unexpected fixture route $path'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    } catch (_) {
      request.response.statusCode = 500;
      await request.response.close();
    }
  }
  final serving = gateway.listen((request) {
    final operation = serve(request); pending.add(operation);
    unawaited(operation.whenComplete(() => pending.remove(operation)));
  });

  Future<int> send(String id, {String repository = 'happen-fixture/demo', String action = 'completed',
    String sender = 'github-actions[bot]', bool signed = true}) async {
    final bytes = utf8.encode(jsonEncode({
      'action': action, 'repository': {'full_name': repository}, 'sender': {'login': sender},
      'workflow_run': {'id': 42, 'name': 'CI', 'status': 'completed', 'conclusion': 'failure',
        'head_branch': 'main', 'html_url': 'https://github.com/$repository/actions/runs/42',
        'completed_at': DateTime.now().toUtc().toIso8601String()},
    }));
    final request = await http.postUrl(Uri.parse('http://127.0.0.1:${gateway.port}/github')).asCancellable(token);
    final hook = CancellationHook(token, () => request.abort(token.exception));
    try {
      request.headers.contentType = ContentType.json;
      request.headers.set('x-github-event', 'workflow_run'); request.headers.set('x-github-delivery', id);
      request.headers.set('x-hub-signature-256', signed ? 'sha256=${Hmac(sha256, utf8.encode(secret)).convert(bytes)}' : 'sha256=invalid');
      request.add(bytes);
      final response = await request.close().asCancellable(token);
      await response.drain<void>().asCancellable(token);
      return response.statusCode;
    } finally { hook.dispose(); }
  }

  void check(String name, bool passed) {
    checks[name] = passed;
    if (!passed) throw StateError('Bridge verification failed: $name');
  }

  try {
    final revision = await Process.run('git', ['rev-parse', 'HEAD'], workingDirectory: source.path).asCancellable(token);
    report['bridge_commit'] = (revision.stdout as String).trim();
    final package = jsonObject(jsonDecode(await File('${source.path}/package.json').readAsString()));
    report['bridge_version'] = package['version'];
    String module(String path) => jsonEncode(source.uri.resolve('src/$path.ts').toString());
    final launcher = await File('${root.path}/bridge-launcher.mts').writeAsString('''
import { defineConfig, resolveConfig } from ${module('core/config')};
import { HookdeckClient } from ${module('core/hookdeck')};
import { MemoryStore } from ${module('core/memory-store')};
import { github } from ${module('sources')};
import { createBridgeServer } from ${module('host/server')};
const bridge = await createBridgeServer(resolveConfig(defineConfig({
  port: 0, inbound: 'cli', sources: [github({webhookSecret: ${jsonEncode(secret)}, events: ['workflow_run']})],
}), {HOOKDECK_API_KEY: 'fixture', HOOKDECK_SIGNING_SECRET: 'fixture', BRIDGE_MCP_SECRET: ${jsonEncode(principal)}}), {
  hookdeck: new HookdeckClient({apiKey: 'fixture', apiBase: 'http://127.0.0.1:${gateway.port}'}),
  store: new MemoryStore(), localAgents: false, version: ${jsonEncode(package['version'])}, log: console.error,
});
console.log(JSON.stringify(await bridge.listen()));
process.on('SIGTERM', async () => { await bridge.close(); process.exit(0); });
''');
    bridge = await Process.start('aube', ['exec', 'tsx', launcher.path], workingDirectory: source.path);
    processHook = CancellationHook(token, () => bridge?.kill(ProcessSignal.sigterm));
    final listening = Completer<int>(), errors = <String>[];
    output = utf8.decoder.bind(bridge.stdout).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('{')) {
        final value = jsonObject(jsonDecode(line));
        if (value['port'] is int && !listening.isCompleted) listening.complete(value['port'] as int);
      }
    }, onDone: () {
      if (!listening.isCompleted) listening.completeError(StateError('Bridge did not start: ${errors.join('\n')}'));
    });
    diagnostics = utf8.decoder.bind(bridge.stderr).transform(const LineSplitter()).listen((line) {
      errors.add(line); if (errors.length > 20) errors.removeAt(0);
    });
    final port = await listening.future.asCancellable(token);
    final desired = File('${root.path}/subscriptions.json');
    await desired.writeAsString('{}');
    manager = McpManager(http: http, onEvent: (_, event) => notifications.add(event),
      persistSubscription: (operation, params, cancellation) async {
        cancellation.throwIfCancelled();
        final saved = jsonObject(jsonDecode(await desired.readAsString()));
        if (operation == 'remove') {
          saved.remove(params['subscription_id']);
        } else {
          final snapshot = jsonObject(params['snapshot']); saved[snapshot['subscription_id'] as String] = snapshot;
        }
        final pending = await File('${desired.path}.pending').writeAsString(jsonEncode(saved), flush: true);
        await pending.rename(desired.path);
      });
    await manager.configure({'bridge': {'url': 'http://127.0.0.1:$port/mcp', 'legacy_fallback': false,
      'headers': {'Authorization': 'Bearer $principal'}}}, token);
    check('modern_discovery', manager.status().single['protocol_version'] == mcpProtocolVersion && manager.status().single['state'] == 'ready');
    final catalog = await manager.catalog(token);
    final toolNames = (catalog['tools'] as List).map((dynamic tool) => tool['name']).toSet();
    check('poll_tools_discovered', toolNames.containsAll(['mcp__bridge__poll_events', 'mcp__bridge__wait_for_event']));
    final definitions = await manager.request('bridge', 'events/list', {}, token);
    final definition = jsonObject((definitions['events'] as List).single);
    check('github_workflow_event_discovered', definition['name'] == eventName && (definition['delivery'] as List).contains('poll'));
    final bootstrap = await manager.request('bridge', 'events/poll', {'name': eventName, 'arguments': filters}, token);
    check('initial_poll_starts_now', (bootstrap['events'] as List).isEmpty && bootstrap['cursor'] is String);
    final subscription = await manager.subscribe('probe', {'server': 'bridge', 'name': eventName, 'arguments': filters, 'cursor': bootstrap['cursor']}, token);
    check('automatic_poll_selection', subscription['mode'] == 'poll');
    await cancellableDelay(const Duration(milliseconds: 10), token);
    check('invalid_source_signature_rejected', await send('invalid-signature', signed: false) == 401);
    await send('other-repository', repository: 'other/repository');
    await send('other-action', action: 'requested');
    await send('other-sender', sender: 'someone-else');
    check('signed_actions_fixture_accepted', await send('actions-failed-42') == 202);
    final eventArrived = TimeoutCancellationToken(const Duration(seconds: 15));
    try {
      while (!notifications.any((e) => e['notification']?['params']?['eventId'] == 'actions-failed-42')) {
        await cancellableDelay(const Duration(milliseconds: 50), token.merge(eventArrived));
      }
    } finally { eventArrived.cancel(); }
    final occurrence = jsonObject(notifications.singleWhere((e) => e['notification']?['params']?['eventId'] == 'actions-failed-42')['notification']['params']);
    check('actions_failure_delivered', occurrence['name'] == eventName && occurrence['data']['conclusion'] == 'failure'
        && occurrence['data']['workflow'] == 'CI' && occurrence['data']['branch'] == 'main');
    check('github_filters_applied', notifications.where((e) => e['notification']?['method'] == 'notifications/events/event').length == 1);
    final replay = await manager.request('bridge', 'events/poll', {'name': eventName, 'arguments': filters, 'cursor': bootstrap['cursor']}, token);
    check('protocol_cursor_replay', (replay['events'] as List).single['eventId'] == 'actions-failed-42');
    final polled = await manager.callTool('mcp__bridge__poll_events', {'name': eventName, 'arguments': filters, 'cursor': bootstrap['cursor']}, token);
    check('poll_events_tool', polled['isError'] != true && (polled['structuredContent']['events'] as List).single['eventId'] == 'actions-failed-42');
    final waiting = manager.callTool('mcp__bridge__wait_for_event', {'name': eventName, 'arguments': filters, 'cursor': replay['cursor'], 'timeoutMs': 10000}, token);
    await cancellableDelay(const Duration(milliseconds: 100), token);
    await send('actions-failed-43');
    final waited = await waiting;
    check('wait_for_event_tool', waited['isError'] != true && (waited['structuredContent']['events'] as List).single['eventId'] == 'actions-failed-43');
    final empty = await manager.callTool('mcp__bridge__poll_events', {'name': eventName, 'arguments': filters,
      'cursor': waited['structuredContent']['cursor']}, token);
    check('cursor_prevents_duplicate_replay', (empty['structuredContent']['events'] as List).isEmpty);
    await manager.unsubscribe('probe', subscription['subscription_id'] as String);
    check('subscription_cancelled', manager.subscriptions('probe').isEmpty);
    // A rejected request does not say that a provider ended an accepted
    // subscription. The host retains its desired state for explicit repair.
    var rejected = false;
    try {
      await manager.subscribe('thread:fixture', {'server': 'bridge', 'name': eventName,
        'threadId': 'fixture', 'arguments': {'repository': 'happen-fixture/demo', 'actions': <String>[]}}, token);
    } on McpFailure catch (error) { rejected = error.code == -32602; }
    final saved = jsonObject(jsonDecode(await desired.readAsString()));
    check('invalid_params_preserves_desired_subscription', rejected && saved.length == 1);
    report['event'] = occurrence;
  } catch (_) { report['failed'] = true; rethrow; }
  finally {
    token.cancel(); processHook?.dispose();
    await manager?.close(); http.close(force: true);
    bridge?.kill(ProcessSignal.sigterm);
    if (bridge != null) {
      try { await bridge.exitCode.timeout(const Duration(seconds: 5)); }
      on TimeoutException { bridge.kill(ProcessSignal.sigkill); await bridge.exitCode; }
    }
    await output?.cancel(); await diagnostics?.cancel();
    await serving.cancel(); await gateway.close(force: true); await Future.wait(pending);
    for (final signal in signals) { await signal.cancel(); }
    await root.delete(recursive: true);
    final json = const JsonEncoder.withIndent('  ').convert(report);
    if (arguments.length == 2) await File(arguments[1]).writeAsString('$json\n');
    stdout.writeln(json);
  }
}
