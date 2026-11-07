@Tags(['e2e'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:openai/openai.dart' show GptModel, gptCatalogRevision, supportedGptModels;
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

import '../fixtures/context_contract/cases.dart';
import '../fixtures/context_contract/environment.dart';
import '../support/thread.dart' show unloadThread;
import '../support/thread_names.dart';

final root = Directory.current.absolute;
final fixtures = Directory('${root.path}/test/fixtures/context_contract');
const encoder = JsonEncoder.withIndent('  ');

Future<void> save(String path, Object? value) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString('${encoder.convert(value)}\n');
}

Future<String> run(List<String> command, Map<String, String> environment,
  String log, CancellationToken cancellation, {String? cwd, Duration timeout = const Duration(minutes: 2)}) async {
  cancellation.throwIfCancelled();
  await File(log).parent.create(recursive: true);
  final deadline = TimeoutCancellationToken(timeout);
  final token = cancellation.merge(deadline);
  final process = await Process.start(command.first, command.skip(1).toList(),
    workingDirectory: cwd ?? root.path, environment: environment, includeParentEnvironment: false);
  await process.stdin.close();
  final out = File(log).openWrite(), err = File('$log.stderr').openWrite();
  final streams = Future.wait([out.addStream(process.stdout), err.addStream(process.stderr)]);
  final hook = CancellationHook(token, () => process.kill(ProcessSignal.sigterm));
  try {
    final code = await process.exitCode.asCancellable(token);
    await streams.asCancellable(token);
    if (code != 0) throw StateError('${command.first} exited $code; see $log and $log.stderr');
    await out.flush();
    return await File(log).readAsString();
  } finally {
    hook.dispose();
    deadline.cancel();
    process.kill(ProcessSignal.sigterm);
    try { await process.exitCode.timeout(const Duration(seconds: 5)); }
    on TimeoutException { process.kill(ProcessSignal.sigkill); await process.exitCode; }
    await streams;
    await out.close();
    await err.close();
  }
}

String text(Json item) => item['content'] is String ? item['content'] as String
  : (item['content'] as List? ?? []).whereType<Map<Object?, Object?>>().map((part) => part['text'] ?? '').join('\n');

/// Every case excludes Codex's client telemetry, removes scoped IDs and normalizes
/// known timings. All remaining fields, encodings and array positions are strict.
Json prepareComparison(Json received) {
  final request = jsonObject(jsonDecode(jsonEncode(received)));
  void removeTime(Json object, String key) {
    final value = object[key];
    if (value is! num || !value.isFinite || value < 0) return;
    object.remove(key);
  }
  request.remove('prompt_cache_key');
  request.remove('client_metadata');
  bool shellReceipt(Json printed) {
    if (printed['chunk_id'] is! String || printed['wall_time_seconds'] is! num || printed['output'] is! String) return false;
    printed.remove('chunk_id');
    if (printed['session_id'] is int) printed.remove('session_id');
    removeTime(printed, 'wall_time_seconds');
    return true;
  }
  String outputText(String text) {
    final shell = RegExp(r'^(?:Chunk ID: ([0-9a-f]{6})\n)?Wall time: ([0-9]+(?:\.[0-9]+)?) seconds\n'
      r'(Process exited with code -?[0-9]+|Process running with session ID [0-9]+)\n'
      r'(?:Original token count: [0-9]+\n)?Output:\n').firstMatch(text);
    if (shell != null) {
      var header = shell[0]!.replaceFirst('Wall time: ${shell[2]} seconds', 'Wall time: <ELAPSED> seconds');
      if (shell[1] != null) header = header.replaceFirst('Chunk ID: ${shell[1]}', 'Chunk ID: <CHUNK_ID>');
      header = header.replaceFirst(RegExp(r'Process running with session ID [0-9]+'), 'Process running with session ID <SESSION_ID>');
      return '$header${text.substring(shell.end)}';
    }
    final patch = RegExp(r'^Exit code: -?[0-9]+\nWall time: ([0-9]+(?:\.[0-9]+)?) seconds\n(?:Total output lines: [0-9]+\n)?Output:\n').firstMatch(text);
    if (patch != null) {
      return text.replaceFirst('Wall time: ${patch[1]} seconds', 'Wall time: <ELAPSED> seconds');
    }
    final mcp = RegExp(r'^Wall time: ([0-9]+(?:\.[0-9]+)?) seconds\nOutput:(?:\n|$)').firstMatch(text);
    if (mcp != null) {
      return text.replaceFirst('Wall time: ${mcp[1]} seconds', 'Wall time: <ELAPSED> seconds');
    }
    final status = RegExp(r'^Script (completed|failed|terminated|running with cell ID [1-9][0-9]*)\nWall time ([0-9]+(?:\.[0-9]+)?) seconds\nOutput:\n$').firstMatch(text);
    if (status != null) {
      return text.replaceFirst('Wall time ${status[2]} seconds', 'Wall time <ELAPSED> seconds');
    }
    final sleep = RegExp(r'^Wall time: ([0-9]+(?:\.[0-9]+)?) seconds\nSleep (completed|interrupted by new input)\.$').firstMatch(text);
    if (sleep != null) {
      return text.replaceFirst('Wall time: ${sleep[1]} seconds', 'Wall time: <ELAPSED> seconds');
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final printed = jsonObject(decoded);
        if (shellReceipt(printed)) return jsonEncode(printed);
        // Promise.allSettled receipts retain their index, settlement and value;
        // only the nested shell transport's scoped ID/time are normalized.
        if (printed['i'] is int && printed['status'] == 'fulfilled' && printed['value'] is Map) {
          final value = jsonObject(printed['value']);
          if (shellReceipt(value)) return jsonEncode({...printed, 'value': value});
        }
      }
      if (decoded is Map && decoded.containsKey('completionBudgetReport') && decoded.containsKey('remainingTokens')) {
        final printed = jsonObject(decoded);
        if (printed['goal'] is Map) {
          final goal = jsonObject(printed['goal'])..remove('threadId');
          removeTime(goal, 'createdAt');
          removeTime(goal, 'updatedAt');
          removeTime(goal, 'timeUsedSeconds');
          printed['goal'] = goal;
        }
        return jsonEncode(printed);
      }
    } on FormatException { /* Ordinary tool prose is preserved byte-for-byte. */ }
    return text;
  }
  final input = request['input'] as List;
  for (var index = 0; index < input.length; index++) {
    final item = input[index] as Json;
    item.remove('id');
    if (item['type'] == 'additional_tools') {
      for (final namespace in (item['tools'] as List).map(jsonObject).where((tool) => tool['name'] == 'functions')) {
        for (final tool in (namespace['tools'] as List).whereType<Json>().where((tool) => tool['name'] == 'exec')) {
          // The embedded engine and these two helpers are deliberate Happen
          // adaptations. Keep every shared declaration and all other prose strict.
          tool['description'] = (tool['description'] as String)
            .replaceFirst('fresh V8 isolate', 'fresh JavaScript runtime')
            .replaceFirst('fresh embedded QuickJS runtime', 'fresh JavaScript runtime')
            .replaceFirst('- `as_settled(promises: Iterable<any> | Map<any, any>)`: returns an async iterator of `{ index, status, value?, reason? }` results in settlement order. `index` is the input position or Map key.\n', '')
            .replaceFirst('- `stream_settled(promises: Iterable<any> | Map<any, any>, emit: (result: any) => any)`: processes results in settlement order, awaiting each callback before the next.\n', '')
            .replaceFirst('\n\nMCP tools return the full CallToolResult envelope. Check `isError` before using its content, even when `Promise.allSettled` reports `fulfilled`. Prefer `structuredContent` when present. Text blocks can contain ordinary text or error messages; only use `JSON.parse` when the tool documents JSON output. Print an error result to inspect it before retrying.', '');
        }
      }
    }
    if (item['internal_chat_message_metadata_passthrough'] is Map) {
      final metadata = item['internal_chat_message_metadata_passthrough'] as Json;
      metadata.remove('turn_id');
      removeTime(metadata, 'create_time');
      if (metadata.isEmpty) item.remove('internal_chat_message_metadata_passthrough');
    }
    if (!{'custom_tool_call_output', 'function_call_output'}.contains(item['type'])) continue;
    if (item['output'] case final String output) { item['output'] = outputText(output); }
    else if (item['output'] case final List<Object?> output) {
      for (var part = 0; part < output.length; part++) {
        final content = jsonObject(output[part]);
        if (content['type'] == 'input_text') content['text'] = outputText(content['text'] as String);
        output[part] = content;
      }
    }
  }
  return request;
}

/// Object-key sorting is for readable differences, never array reordering.
Object? sortedKeys(Object? value) {
  if (value is List) return value.map(sortedKeys).toList();
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: sortedKeys(value[key])};
  }
  return value;
}

bool uuid7(Object? id) => id is String && RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(id);

bool itemIdContract(List<Json> items, {Map<String, String> modelIds = const {}}) {
  const prefixes = {'message': 'msg', 'reasoning': 'rs', 'function_call': 'fc', 'custom_tool_call': 'ctc',
    'function_call_output': 'fco', 'custom_tool_call_output': 'ctco', 'tool_search_call': 'tsc',
    'tool_search_output': 'tso', 'compaction': 'cmp', 'web_search_call': 'ws', 'additional_tools': 'at'};
  final seen = <String>{};
  for (var index = 0; index < items.length; index++) {
    final item = items[index], kind = item['type'] ?? (item.containsKey('role') ? 'message' : null);
    final prefix = prefixes[kind];
    if (prefix == null) continue;
    final id = item['id'];
    if (id is! String || !seen.add(id)) return false;
    if (modelIds[id] == kind) continue; // Preserve IDs actually emitted by the synthetic upstream.
    if (!id.startsWith('${prefix}_') || !uuid7(id.substring(prefix.length + 1))) { return false; }
  }
  return true;
}

bool shellIdContract(List<Json> input) {
  for (final item in input.where((item) => {'function_call_output', 'custom_tool_call_output'}.contains(item['type']))) {
    if (item['output'] case final String output when output.startsWith('Chunk ID: ')) {
      if (!RegExp(r'^Chunk ID: [0-9a-f]{6}\n').hasMatch(output)) return false;
      final session = RegExp(r'\nProcess running with session ID ([0-9]+)\n').firstMatch(output);
      if (session != null && (int.parse(session[1]!) < 1000 || int.parse(session[1]!) >= 100000)) return false;
    }
    for (final part in item['output'] is List ? (item['output'] as List).whereType<Map<Object?, Object?>>() : const <Map<Object?, Object?>>[]) {
      try {
        var value = jsonDecode(part['text'] as String? ?? '');
        if (value is Map && value['i'] is int && value['status'] == 'fulfilled' && value['value'] is Map) value = value['value'];
        if (value is! Map || !value.containsKey('chunk_id') || !value.containsKey('wall_time_seconds')) continue;
        if (value['chunk_id'] is! String || !RegExp(r'^[0-9a-f]{6}$').hasMatch(value['chunk_id'] as String)) return false;
        if (value.containsKey('session_id') && (value['session_id'] is! int || (value['session_id'] as int) < 1000 || (value['session_id'] as int) >= 100000)) return false;
      } on FormatException { /* Non-JSON prose. */ }
    }
  }
  return true;
}

Future<bool> compare(Json reference, Json actual, String path) async {
  final left = prepareComparison(reference), right = prepareComparison(actual);
  final equal = equals(left).matches(right, {});
  final a = encoder.convert(sortedKeys(left)).split('\n'), b = encoder.convert(sortedKeys(right)).split('\n');
  var index = 0;
  while (index < a.length && index < b.length && a[index] == b[index]) { index++; }
  if (!equal) {
    await Directory(path).create(recursive: true);
    await File('$path/first-difference.txt').writeAsString('Line ${index + 1}\n'
      'Codex: ${index < a.length ? a[index] : '<end>'}\n'
      'Happen: ${index < b.length ? b[index] : '<end>'}\n');
  }
  return equal;
}

Future<({HttpServer server, int bootstrapPort, Future<void> Function() close, Map<String, List<Json>> requests,
  Map<String, List<Json>> headers,
  Map<String, List<Json>> searches, Map<String, int> catalogs, Map<String, List<String>> files, List<String> errors,
  Map<String, Map<String, String>> modelIds})>
    responsesPeer(Json scenario, String outputPath, CancellationToken cancellation) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // Keep account discovery on a separate origin. Codex's real workspace router
  // then preserves the explicit local inference endpoint.
  final bootstrap = scenario['discovered_catalog'] == true
    ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0) : server;
  Future<void>? closing;
  Future<void> close() => closing ??= () async {
    await server.close(force: true);
    if (!identical(bootstrap, server)) await bootstrap.close(force: true);
  }();
  final hook = CancellationHook(cancellation, () => unawaited(close()));
  final requests = <String, List<Json>>{}, errors = <String>[];
  final headers = <String, List<Json>>{};
  final searches = <String, List<Json>>{};
  final catalogs = <String, int>{};
  final files = <String, List<String>>{};
  for (final engine in ['codex', 'happen']) { await Directory('$outputPath/$engine-requests').create(recursive: true); }
  final modelIds = <String, Map<String, String>>{};
  final continuationIds = <String, Map<int, Set<String>>>{};
  Future<void> handle(HttpRequest http) async {
    // This peer implements HTTP Responses. Exercise the built-in provider's
    // ordinary HTTP fallback instead of changing its WebSocket capability.
    if (WebSocketTransformer.isUpgradeRequest(http)) {
      http.response.statusCode = HttpStatus.upgradeRequired;
      await http.response.close();
      return;
    }
    try {
      final engine = http.uri.pathSegments.first;
      if (http.method == 'GET' && http.uri.path.endsWith('/models')) {
        catalogs.update(engine, (count) => count + 1, ifAbsent: () => 1);
        if (scenario['discovered_catalog'] != true || http.headers.value('authorization') != 'Bearer ${scenario['discovery_token']}' ||
            http.headers.value('chatgpt-account-id') != 'synthetic-account' || http.uri.queryParameters['client_version'] == null) {
          throw StateError('Model discovery must use the isolated account and backend');
        }
        http.response.headers.contentType = ContentType.json;
        http.response.headers.set('etag', 'context-contract-live-catalog');
        http.response.write(jsonEncode({'models': scenario['catalog_models']}));
        return;
      }
      if (scenario['discovered_catalog'] == true) {
        if (http.method == 'GET' && http.uri.path.endsWith('/api/codex/accounts/check')) {
          http.response.headers.contentType = ContentType.json;
          http.response.write(jsonEncode({'accounts': [{'id': 'synthetic-account', 'name': 'Contract account',
            'workspace_backend_origin': 'https://chatgpt.com', 'account_routing_override': 'NO_CONSTRAINT'}],
            'default_account_id': 'synthetic-account'}));
          return;
        }
        if (http.method == 'GET' && http.uri.path.endsWith('/api/codex/settings/user') ||
            http.method == 'POST' && http.uri.path.endsWith('/codex/analytics-events/events')) {
          http.response.headers.contentType = ContentType.json;
          http.response.write('{}');
          return;
        }
      }
      if (http.method != 'POST' || !http.uri.path.endsWith('/responses') && !http.uri.path.endsWith('/alpha/search')) {
        throw StateError('Unexpected backend request: ${http.method} ${http.uri.path}');
      }
      final chunks = await http.fold<BytesBuilder>(BytesBuilder(copy: false), (buffer, chunk) => buffer..add(chunk));
      final bytes = chunks.takeBytes();
      final body = jsonObject(jsonDecode(utf8.decode(bytes)));
      if (await respondToThreadName(http, body)) return;
      if (http.uri.path.endsWith('/alpha/search')) {
        final captured = searches.putIfAbsent(engine, () => [])..add(body);
        final fixtures = scenario['searches'] as List;
        final search = jsonObject(fixtures[(captured.length - 1) % fixtures.length]);
        final file = File('$outputPath/$engine-search-requests/${captured.length.toString().padLeft(6, '0')}.json');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        if (!equals(search['commands']).matches(body['commands'], {})) {
          throw StateError('Unexpected web.run commands: ${body['commands']}');
        }
        http.response.headers.contentType = ContentType.json;
        http.response.write(jsonEncode({'output': search['output'], 'results': [
          {'type': 'text_result', 'ref_id': 'turn0search0', 'title': 'Podcast source',
            'url': 'https://listenbox.app/', 'future_field': {'preserved': true}},
        ]}));
        return;
      }
      final threadKey = '$engine:${body['prompt_cache_key']}';
      if (engine == 'happen') {
        final key = scenario['discovered_catalog'] == true ? scenario['discovery_token'] : scenario['endpoint_key'];
        if (http.headers.value(HttpHeaders.authorizationHeader) != (key == null ? null : 'Bearer $key') ||
            http.headers.value('chatgpt-account-id') != (scenario['discovered_catalog'] == true ? 'synthetic-account' : null)) {
          throw StateError('Unexpected credentials at the local Responses endpoint');
        }
      }
      final captured = requests.putIfAbsent(engine, () => [])..add(body);
      final protocol = <String, dynamic>{
        'method': http.method, 'path': '/${http.uri.pathSegments.skip(1).join('/')}',
        for (final name in ['accept', 'content-type', 'openai-beta', 'x-openai-internal-codex-responses-lite'])
          name: http.headers.value(name),
      };
      headers.putIfAbsent(engine, () => []).add(protocol);
      // The endpoint owns the single authoritative capture for both harnesses.
      // Save the received bytes, never a re-encoded or reconstructed body.
      final file = File('$outputPath/$engine-requests/${captured.length.toString().padLeft(6, '0')}.json');
      await file.writeAsBytes(bytes, flush: true);
      await save('${file.path}.headers.json', protocol);
      files.putIfAbsent(engine, () => []).add(file.path);
      final completed = {for (final item in (body['input'] as List).map(jsonObject))
        if (['custom_tool_call_output', 'function_call_output', 'tool_search_output'].contains(item['type'])) item['call_id']};
      final messages = scenario['messages'] as List? ?? [];
      final prelude = scenario['workflow'] == 'compaction' && messages.length > 1 &&
        messages.take(messages.length - 1).contains(text((body['input'] as List).map(jsonObject)
          .lastWhere((item) => item['role'] == 'user')));
      final resumed = messages.length > 1 && (body['input'] as List).map(jsonObject)
        .any((item) => item['role'] == 'user' && text(item) == messages.last);
      final scripted = resumed && scenario['resume_responses'] is List ? scenario['resume_responses'] : scenario['responses'];
      final steps = (prelude ? null : scripted as List?) ?? [[{
        'type': 'message', 'role': 'assistant',
        'content': [{'type': 'output_text', 'text': 'READY', 'annotations': <Object?>[]}],
      }]];
      final continuing = (scenario['continue_after'] as List? ?? []).cast<int>().toSet();
      final inputIds = {for (final item in (body['input'] as List).map(jsonObject)) item['id']};
      var step = 0;
      while (step + 1 < steps.length) {
        final expected = {for (final item in (steps[step] as List).map(jsonObject))
          if (['custom_tool_call', 'function_call', 'tool_search_call'].contains(item['type'])) item['call_id']};
        if (expected.isEmpty) {
          final previous = continuationIds[threadKey]?[step];
          if (!continuing.contains(step) || previous == null || !inputIds.containsAll(previous)) break;
        } else if (!completed.containsAll(expected)) { break; }
        step++;
      }
      final compact = (body['input'] as List).last['type'] == 'compaction_trigger';
      final restored = (body['input'] as List).any((item) => item['type'] == 'compaction');
      if (scenario['workflow'] == 'compaction' && restored) step = steps.length - 1;
      final output = [for (var i = 0; i < (steps[step] as List).length; i++) {
        'id': 'fixture_item_${captured.length}_$i',
        if (steps[step][i]['type'] != 'reasoning') 'status': 'completed', ...jsonObject(steps[step][i]),
      }];
      if (step == 0 && protocol['x-openai-internal-codex-responses-lite'] != 'true') {
        if (scenario['unnegotiated_search_response'] case final Map<String, dynamic> unnegotiated) {
          output[0] = {...output.first, ...unnegotiated};
        }
      }
      if (compact) {
        output.clear();
        output.add({'type': 'compaction', 'encrypted_content': 'context-contract-native-checkpoint'});
      }
      for (final item in output) {
        if (item['id'] case final String id) (modelIds[engine] ??= {})[id] = item['type'] as String;
      }
      if (continuing.contains(step)) {
        (continuationIds[threadKey] ??= {})[step] = output.map((item) => item['id'] as String).toSet();
      }
      final compactLimit = scenario['auto_compact_limit'] as int? ?? 20000;
      final inputTokens = scenario['workflow'] == 'compaction' && !prelude && !compact && !restored
        ? output.any((item) => item['name'] == 'wait') ? compactLimit - 10
          : scenario['catalog_compaction'] == true && output.any((item) => item['name'] == 'exec')
            ? compactLimit - 1010 : 100
        : 100;
      final response = {'id': 'resp_fixture_${captured.length}', 'object': 'response', 'status': 'completed',
        if (continuing.isNotEmpty) 'end_turn': !continuing.contains(step),
        'output': output, 'usage': {'input_tokens': inputTokens, 'output_tokens': 10, 'total_tokens': inputTokens + 10}};
      final stream = StringBuffer();
      void event(Json value) => stream.write('data: ${jsonEncode(value)}\n\n');
      event({'type': 'response.created', 'response': {...response, 'status': 'in_progress', 'output': <Object?>[]}});
      for (var i = 0; i < output.length; i++) {
        event({'type': 'response.output_item.added', if (scenario['indexless_stream'] != true) 'output_index': i, 'item': output[i]});
        event({'type': 'response.output_item.done', if (scenario['indexless_stream'] != true) 'output_index': i, 'item': output[i]});
      }
      event({'type': 'response.completed', 'response': {...response, 'output': <Object?>[]}});
      http.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      http.response.add(utf8.encode(stream.toString()));
    } catch (error, stack) {
      errors.add('$error\n$stack');
      await File('$outputPath/peer-errors.log').writeAsString('$error\n$stack\n', mode: FileMode.append);
      try { http.response.statusCode = 500; } on StateError { /* Preserve the primary error after a peer disconnect. */ }
    } finally { await http.response.close(); }
  }
  server.listen(handle);
  if (!identical(bootstrap, server)) bootstrap.listen(handle);
  return (server: server, bootstrapPort: bootstrap.port, close: () async { hook.dispose(); await close(); },
    requests: requests, headers: headers, searches: searches, catalogs: catalogs, files: files, errors: errors, modelIds: modelIds);
}

Future<Json> scenario(Json scenario, String model, String codex, String output,
  CancellationToken cancellation, String catalog, {required bool codeModeOnly,
    required String reasoning, required String reasoningSummary}) async {
  String terminalCall(String id) => jsonObject(scenario['terminal_calls'] ?? {})[id] as String? ?? id;
  bool toolOutput(Json item) => {'custom_tool_call_output', 'function_call_output'}.contains(item['type']);
  final work = '$output/work', codexHome = '$output/codex-home', data = '$output/happen-data';
  await Directory(output).create(recursive: true);
  final home = (await Directory(output).createTemp('home-')).path;
  for (final path in [work, codexHome, data]) { await Directory(path).create(recursive: true); }
  final globalSkills = Directory('$home/.agents/skills');
  await globalSkills.create(recursive: true);
  for (final entry in jsonObject(scenario['global_skills'] ?? {}).entries) {
    final file = File('${globalSkills.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value as String);
  }
  for (final entry in jsonObject(scenario['files']).entries) {
    final file = File('$work/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value as String);
  }
  for (final entry in jsonObject(scenario['binary_files'] ?? {}).entries) {
    final file = File('$work/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(base64Decode(entry.value as String));
  }
  for (final entry in jsonObject(scenario['binary_sources'] ?? {}).entries) {
    final file = File('$work/${entry.key}');
    await file.parent.create(recursive: true);
    await File('${fixtures.path}/${entry.value}').copy(file.path);
  }
  final cwd = '$work/${scenario['cwd'] ?? '.'}';
  await Directory(cwd).create(recursive: true);
  final env = isolatedEnvironment(home, codexHome);
  await run(['git', 'init', '--quiet', work], env, '$output/git.log', cancellation);
  if (scenario['global_instructions'] case final String instructions) {
    for (final path in [codexHome, data]) { await File('$path/AGENTS.md').writeAsString(instructions); }
  }
  scenario = jsonObject(jsonDecode(
    jsonEncode(scenario).replaceAll('{{WORK_URI}}', Directory(work).uri.toString())
      .replaceAll('{{SKILLS_ROOT}}', globalSkills.path)));
  final peer = await responsesPeer(scenario, output, cancellation);
  final endpoint = 'http://127.0.0.1:${peer.server.port}';
  final config = StringBuffer('''
model_catalog_json = ${jsonEncode(catalog)}
openai_base_url = "$endpoint/codex"
${scenario['selected_model'] == true ? 'model = "$model"' : ''}
${scenario['selected_reasoning'] == true ? 'model_reasoning_effort = "$reasoning"' : ''}
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
${scenario['request_user_input'] == true ? 'default_mode_request_user_input = true' : ''}
code_mode_tool_search = true
# codex-cli 0.166 predates the checkout's default for deferred tool context.
deferred_tool_world_state = true
multi_agent = false
plugins = false
apps = false
''');
  final happenConfig = <String, dynamic>{};
  final settings = <String, dynamic>{
    if (scenario['request_user_input'] == true) 'default_mode_request_user_input': true,
  };
  if ({'compaction', 'audio'}.contains(scenario['workflow']) && scenario['catalog_compaction'] != true) {
    final text = config.toString();
    config.clear();
    config.write('model_context_window = 100000\nmodel_auto_compact_token_limit = 20000\n$text');
    settings.addAll({'context_limit': 100000, 'compaction_headroom': 80000});
  }
  if (scenario['mcp'] == true) {
    await run(['dart', 'pub', 'get', '--offline'], env, '$output/pub-get.log', cancellation, cwd: work);
    // Install the SDK's real server once, then launch its installed executable
    // directly. The Dart command dispatcher otherwise consumes the optional
    // server's default startup grace before the server itself can initialize.
    await run(['dart', 'mcp-server', '--help'], env, '$output/mcp-prepare.log', cancellation, cwd: work);
    final executables = await Directory(home).list(recursive: true, followLinks: false)
      .where((entry) => entry is File && entry.path.replaceAll('\\', '/').endsWith(
        '/bundle/bin/dart_mcp_server${Platform.isWindows ? '.exe' : ''}')).toList().asCancellable(cancellation);
    final mcp = {'command': executables.single.path,
      'args': ['--dart-sdk', File(Platform.resolvedExecutable).parent.parent.path], 'env': env};
    config.writeln('[mcp_servers.dart]\ncommand = ${jsonEncode(mcp['command'])}\nargs = ${jsonEncode(mcp['args'])}');
    config.writeln('[mcp_servers.dart.env]');
    for (final entry in env.entries) { config.writeln('${entry.key} = ${jsonEncode(entry.value)}'); }
    happenConfig['mcp_servers'] = {'dart': mcp};
  }
  await File('$codexHome/config.toml').writeAsString(config.toString());
  await save('$data/config.yaml', happenConfig);
  final codexEnv = {...env, 'OPENAI_API_KEY': 'synthetic-context-contract'};
  final prompt = scenario['prompt'] as String;
  final command = [codex, '-C', cwd];
  final checks = <String, bool>{};
  final host = await AgentServer.startLocal(directory: data, configPath: '$data/config.yaml', skillsHome: home,
    endpoint: '$endpoint/happen/responses', apiKeyEnv: 'CONTEXT_CONTRACT_UNUSED_${newId()}', telemetry: false);
  final client = AgentClient.local(host);
  final nativeEvents = <Json>[];
  final nativeSubscription = client.events.stream.listen((event) {
    if ({'item/started', 'item/completed'}.contains(event['method']) && event['params']?['item']?['type'] == 'webSearch') nativeEvents.add(event);
  });
  try {
    // Opposite execution orders cover fresh-thread isolation and reuse of the
    // shared MCP owner. These are functional replays, not benchmark samples.
    const orders = [['codex', 'happen'], ['happen', 'codex']];
    for (final (iteration, order) in orders.indexed) {
      final runPath = '$output/run-$iteration';
      final starts = {for (final engine in ['codex', 'happen']) engine: peer.requests[engine]?.length ?? 0};
      String? taskID;
      Future<void> turn(String prompt) async {
        if (taskID == null) {
          final started = jsonObject(await client.request('thread/start', {'cwd': cwd,
            'config': {'thread_unload_delay_secs': 0},
            if (scenario['selected_model'] == true) 'model': model,
            if (scenario['selected_reasoning'] == true) 'reasoning': reasoning,
            if (settings.isNotEmpty) 'settings': settings,
          }).asCancellable(cancellation));
          taskID = started['thread']['id'] as String;
          final config = jsonObject(started['configuration']);
          final resolved = jsonObject(config['provider_settings']);
          final defaults = GptModel(model).data;
          final window = settings['context_limit'] ?? defaults['context_window'];
          checks['happen:resolved_model:run-$iteration'] = config['model'] == model;
          checks['happen:resolved_effort:run-$iteration'] = resolved['reasoning'] == reasoning;
          checks['happen:raw_context_window:run-$iteration'] = resolved['context_limit'] == window;
          checks['happen:usable_context_window:run-$iteration'] = config['context_window'] ==
            (window as int) * (defaults['effective_context_window_percent'] as int? ?? 95) ~/ 100;
        }
        final input = StreamIterator(client.events.stream);
        try {
          await client.request('turn/start', {'threadId': taskID, 'input': [{'type': 'text', 'text': prompt}]}).asCancellable(cancellation);
          while (await input.moveNext().asCancellable(cancellation, onCancel: () => unawaited(input.cancel()))) {
            final event = input.current;
            if (event['method'] != 'turn/completed' || event['params']['threadId'] != taskID) continue;
            final completed = jsonObject(event['params']['turn']);
            if (completed['status'] != 'completed') throw StateError('Agent turn failed: ${completed['error']}');
            return;
          }
          throw StateError('Connection closed before completion');
        } finally { await input.cancel(); }
      }
      for (final engine in order) {
        final messages = (scenario['messages'] as List? ?? [prompt,
          if (scenario['workflow'] == 'resume') 'Continue and reply READY.']).cast<String>();
        for (var message = 0; message < messages.length; message++) {
          if (engine == 'codex') {
            await run([...command, 'exec',
              if (message == 0) '--skip-git-repo-check' else ...['resume', '--last'],
              '--json', messages[message]], codexEnv, '$runPath/$engine.message-$message.jsonl', cancellation);
          } else {
            // Each reference turn starts a new Codex process, including resume.
            if (message > 0) {
              await unloadThread(client, taskID!, cancellation: cancellation);
              await client.request('thread/resume', {'threadId': taskID,
                'config': {'thread_unload_delay_secs': 0}}).asCancellable(cancellation);
            }
            await turn(messages[message]);
          }
        }
      }
      final a = (peer.requests['codex'] ?? []).skip(starts['codex']!).toList();
      final b = (peer.requests['happen'] ?? []).skip(starts['happen']!).toList();
      final aHeaders = (peer.headers['codex'] ?? []).skip(starts['codex']!).toList();
      final bHeaders = (peer.headers['happen'] ?? []).skip(starts['happen']!).toList();
      await save('$runPath/received-request-files.json', {
        for (final engine in ['codex', 'happen']) engine: (peer.files[engine] ?? []).skip(starts[engine]!).toList(),
      });
      checks['same_model_calls:run-$iteration'] = a.length == b.length && a.isNotEmpty;
      checks['same_selected_model:run-$iteration'] = [...a, ...b].every((request) => request['model'] == model);
      checks['same_selected_reasoning:run-$iteration'] = [...a, ...b].every((request) =>
        request['reasoning']?['effort'] == reasoning &&
        request['reasoning']?['summary'] == (reasoningSummary == 'none' ? null : reasoningSummary));
      checks['happen:no_client_metadata:run-$iteration'] = b.isNotEmpty && b.every((request) => !request.containsKey('client_metadata'));
      for (final pair in [('codex', a), ('happen', b)]) {
        checks['${pair.$1}:thread_id_contract:run-$iteration'] = pair.$2.isNotEmpty &&
          pair.$2.every((request) => uuid7(request['prompt_cache_key']) && request['prompt_cache_key'] == pair.$2.first['prompt_cache_key']);
        final input = pair.$2.isEmpty ? <Json>[] : (pair.$2.first['input'] as List).map(jsonObject).toList();
        final serialized = jsonEncode(input.isEmpty ? [] : input.take(input.length - 1).toList());
        checks['${pair.$1}:prompt_last:run-$iteration'] = input.isNotEmpty &&
          input.lastWhere((item) => item['type'] != 'configuration_update')['role'] == 'user' &&
          text(input.lastWhere((item) => item['type'] != 'configuration_update')) == prompt;
        for (final marker in scenario['contains'] as List) { checks['${pair.$1}:contains:$marker:run-$iteration'] = serialized.contains(marker as String); }
        for (final marker in scenario['absent'] as List) { checks['${pair.$1}:absent:$marker:run-$iteration'] = !jsonEncode(input).contains(marker as String); }
        final listed = RegExp(r'^- ([^:\n]+):[^\n]*\(file: ', multiLine: true)
          .allMatches(input.map(text).join('\n')).map((match) => match[1]!).toSet();
        final expected = (scenario['catalog_skills'] as List? ?? []).cast<String>().toSet();
        checks['${pair.$1}:only_fixture_skills:run-$iteration'] = listed.length == expected.length && listed.containsAll(expected);
      }
      checks['happen:admitted_thread_id:run-$iteration'] = b.isNotEmpty && b.first['prompt_cache_key'] == taskID;
      for (var i = 0; i < a.length && i < b.length; i++) {
        checks['request_equal:$i:run-$iteration'] = await compare(a[i], b[i], '$runPath/request-$i');
        checks['request_protocol_equal:$i:run-$iteration'] = equals(aHeaders[i]).matches(bHeaders[i], {});
        for (final pair in [('codex', aHeaders[i]), ('happen', bHeaders[i])]) {
          checks['${pair.$1}:responses_lite_negotiated:$i:run-$iteration'] =
            pair.$2['x-openai-internal-codex-responses-lite'] == 'true';
        }
        for (final pair in [('codex', a[i]), ('happen', b[i])]) {
          final items = (pair.$2['input'] as List).map(jsonObject).toList();
          checks['${pair.$1}:request_item_id_contract:$i:run-$iteration'] = itemIdContract(items,
            modelIds: peer.modelIds[pair.$1] ?? {});
          checks['${pair.$1}:shell_id_contract:$i:run-$iteration'] = shellIdContract(items);
        }
        List<Json> declarations(Json request) => [
          for (final item in (request['input'] as List).map(jsonObject))
            if (item['type'] == 'additional_tools')
              for (final namespace in (item['tools'] as List).map(jsonObject))
                ...(namespace['tools'] as List? ?? [namespace]).map(jsonObject),
        ];
        final referenceTools = declarations(a[i]), actualTools = declarations(b[i]);
        final referenceExec = referenceTools.where((tool) => tool['name'] == 'exec').lastOrNull;
        final actualExec = actualTools.where((tool) => tool['name'] == 'exec').lastOrNull;
        const nestedMarker = 'Shared MCP Types:';
        String? nested(Json? tool) {
          final description = tool?['description'] as String? ?? '';
          final start = description.indexOf(nestedMarker);
          return start < 0 ? null : description.substring(start);
        }
        checks['nested_tool_context_equal:$i:run-$iteration'] = codeModeOnly
          ? nested(referenceExec) != null && nested(referenceExec) == nested(actualExec)
          : referenceExec != null && actualExec != null && nested(referenceExec) == null && nested(actualExec) == null;
        for (final pair in [('codex', referenceTools), ('happen', actualTools)]) {
          checks['${pair.$1}:code_mode_only_surface:$i:run-$iteration'] =
            pair.$2.any((tool) => tool['name'] == 'exec_command') == !codeModeOnly;
        }
        checks['codex_parallel_tool_calls:$i:run-$iteration'] = a[i]['parallel_tool_calls'] == false;
        checks['happen_parallel_tool_calls:$i:run-$iteration'] = b[i]['parallel_tool_calls'] == false;
        checks['reasoning_context_all_turns:$i:run-$iteration'] = a[i]['reasoning']['context'] == 'all_turns' &&
          b[i]['reasoning']['context'] == 'all_turns';
        for (final pair in [('codex', a[i]), ('happen', b[i])]) {
          final input = (pair.$2['input'] as List).map(jsonObject).toList();
          final exec = pair.$1 == 'codex' ? referenceExec : actualExec;
          final execDescription = exec?['description'] as String? ?? '';
          checks['${pair.$1}:catalog_prefix:$i:run-$iteration'] = input.length > 1 &&
            input.first['type'] == 'additional_tools' && input[1]['role'] == 'developer' &&
            text(input[1]).startsWith('You are Codex,');
          checks['${pair.$1}:standalone_web_run:$i:run-$iteration'] = !pair.$2.containsKey('tools') &&
            (codeModeOnly ? execDescription.contains('declare const tools: { web__run(')
              : input.where((item) => item['type'] == 'additional_tools').any((item) =>
                (item['tools'] as List).any((tool) => tool['type'] == 'namespace' && tool['name'] == 'web' &&
                  (tool['tools'] as List).any((tool) => tool['name'] == 'run'))));
        }
        if (scenario['mcp'] == true) {
          for (final entry in {'codex': a[i], 'happen': b[i]}.entries) {
            final definitions = declarations(entry.value);
            checks['${entry.key}:discovery_declared:$i:run-$iteration'] =
              jsonEncode(definitions).contains('tools.tool_search');
          }
        }
      }
      if (scenario['result'] case final String marker) {
        for (final engine in ['codex', 'happen']) {
          final requests = engine == 'codex' ? a : b;
          checks['$engine:tool_result_delivered:run-$iteration'] = requests.length > 1 && (requests.last['input'] as List).map(jsonObject)
            .where((item) => ['custom_tool_call_output', 'function_call_output', 'tool_search_output'].contains(item['type']))
            .any((item) => jsonEncode(item).contains(marker));
        }
      }
      if (scenario['workflow'] == 'parallel') {
        for (final pair in [('codex', a), ('happen', b)]) {
          final outputs = (pair.$2.last['input'] as List).map(jsonObject)
            .where((item) => item['call_id'] == terminalCall('parallel_shells') && toolOutput(item));
          checks['${pair.$1}:both_parallel_tools_completed:run-$iteration'] = outputs.any((output) {
            final printed = <Json>[];
            for (final part in (output['output'] as List).map(jsonObject)) {
              try {
                final value = jsonDecode(part['text'] as String? ?? '');
                if (value is Map) printed.add(jsonObject(value));
              } on FormatException { /* The script status is ordinary prose. */ }
            }
            final results = printed.where((item) => item['status'] == 'fulfilled').toList();
            return printed.any((item) => item['both_succeeded'] == true) && results.length == 2 &&
              results.every((item) => item['value']?['exit_code'] == 0);
          });
        }
      }
      if (scenario['workflow'] == 'image') {
        for (final pair in [('codex', a), ('happen', b)]) {
          final outputs = pair.$2.isEmpty ? <Json>[] : (pair.$2.last['input'] as List).map(jsonObject)
            .where((item) => toolOutput(item) && item['call_id'] == terminalCall('image_result')).toList();
          final parts = outputs.length == 1 && outputs.single['output'] is List
            ? (outputs.single['output'] as List).map(jsonObject).toList() : <Json>[];
          checks['${pair.$1}:generated_image_content_order:run-$iteration'] =
            jsonEncode(parts.map((part) => part['type']).toList()) == jsonEncode(['input_text', 'input_text', 'input_image', 'input_text', 'input_text']) &&
            parts[1]['text'] == 'image-before' && parts[3]['text'] == 'image-output-hint' && parts[4]['text'] == 'image-after';
        }
      }
      if (scenario['workflow'] == 'audio') {
        for (final pair in [('codex', a), ('happen', b)]) {
          final outputs = pair.$2.isEmpty ? <Json>[] : (pair.$2.last['input'] as List).map(jsonObject)
            .where((item) => toolOutput(item) && item['call_id'] == terminalCall('audio_result')).toList();
          final parts = outputs.length == 1 && outputs.single['output'] is List
            ? (outputs.single['output'] as List).map(jsonObject).toList() : <Json>[];
          checks['${pair.$1}:recorded_audio_content_order:run-$iteration'] =
            jsonEncode(parts.map((part) => part['type']).toList()) == jsonEncode(['input_text', 'input_text', 'input_text', 'input_text']) &&
            parts[1]['text'] == 'audio-before' && parts[2]['text'] == 'audio content omitted because you do not support audio input' &&
            parts[3]['text'] == 'audio-after';
          checks['${pair.$1}:audio_bytes_not_counted_as_prose:run-$iteration'] = pair.$2.length == (scenario['responses'] as List).length &&
            pair.$2.every((request) => (request['input'] as List).last['type'] != 'compaction_trigger');
        }
      }
      if (scenario['workflow'] == 'web') {
        final expectedSearches = (scenario['searches'] as List).length * (scenario['messages'] as List? ?? [prompt]).length;
        final left = (peer.searches['codex'] ?? []).skip(iteration * expectedSearches).toList();
        final right = (peer.searches['happen'] ?? []).skip(iteration * expectedSearches).toList();
        checks['same_full_search_requests:run-$iteration'] = left.length == expectedSearches && right.length == expectedSearches;
        for (var i = 0; i < left.length && i < right.length; i++) {
          checks['same_full_search_request:$i:run-$iteration'] = await compare(
            {...left[i]}..remove('id'), {...right[i]}..remove('id'), '$runPath/search-$i');
        }
        final codexThread = a.first['prompt_cache_key'] as String;
        final rollouts = await Directory('$codexHome/sessions').list(recursive: true)
          .where((entry) => entry is File && entry.path.endsWith('-$codexThread.jsonl')).toList();
        final rollout = (await File(rollouts.single.path).readAsLines()).map((line) => jsonObject(jsonDecode(line)));
        final referenceItems = rollout.where((line) => line['type'] == 'event_msg' && line['payload']?['type'] == 'item_completed' &&
          line['payload']?['item']?['kind'] == 'web.search').map((line) => jsonObject(line['payload']['item'])).toList();
        Json searchFields(Json item) => {...item}..remove('id')..remove('type')..remove('kind')
          ..remove('startedAtMs')..remove('completedAtMs');
        final activity = nativeEvents.where((event) => event['params']['threadId'] == taskID).toList();
        final starts = activity.where((event) => event['method'] == 'item/started').toList();
        final ends = activity.where((event) => event['method'] == 'item/completed').toList();
        final codexActivity = <Json>[];
        for (var message = 0; message < (scenario['messages'] as List? ?? [prompt]).length; message++) {
          codexActivity.addAll((await File('$runPath/codex.message-$message.jsonl').readAsLines())
            .map((line) => jsonObject(jsonDecode(line))).where((event) => event['item']?['type'] == 'web_search'));
        }
        checks['same_search_lifecycle:run-$iteration'] = starts.length == expectedSearches && ends.length == expectedSearches &&
          codexActivity.where((event) => event['type'] == 'item.started').length == starts.length &&
          codexActivity.where((event) => event['type'] == 'item.completed').length == ends.length &&
          starts.indexed.every((entry) => entry.$2['params']['item']['id'] == ends[entry.$1]['params']['item']['id'] &&
            activity.indexOf(entry.$2) < activity.indexOf(ends[entry.$1]));
        checks['same_completed_search_items:run-$iteration'] = referenceItems.length == expectedSearches &&
          equals(referenceItems.map(searchFields).toList()).matches(ends.map((event) => searchFields(jsonObject(event['params']['item']))).toList(), {});
        final persisted = jsonObject(await client.request('thread/items/list', {'threadId': taskID}));
        checks['same_persisted_search_items:run-$iteration'] = equals(referenceItems.map(searchFields).toList()).matches(
          (persisted['data'] as List).map((entry) => jsonObject(entry['item'])).where((item) => item['type'] == 'webSearch').map(searchFields).toList(), {});
        await save('$runPath/native-search-items.json', {'codex': referenceItems, 'happen': activity});
        for (final pair in [('codex', a), ('happen', b)]) {
          final input = (pair.$2.last['input'] as List).map(jsonObject).toList();
          final searches = peer.searches[pair.$1] ?? [];
          checks['${pair.$1}:web_run_executed:run-$iteration'] = searches.length == (iteration + 1) * expectedSearches &&
            searches.every((request) => request['model'] == model && request['settings']['external_web_access'] == true);
          checks['${pair.$1}:web_run_result_retained:run-$iteration'] = input.any((item) =>
            item['type'] == 'custom_tool_call_output' && item['call_id'] == 'youtube_podcast_search' &&
              jsonEncode(item['output']).contains('YOUTUBE_PODCAST_SEARCH_RECEIPT'));
          checks['${pair.$1}:web_run_citation_retained:run-$iteration'] = input.any((item) => item['role'] == 'assistant' &&
            jsonEncode(item['content']).contains('https://listenbox.app/'));
        }
      }
      if (scenario['workflow'] == 'continuation') {
        for (final pair in [('codex', a), ('happen', b)]) {
          checks['${pair.$1}:commentary_continues_to_real_tool_execution:run-$iteration'] = pair.$2.length == (scenario['responses'] as List).length &&
            (pair.$2.last['input'] as List).map(jsonObject).any((item) => item['role'] == 'assistant' && item['phase'] == 'commentary' &&
              text(item) == "I'll check the requested tools.");
        }
      }
      if (scenario['retain_model_items'] == true) {
        final steps = [...(scenario['responses'] as List), ...(scenario['resume_responses'] as List? ?? [])];
        final expected = steps.take(steps.length - 1).expand((step) => step as List).map(jsonObject).toList();
        for (final pair in [('codex', a), ('happen', b)]) {
          final input = pair.$2.isEmpty ? <Json>[] : (pair.$2.last['input'] as List).map(jsonObject).toList();
          final retained = input.where((item) => peer.modelIds[pair.$1]?.containsKey(item['id']) == true).toList();
          checks['${pair.$1}:model_items_retained_in_order:run-$iteration'] = pair.$2.length == steps.length &&
            retained.length == expected.length && [for (var i = 0; i < expected.length && i < retained.length; i++)
              expected[i].entries.every((entry) => retained[i].containsKey(entry.key) && equals(entry.value).matches(retained[i][entry.key], {}))]
              .every((value) => value);
        }
      }
      if (scenario['workflow'] == 'tldw') {
        for (final pair in [('codex', a), ('happen', b)]) {
          final input = pair.$2.isEmpty ? <Json>[] : (pair.$2.last['input'] as List).map(jsonObject).toList();
          final receipts = {for (final item in input.where(toolOutput)) item['call_id']: item['output']};
          for (final entry in jsonObject(scenario['terminal_calls'] ?? {}).entries) {
            receipts[entry.key] = receipts[entry.value];
          }
          final skillReads = receipts['tldw_read_skills'] is List
            ? (receipts['tldw_read_skills'] as List).skip(1).map((part) => jsonObject(jsonDecode(part['text'] as String))).toList() : <Json>[];
          final skillFiles = jsonObject(scenario['global_skills']).values.toList();
          checks['${pair.$1}:tldw_skill_bodies_delivered:run-$iteration'] = skillReads.length == skillFiles.length &&
            skillReads.indexed.every((entry) => entry.$2['i'] == entry.$1 && entry.$2['status'] == 'fulfilled' &&
              entry.$2['value']?['exit_code'] == 0 && entry.$2['value']?['output'] == skillFiles[entry.$1]);
          final discovery = receipts['tldw_discover'] is List ? (receipts['tldw_discover'] as List).skip(1).take(2).toList() : <Object?>[];
          checks['${pair.$1}:parallel_shell_receipts_delivered:run-$iteration'] = discovery.length == 2 &&
            [for (var i = 0; i < discovery.length; i++) jsonObject(jsonDecode(jsonObject(discovery[i])['text'] as String))]
              .indexed.every((entry) => entry.$2['i'] == entry.$1 && entry.$2['status'] == 'fulfilled' && entry.$2['value']?['exit_code'] == 0);
          checks['${pair.$1}:transcript_read_truncated:run-$iteration'] = jsonEncode(receipts['tldw_read_transcript']).contains('tokens truncated');
          final recovered = jsonEncode(receipts['tldw_recover_transcript']);
          checks['${pair.$1}:transcript_reread_delivered:run-$iteration'] = recovered.contains('[14:01]') &&
            recovered.contains('[21:39]') && recovered.contains('[34:58]') && !recovered.contains('tokens truncated');
        }
      }
      if (scenario['workflow'] == 'goal') {
        for (final pair in [('codex', a), ('happen', b)]) {
          final input = (pair.$2.last['input'] as List).map(jsonObject).toList();
          final output = input.singleWhere((item) => item['type'] == 'custom_tool_call_output' && item['call_id'] == 'goal_restore');
          final parts = output['output'] as List;
          final saved = jsonObject(jsonDecode(parts.last['text'] as String));
          final goal = jsonObject(saved['goal']);
          checks['${pair.$1}:completed_goal_survives_cold_resume:run-$iteration'] = goal['threadId'] == pair.$2.last['prompt_cache_key'] &&
            goal['objective'] == 'GOAL_CONTEXT_RECEIPT' && goal['status'] == 'complete' && goal['tokensUsed'] == 110 &&
            goal['tokenBudget'] == 1000 && saved['remainingTokens'] == 890;
        }
      }
      if (scenario['workflow'] == 'compaction') {
        for (final engine in ['codex', 'happen']) {
          final requests = engine == 'codex' ? a : b;
          final compactions = requests.where((request) => (request['input'] as List).last['type'] == 'compaction_trigger').toList();
          final following = requests.where((request) => (request['input'] as List).any((item) => item['type'] == 'compaction')).toList();
          checks['$engine:one_real_compaction:run-$iteration'] = compactions.length == 1;
          checks['$engine:tool_receipt_entered_history:run-$iteration'] = compactions.length == 1 && jsonEncode(compactions.single['input']).contains('COMPACTION_TOOL_RECEIPT');
          checks['$engine:checkpoint_installed:run-$iteration'] = following.isNotEmpty && (following.last['input'] as List)
            .where((item) => item['type'] == 'compaction' && item['encrypted_content'] == 'context-contract-native-checkpoint').length == 1;
          checks['$engine:tool_receipt_compacted:run-$iteration'] = following.isNotEmpty && !jsonEncode(following.last['input']).contains('COMPACTION_TOOL_RECEIPT');
          final restoredText = following.isEmpty ? '' : (following.last['input'] as List).map((item) => text(jsonObject(item))).join('\n');
          checks['$engine:instructions_restored_once:run-$iteration'] = RegExp('COMPACTION_REPOSITORY_RULE').allMatches(restoredText).length == 1;
          checks['$engine:skills_restored_once:run-$iteration'] = RegExp('- fixture-global:').allMatches(restoredText).length == 1;
          if (scenario['messages'] case final List<Object?> messages) {
            final before = compactions.length == 1 ? (compactions.single['input'] as List).map(jsonObject).toList() : <Json>[];
            final after = following.isNotEmpty ? (following.last['input'] as List).map(jsonObject).toList() : <Json>[];
            final retained = [for (final item in after)
              if (item['type'] == 'compaction') '<CHECKPOINT>'
              else if (item['role'] == 'user' && messages.contains(text(item))) text(item)];
            checks['$engine:multiple_users_entered_compaction_in_order:run-$iteration'] =
              equals(messages).matches([for (final item in before)
                if (item['role'] == 'user' && messages.contains(text(item))) text(item)], {});
            checks['$engine:retained_users_precede_checkpoint_in_order:run-$iteration'] =
              equals([...messages, '<CHECKPOINT>']).matches(retained, {});
          }
        }
      }
      for (final discovery in jsonObject(scenario['discovery_calls'] ?? {}).entries) {
        final expected = jsonObject(discovery.value);
        for (final pair in [('codex', a), ('happen', b)]) {
          final outputs = pair.$2.isEmpty ? <Json>[] : (pair.$2.last['input'] as List).map(jsonObject)
            .where((item) => item['type'] == 'custom_tool_call_output' &&
              item['call_id'] == discovery.key).toList();
          final found = <Json>[];
          for (final output in outputs) {
            for (final part in output['output'] is List ? (output['output'] as List).map(jsonObject) : <Json>[]) {
                try {
                  final value = jsonDecode(part['text'] as String? ?? '');
                  if (value is Map && value['tools'] is List) found.addAll((value['tools'] as List).map(jsonObject));
                } on FormatException { /* The separate script status is ordinary prose. */ }
            }
          }
          checks['${pair.$1}:${discovery.key}:nonempty:run-$iteration'] = found.isNotEmpty && found.length <= (expected['limit'] as int);
          checks['${pair.$1}:${discovery.key}:dart_names:run-$iteration'] = found.isNotEmpty && found.every((tool) =>
            (tool['name'] as String).startsWith('mcp__dart__'));
          checks['${pair.$1}:${discovery.key}:declarations:run-$iteration'] = found.isNotEmpty && found.every((tool) =>
            (tool['description'] as String).contains('declare const tools: { ${tool['name']}('));
          if (expected['names'] case final List<Object?> names) {
            checks['${pair.$1}:${discovery.key}:selected_tools:run-$iteration'] = jsonEncode(found.map((tool) => tool['name']).toList()) == jsonEncode(names);
          }
        }
      }
      if (scenario['workflow'] == 'cells') {
        for (final pair in [('codex', a), ('happen', b)]) {
          final outputs = pair.$2.isEmpty ? <Json>[] : (pair.$2.last['input'] as List).map(jsonObject)
            .where((item) => {'custom_tool_call_output', 'function_call_output'}.contains(item['type'])).toList();
          final printed = outputs.map((item) => jsonEncode(item['output'])).join('\n');
          checks['${pair.$1}:cell_ids_are_session_counters:run-$iteration'] = printed.contains('Script running with cell ID 1') &&
            printed.contains('Script running with cell ID 2');
          checks['${pair.$1}:wait_terminated:run-$iteration'] = printed.contains('Script terminated') && !printed.contains('UNEXPECTED_AFTER_TERMINATE');
          checks['${pair.$1}:native_exit_completed:run-$iteration'] = printed.contains('BEFORE_EXIT') && !printed.contains('UNEXPECTED_AFTER_EXIT') &&
            outputs.any((item) => item['call_id'] == 'exit_cell' && jsonEncode(item['output']).contains('Script completed'));
          checks['${pair.$1}:notification_delivered:run-$iteration'] = outputs.where((item) =>
            jsonEncode(item['output']).contains('CELL_NOTICE')).length == 1;
          checks['${pair.$1}:clock_format:run-$iteration'] = outputs.any((item) => jsonEncode(item['output']).contains(r'{\"clock\":true}'));
        }
      }
    }
    for (final engine in ['codex', 'happen']) {
      final ids = (peer.requests[engine] ?? []).map((request) => request['prompt_cache_key']).toSet().cast<String>().toList();
      checks['$engine:thread_ids_monotonic'] = ids.isNotEmpty &&
        [for (var i = 1; i < ids.length; i++) ids[i - 1].compareTo(ids[i]) < 0].every((value) => value);
    }
    if (scenario['id'] == 'empty') {
      // Real concurrent turns exercise ID allocation and delivery; no debug-only
      // preparation or generator endpoint stands in for the production owner.
      final completed = <String>{}, done = Completer<void>();
      final subscription = client.events.stream.listen((event) {
        if (event['method'] != 'turn/completed') return;
        if (event['params']['turn']['status'] == 'completed') {
          completed.add(requiredString(jsonObject(event['params']), 'threadId'));
          if (completed.length == 16 && !done.isCompleted) done.complete();
        } else if (!done.isCompleted) {
          done.completeError(StateError('Concurrent turn failed: $event'));
        }
      });
      try {
        final admitted = await Future.wait(List.generate(16, (_) async {
          final page = jsonObject(await client.request('thread/start', {'cwd': cwd, 'provider': 'openai', 'model': model})
            .asCancellable(cancellation));
          final id = page['thread']['id'] as String;
          await client.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': prompt}]}).asCancellable(cancellation);
          return id;
        }));
        await done.future.asCancellable(cancellation);
        final ids = admitted;
        checks['happen:concurrent_thread_ids_uuid7'] = ids.every(uuid7);
        checks['happen:concurrent_thread_ids_unique'] = ids.toSet().length == ids.length;
        checks['happen:concurrent_thread_ids_monotonic'] = [for (var i = 1; i < ids.length; i++)
          ids[i - 1].compareTo(ids[i]) < 0].every((value) => value);
        checks['happen:concurrent_threads_reached_inference'] = ids.every((id) =>
          peer.requests['happen']!.any((request) => request['prompt_cache_key'] == id));
      } finally { await subscription.cancel(); }
    }
    checks['no_fixture_errors'] = peer.errors.isEmpty;
  } finally {
    await nativeSubscription.cancel();
    await client.close();
    await host.close();
    await peer.close();
  }
  return {'scenario': scenario['id'], 'passed': checks.values.every((value) => value), 'checks': checks,
    'fixtureErrors': peer.errors};
}

// This contract deliberately supplies no model_catalog_json. Both real model
// managers discover the endpoint's metadata, including base instructions and
// fields not projected by providers.list. Provider routing is not a prompt test.
Future<Json> catalogDiscovery(String output, List<Json> bundled, CancellationToken cancellation) async {
  final live = [for (final entry in bundled) {
    ...entry, 'default_reasoning_level': 'high', 'context_window': 333000,
    'supports_reasoning_effort_updates': true,
    'model_messages': {...jsonObject(entry['model_messages']),
      'instructions_template': 'DISCOVERED_MODEL_CONTRACT\n${entry['model_messages']['instructions_template']}'},
  }];
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final claims = {'sub': 'synthetic-user', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    'https://api.openai.com/auth': {'chatgpt_plan_type': 'plus', 'chatgpt_account_id': 'synthetic-account'}};
  final token = '${part({'alg': 'none'})}.${part(claims)}.signature';
  final fixture = <String, dynamic>{'discovered_catalog': true, 'discovery_token': token, 'catalog_models': live,
    'responses': [[{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'READY'}]}]]};
  final peer = await responsesPeer(fixture, output, cancellation);
  final home = '$output/home', codexHome = '$output/codex-home', data = '$output/happen-data', cwd = '$output/work';
  for (final path in [home, codexHome, data, cwd]) { await Directory(path).create(recursive: true); }
  final endpoint = 'http://127.0.0.1:${peer.server.port}';
  await File('$codexHome/config.toml').writeAsString('''
model_provider = "catalog-fixture"
chatgpt_base_url = "http://127.0.0.1:${peer.bootstrapPort}/codex"
approval_policy = "never"
sandbox_mode = "danger-full-access"
[skills.bundled]
enabled = false
[features]
multi_agent = false
plugins = false
apps = false
[model_providers.catalog-fixture]
name = "Catalog fixture"
base_url = "$endpoint/codex/backend-api/codex"
requires_openai_auth = true
supports_standalone_web_search = true
supports_websockets = false
''');
  await save('$codexHome/auth.json', {'auth_mode': 'chatgpt',
    'tokens': {'id_token': token, 'access_token': token, 'refresh_token': 'synthetic-refresh', 'account_id': 'synthetic-account'},
    'last_refresh': DateTime.now().toUtc().toIso8601String()});
  await save('$data/auth.json', {'type': 'chatgpt', 'access_token': token, 'refresh_token': 'synthetic-refresh',
    'account_id': 'synthetic-account', 'plan_type': 'plus',
    'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch});
  await save('$data/config.yaml', {});
  final host = await AgentServer.startLocal(directory: data, configPath: '$data/config.yaml', skillsHome: home,
    endpoint: '$endpoint/happen/backend-api/codex/responses', telemetry: false);
  final client = AgentClient.local(host);
  final checks = <String, bool>{};
  try {
    for (final model in supportedGptModels) {
      final expected = live.singleWhere((entry) => entry['slug'] == model);
      await run(['codex', '-C', cwd, 'exec', '--skip-git-repo-check', '--json', '-m', model, 'Reply READY.'],
        isolatedEnvironment(home, codexHome), '$output/$model.jsonl', cancellation);
      final cached = jsonObject(jsonDecode(await File('$codexHome/models_cache.json').readAsString()));
      final reference = jsonObject((cached['models'] as List).singleWhere((entry) => entry['slug'] == model));
      final page = jsonObject(await client.request('thread/start', {'cwd': cwd, 'model': model}).asCancellable(cancellation));
      final config = jsonObject(page['configuration']);
      final actual = jsonObject(config['model_info']);
      // The installed CLI serializes its typed ModelInfo: it drops unknown
      // server fields, fills optional defaults, and selects unified_exec for
      // Code Mode. Compare every shared field; consumed defaults and prompt
      // bytes are independently checked below.
      bool sharedFields(Object? value, Object? cached) {
        if (value is Map && cached is Map) {
          return value.entries.where((entry) => cached.containsKey(entry.key) && entry.key != 'shell_type')
            .every((entry) => sharedFields(entry.value, cached[entry.key]));
        }
        return equals(value).matches(cached, {});
      }
      checks['$model:codex_discovered_metadata'] = sharedFields(expected, reference) && reference['supports_reasoning_effort_updates'] == true;
      checks['$model:happen_discovered_metadata'] = equals(expected).matches(actual, {});
      checks['$model:resolved_defaults'] = config['provider_settings']['reasoning'] == 'high' && config['context_window'] == 316350 &&
        config['reasoning_updates'] == true;
      final request = peer.requests['codex']!.last;
      checks['$model:codex_used_discovered_defaults'] = request['model'] == model && request['reasoning']['effort'] == 'high' &&
        (request['input'] as List).map(jsonObject).any((item) => item['role'] == 'developer' && text(item).contains('DISCOVERED_MODEL_CONTRACT'));
      checks['$model:base_instructions_equal'] = (request['input'] as List).map(jsonObject)
        .any((item) => item['role'] == 'developer' && text(item) == config['instructions']);
    }
    checks['both_catalogs_fetched'] = ['codex', 'happen'].every((engine) => (peer.catalogs[engine] ?? 0) > 0);
    checks['no_fixture_errors'] = peer.errors.isEmpty;
  } finally { await client.close(); await host.close(); await peer.close(); }
  return {'passed': checks.values.every((passed) => passed), 'checks': checks, 'fixtureErrors': peer.errors};
}

void main() {
  const codex = 'codex';
  final catalog = File('${root.path}/packages/openai/catalog/models.json');
  final catalogBytes = catalog.readAsBytesSync();
  final upstream = File('${Platform.environment['CONTEXT_CONTRACT_CODEX_SOURCE']}/codex-rs/models-manager/models.json');
  if (!upstream.existsSync()) throw StateError('The Codex source checkout is required; set CODEX_SOURCE_DIR for moon run test-e2e');
  final upstreamBytes = upstream.readAsBytesSync();
  final modelDefaults = (jsonObject(jsonDecode(utf8.decode(upstreamBytes)))['models'] as List).map(jsonObject).toList();
  final available = modelDefaults.where((entry) => entry['visibility'] == 'list' && entry['supported_in_api'] == true).toList()
    ..sort((a, b) => (a['priority'] as int).compareTo(b['priority'] as int));
  final defaultModel = available.first['slug'] as String;
  final selections = [
    (model: defaultModel, effort: null),
    (model: 'gpt-6.1-sol', effort: 'xhigh'),
    (model: 'gpt-6.1-terra', effort: null),
    for (final model in supportedGptModels.where((id) => id != defaultModel && id != 'gpt-6.1-terra'))
      (model: model, effort: null),
  ];
  final models = selections.map((selection) => selection.model).toSet().toList();
  var output = '';
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  final report = <String, dynamic>{'models': models, 'catalogSHA256': sha256.convert(catalogBytes).toString(),
    'results': <Json>[]};
  setUpAll(() async {
    final isolatedHome = Platform.environment['CONTEXT_CONTRACT_HOME'];
    if (isolatedHome == null || Platform.environment['HOME'] != isolatedHome ||
        Platform.environment['PUB_CACHE'] != '$isolatedHome/.pub-cache') {
      throw StateError('Run moon run test-e2e so real Happen children inherit an isolated environment');
    }
    output = Platform.environment['CONTEXT_CONTRACT_OUTPUT']!;
    await Directory(output).create(recursive: true);
    final env = isolatedEnvironment('$output/home', '$output/codex-home');
    await Directory(env['HOME']!).create(recursive: true);
    await Directory(env['CODEX_HOME']!).create(recursive: true);
    report['codexVersion'] = (await run([codex, '--version'], env, '$output/version.log', cancellation)).trim();
    await File('$output/models.json').writeAsBytes(upstreamBytes, flush: true);
    report['sourceCatalogSHA256'] = sha256.convert(upstreamBytes).toString();
    report['sourceRevision'] = (await run(['git', '-C', upstream.parent.parent.parent.path, 'rev-parse', 'HEAD'],
      env, '$output/source-revision.log', cancellation)).trim();
    report['bundledRevision'] = gptCatalogRevision;
    expect(catalogBytes, upstreamBytes, reason: 'Codex must use its own source catalog, independently of Happen');
    report['embeddedCatalogEqual'] = supportedGptModels.every((model) =>
      equals(modelDefaults.singleWhere((entry) => entry['slug'] == model)).matches(GptModel(model).data, {}));
    expect(report['embeddedCatalogEqual'], isTrue,
      reason: 'The embedded runtime catalog must match models.json, including fields not exercised by the request matrix.');
  });
  tearDownAll(() async {
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
    if (output.isEmpty) return;
    report['passed'] = report['embeddedCatalogEqual'] == true && report['catalogDiscovery']?['passed'] == true &&
      (report['results'] as List).length == selections.length * contextCases.length &&
      (report['results'] as List).every((item) => item['passed'] == true);
    await save('$output/report.json', report);
    print('Context contract evidence: $output/report.json');
  });
  test('discovered catalog matches Codex for every supported model', () async {
    final result = await catalogDiscovery('$output/catalog-discovery', modelDefaults, cancellation);
    report['catalogDiscovery'] = result;
    await save('$output/catalog-discovery/result.json', result);
    expect(result['passed'], isTrue, reason: jsonObject(result['checks']).entries.where((entry) => entry.value != true)
      .map((entry) => entry.key).join(', '));
  });
  for (final selection in selections) {
    final model = selection.model;
    final defaults = modelDefaults.singleWhere((entry) => entry['slug'] == model);
      final reasoning = selection.effort ?? defaults['default_reasoning_level'] as String;
    final reasoningSummary = defaults['default_reasoning_summary'] as String? ?? 'none';
    final codeModeOnly = defaults['tool_mode'] == 'code_mode_only';
    group('$model reasoning=$reasoning code_mode_tool_search=true', () {
      for (final fixture in contextCases) {
        final value = terminalShells({...fixture,
          if (fixture['workflow'] == 'web') ...{
            'messages': [fixture['prompt'], 'Compare hosted and self-hosted tools. Verify their sources again.'],
            'resume_responses': [for (final step in fixture['responses'] as List) [for (final item in (step as List).map(jsonObject)) {
              ...item, if (item['call_id'] != null) 'call_id': 'resumed_${item['call_id']}',
            }]],
          },
          'selected_model': model != defaultModel,
          'selected_reasoning': selection.effort != null,
          if (fixture['id'] == 'compaction') ...{
            'catalog_compaction': true,
            'auto_compact_limit': (defaults['auto_compact_token_limit'] as int? ??
              (defaults['context_window'] as int) * 9 ~/ 10)
              .clamp(1, (defaults['context_window'] as int) * 9 ~/ 10),
          },
        });
        test(fixture['id'] as String, () async {
          final path = '$output/$model/$reasoning/${value['id']}';
          final deadline = TimeoutCancellationToken(const Duration(minutes: 2));
          final lifetime = CancellationToken();
          addTearDown(lifetime.cancel);
          Json result;
          try {
            result = await scenario(value, model, codex, path,
              cancellation.merge(deadline).merge(lifetime), '$output/models.json',
              codeModeOnly: codeModeOnly,
              reasoning: reasoning, reasoningSummary: reasoningSummary);
          } catch (error) {
            result = {'scenario': value['id'], 'model': model, 'passed': false, 'error': error.toString()};
          } finally { deadline.cancel(); }
          result['model'] = model;
          result['reasoning'] = reasoning;
          result['reasoning_summary'] = reasoningSummary;
          result['code_mode'] = true;
          result['code_mode_only'] = codeModeOnly;
          result['code_mode_tool_search'] = true;
          result['use_responses_lite'] = defaults['use_responses_lite'];
          (report['results'] as List).add(result);
          await save('$path/result.json', result);
          final failed = jsonObject(result['checks'] ?? {}).entries.where((entry) => entry.value != true).map((entry) => entry.key).toList();
          expect(result['passed'], isTrue, reason: '${result['error'] ?? failed.join(', ')}\nEvidence: $path/result.json');
        });
      }
    });
  }
}
