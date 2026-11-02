@Tags(['e2e'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

import '../fixtures/context_contract/cases.dart';
import '../fixtures/context_contract/environment.dart';

final root = Directory.current.absolute;
final fixtures = Directory('${root.path}/test/fixtures/context_contract');
const encoder = JsonEncoder.withIndent('  ');

Future<void> save(String path, Object? value) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString('${encoder.convert(value)}\n');
}

Future<({String stdout, int microseconds})> run(List<String> command, Map<String, String> environment,
  String log, CancellationToken cancellation, {String? cwd, Duration timeout = const Duration(minutes: 2)}) async {
  cancellation.throwIfCancelled();
  await File(log).parent.create(recursive: true);
  final watch = Stopwatch()..start();
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
    watch.stop();
    await streams.asCancellable(token);
    if (code != 0) throw StateError('${command.first} exited $code; see $log and $log.stderr');
    await out.flush();
    return (stdout: await File(log).readAsString(), microseconds: watch.elapsedMicroseconds);
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
  : (item['content'] as List? ?? []).whereType<Map>().map((part) => part['text'] ?? '').join('\n');

/// One shared preparation for every case: remove scoped IDs and extract known
/// timings. No other fields, encodings, values or array positions are changed.
({Json request, List<Json> timings}) prepareComparison(Json received) {
  final request = jsonObject(jsonDecode(jsonEncode(received)));
  final timings = <Json>[];
  void takeTime(Json object, String key, String path, String kind, String unit) {
    final value = object[key];
    if (value is! num || !value.isFinite || value < 0) return;
    object.remove(key);
    timings.add({'path': '$path.$key', 'kind': kind, 'unit': unit, 'value': value});
  }
  void ids(Json object, List<String> keys) { for (final key in keys) { object.remove(key); } }
  request.remove('prompt_cache_key');
  if (request['client_metadata'] is Map) {
    final metadata = request['client_metadata'] as Json;
    ids(metadata, ['x-codex-installation-id', 'turn_id', 'thread_id', 'session_id',
      'root_turn_id', 'parent_turn_id', 'x-codex-window-id']);
    if (metadata['x-codex-turn-metadata'] case final String encoded) {
      final turn = jsonObject(jsonDecode(encoded));
      ids(turn, ['installation_id', 'session_id', 'thread_id', 'turn_id', 'window_id',
        'context_window_id', 'root_turn_id', 'parent_turn_id']);
      takeTime(turn, 'turn_started_at_unix_ms', 'client_metadata.x-codex-turn-metadata', 'timestamp', 'milliseconds');
      metadata['x-codex-turn-metadata'] = jsonEncode(turn);
    }
  }
  String outputText(String text, String path) {
    final status = RegExp(r'^Script (completed|failed|terminated|running with cell ID [1-9][0-9]*)\nWall time ([0-9.]+) seconds\nOutput:\n$').firstMatch(text);
    if (status != null) {
      timings.add({'path': path, 'kind': 'script', 'unit': 'seconds', 'value': double.parse(status[2]!)});
      return text.replaceFirst('Wall time ${status[2]} seconds', 'Wall time <ELAPSED> seconds');
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['chunk_id'] is String && decoded['wall_time_seconds'] is num && decoded['output'] is String) {
        final printed = jsonObject(decoded);
        printed.remove('chunk_id');
        if (printed['session_id'] is int) printed.remove('session_id');
        takeTime(printed, 'wall_time_seconds', path, 'shell', 'seconds');
        return jsonEncode(printed);
      }
    } on FormatException { /* Ordinary tool prose is preserved byte-for-byte. */ }
    return text;
  }
  final input = request['input'] as List;
  for (var index = 0; index < input.length; index++) {
    final item = input[index] as Json, path = 'input[$index]';
    item.remove('id');
    if (item['internal_chat_message_metadata_passthrough'] is Map) {
      final metadata = item['internal_chat_message_metadata_passthrough'] as Json;
      metadata.remove('turn_id');
      takeTime(metadata, 'create_time', '$path.internal_chat_message_metadata_passthrough', 'timestamp', 'seconds');
    }
    if (!{'custom_tool_call_output', 'function_call_output'}.contains(item['type'])) continue;
    if (item['output'] case final String output) { item['output'] = outputText(output, '$path.output'); }
    else if (item['output'] case final List output) {
      for (var part = 0; part < output.length; part++) {
        if (output[part]['type'] == 'input_text') output[part]['text'] = outputText(output[part]['text'] as String, '$path.output[$part].text');
      }
    }
  }
  return (request: request, timings: timings);
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

String baseInstructionId(String thread, String instructions) {
  // Independent RFC 9562 v5 derivation from Codex client.rs. The provider's
  // renderer is deliberately not used to produce the expected identity.
  List<int> hash(List<int> namespace, String name) {
    final bytes = sha1.convert([...namespace, ...utf8.encode(name)]).bytes.take(16).toList();
    bytes[6] = (bytes[6] & 15) | 0x50; bytes[8] = (bytes[8] & 63) | 0x80;
    return bytes;
  }
  const oid = [0x6b, 0xa7, 0xb8, 0x12, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8];
  final value = hash(hash(oid, thread), instructions).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return 'msg_${value.substring(0, 8)}-${value.substring(8, 12)}-${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}';
}

bool itemIdContract(List<Json> items, {String? thread, Map<String, String> modelIds = const {}}) {
  const prefixes = {'message': 'msg', 'reasoning': 'rs', 'function_call': 'fc', 'custom_tool_call': 'ctc',
    'function_call_output': 'fco', 'custom_tool_call_output': 'ctco', 'compaction': 'cmp'};
  final seen = <String>{};
  for (var index = 0; index < items.length; index++) {
    final item = items[index], kind = item['type'] ?? (item.containsKey('role') ? 'message' : null);
    final prefix = prefixes[kind];
    if (prefix == null) continue;
    final id = item['id'];
    if (id is! String || !seen.add(id)) return false;
    if (modelIds[id] == kind) continue; // Preserve IDs actually emitted by the synthetic upstream.
    if (index == 0 && thread != null && item['role'] == 'developer') {
      if (id != baseInstructionId(thread, text(item))) return false;
    } else if (!id.startsWith('${prefix}_') || !uuid7(id.substring(prefix.length + 1))) { return false; }
  }
  return true;
}

bool shellIdContract(List<Json> input) {
  for (final item in input.where((item) => {'function_call_output', 'custom_tool_call_output'}.contains(item['type']))) {
    for (final part in item['output'] is List ? (item['output'] as List).whereType<Map>() : const <Map>[]) {
      try {
        final value = jsonDecode(part['text'] as String? ?? '');
        if (value is! Map || !value.containsKey('chunk_id') || !value.containsKey('wall_time_seconds')) continue;
        if (value['chunk_id'] is! String || !RegExp(r'^[0-9a-f]{6}$').hasMatch(value['chunk_id'] as String)) return false;
        if (value.containsKey('session_id') && (value['session_id'] is! int || value['session_id'] < 1000 || value['session_id'] >= 100000)) return false;
      } on FormatException { /* Non-JSON prose. */ }
    }
  }
  return true;
}

Future<({bool equal, Json timings})> compare(Json reference, Json actual, String path) async {
  final left = prepareComparison(reference), right = prepareComparison(actual);
  final equal = equals(left.request).matches(right.request, {});
  final a = encoder.convert(sortedKeys(left.request)).split('\n'), b = encoder.convert(sortedKeys(right.request)).split('\n');
  var index = 0;
  while (index < a.length && index < b.length && a[index] == b[index]) { index++; }
  if (!equal) {
    await Directory(path).create(recursive: true);
    await File('$path/first-difference.txt').writeAsString('Line ${index + 1}\n'
      'Codex: ${index < a.length ? a[index] : '<end>'}\n'
      'Happen: ${index < b.length ? b[index] : '<end>'}\n');
  }
  return (equal: equal, timings: {'codex': left.timings, 'happen': right.timings});
}

Future<({HttpServer server, Future<void> Function() close, Map<String, List<Json>> requests,
  Map<String, List<String>> files, List<String> errors, Map<String, List<int>> loops,
  Map<String, List<List<int>>> arrivals, Map<String, Map<String, String>> modelIds})>
    responsesPeer(Json scenario, String outputPath, CancellationToken cancellation) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  Future<void>? closing;
  Future<void> close() => closing ??= server.close(force: true);
  final hook = CancellationHook(cancellation, () => unawaited(close()));
  final requests = <String, List<Json>>{}, errors = <String>[];
  final files = <String, List<String>>{};
  for (final engine in ['codex', 'happen']) { await Directory('$outputPath/$engine-requests').create(recursive: true); }
  final watches = <String, Stopwatch>{}, loops = <String, List<int>>{};
  final arrivals = <String, List<List<int>>>{};
  final currentArrivals = <String, List<int>>{};
  final modelIds = <String, Map<String, String>>{};
  server.listen((http) async {
    try {
      final chunks = await http.fold<BytesBuilder>(BytesBuilder(copy: false), (buffer, chunk) => buffer..add(chunk));
      final bytes = chunks.takeBytes();
      final body = jsonObject(jsonDecode(utf8.decode(bytes)));
      final engine = http.uri.pathSegments.first;
      final clock = '$engine:${body['prompt_cache_key']}';
      final watch = watches.putIfAbsent(clock, () {
        final samples = currentArrivals[clock] = <int>[];
        arrivals.putIfAbsent(engine, () => []).add(samples);
        return Stopwatch()..start();
      });
      currentArrivals[clock]!.add(watch.elapsedMicroseconds);
      if (engine == 'happen') {
        final key = scenario['endpoint_key'];
        if (http.headers.value(HttpHeaders.authorizationHeader) != (key == null ? null : 'Bearer $key') ||
            http.headers.value('chatgpt-account-id') != null) {
          throw StateError('Unexpected credentials at the local Responses endpoint');
        }
      }
      final captured = requests.putIfAbsent(engine, () => [])..add(body);
      // The endpoint owns the single authoritative capture for both harnesses.
      // Save the received bytes, never a re-encoded or reconstructed body.
      final file = File('$outputPath/$engine-requests/${captured.length.toString().padLeft(6, '0')}.json');
      await file.writeAsBytes(bytes, flush: true);
      files.putIfAbsent(engine, () => []).add(file.path);
      final completed = {for (final item in (body['input'] as List).map(jsonObject))
        if (['custom_tool_call_output', 'function_call_output'].contains(item['type'])) item['call_id']};
      final messages = scenario['messages'] as List? ?? [];
      final prelude = messages.length > 1 && messages.take(messages.length - 1).contains(text(jsonObject((body['input'] as List).last)));
      final steps = (prelude ? null : scenario['responses'] as List?) ?? [[{
        'type': 'message', 'role': 'assistant',
        'content': [{'type': 'output_text', 'text': 'READY', 'annotations': []}],
      }]];
      var step = 0;
      while (step + 1 < steps.length) {
        final expected = {for (final item in (steps[step] as List).map(jsonObject))
          if (['custom_tool_call', 'function_call'].contains(item['type'])) item['call_id']};
        if (expected.isEmpty || !completed.containsAll(expected)) break;
        step++;
      }
      final compact = (body['input'] as List).last['type'] == 'compaction_trigger';
      final restored = (body['input'] as List).any((item) => item['type'] == 'compaction');
      if (scenario['workflow'] == 'compaction' && restored) step = steps.length - 1;
      final output = [for (var i = 0; i < (steps[step] as List).length; i++) {
        'id': 'fixture_item_${captured.length}_$i', 'status': 'completed', ...jsonObject(steps[step][i]),
      }];
      if (compact) {
        output.clear();
        output.add({'type': 'compaction', 'encrypted_content': 'context-contract-native-checkpoint'});
      }
      for (final item in output) {
        if (item['id'] case final String id) (modelIds[engine] ??= {})[id] = item['type'] as String;
      }
      final inputTokens = scenario['workflow'] == 'compaction' && !prelude && !compact && !restored ? 21000 : 100;
      final response = {'id': 'resp_fixture_${captured.length}', 'object': 'response', 'status': 'completed',
        'output': output, 'usage': {'input_tokens': inputTokens, 'output_tokens': 10, 'total_tokens': inputTokens + 10}};
      final stream = StringBuffer();
      void event(Json value) => stream.write('data: ${jsonEncode(value)}\n\n');
      event({'type': 'response.created', 'response': {...response, 'status': 'in_progress', 'output': []}});
      for (var i = 0; i < output.length; i++) {
        event({'type': 'response.output_item.added', 'output_index': i, 'item': output[i]});
        event({'type': 'response.output_item.done', 'output_index': i, 'item': output[i]});
      }
      event({'type': 'response.completed', 'response': response});
      http.response.headers.contentType = ContentType('text', 'event-stream');
      http.response.write(stream.toString());
      if (output.any((item) => item['type'] == 'message') &&
          output.every((item) => !{'function_call', 'custom_tool_call'}.contains(item['type']))) {
        final watch = watches.remove(clock)!..stop();
        currentArrivals.remove(clock);
        loops.putIfAbsent(engine, () => []).add(watch.elapsedMicroseconds);
      }
    } catch (error, stack) {
      errors.add('$error\n$stack');
      await File('$outputPath/peer-errors.log').writeAsString('$error\n$stack\n', mode: FileMode.append);
      try { http.response.statusCode = 500; } on StateError { /* Preserve the primary error after a peer disconnect. */ }
    } finally { await http.response.close(); }
  });
  return (server: server, close: () async { hook.dispose(); await close(); },
    requests: requests, files: files, errors: errors, loops: loops, arrivals: arrivals, modelIds: modelIds);
}

double median(List<int> values) {
  final sorted = values.toList()..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[middle].toDouble() : (sorted[middle - 1] + sorted[middle]) / 2;
}

Future<Json> scenario(Json scenario, String model, String codex, String output, int samples,
  CancellationToken cancellation, String catalog) async {
  final work = '$output/work', home = '$output/home', codexHome = '$output/codex-home', data = '$output/happen-data';
  for (final path in [work, home, codexHome, data]) { await Directory(path).create(recursive: true); }
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
  final peer = await responsesPeer(jsonObject(jsonDecode(
    jsonEncode(scenario).replaceAll('{{WORK_URI}}', Directory(work).uri.toString()))), output, cancellation);
  final endpoint = 'http://127.0.0.1:${peer.server.port}';
  final config = StringBuffer('''
model = "$model"
model_catalog_json = ${jsonEncode(catalog)}
model_provider = "context_contract"
model_reasoning_effort = "low"
web_search = "disabled"
approval_policy = "never"
sandbox_mode = "danger-full-access"
cli_auth_credentials_store = "file"
mcp_oauth_credentials_store = "file"
include_permissions_instructions = false
include_apps_instructions = false
include_collaboration_mode_instructions = false
mcp_optional_startup_grace_ms = 0
[agents]
enabled = false
[skills.bundled]
enabled = false
[tools.experimental_request_user_input]
enabled = false
[features]
code_mode = true
code_mode_only = true
code_mode_tool_search = true
deferred_tool_world_state = true
incremental_tools = true
multi_agent = false
multi_agent_v2 = false
sleep_tool = false
memories = false
goals = false
plugins = false
apps = false
shell_snapshot = false
[model_providers.context_contract]
name = "Context contract"
base_url = "$endpoint/codex"
wire_api = "responses"
env_key = "CONTEXT_CONTRACT_KEY"
[model_providers.context_contract.capabilities]
remote_compaction = "v2"
''');
  final happenConfig = <String, dynamic>{'providers': {'openai': {'model': model,
    'settings': <String, dynamic>{'reasoning': 'low', 'reasoning_summary': 'none', 'web_search': 'disabled'}}}};
  if ({'compaction', 'audio'}.contains(scenario['workflow'])) {
    final text = config.toString();
    config.clear();
    config.write('model_context_window = 100000\nmodel_auto_compact_token_limit = 20000\n$text');
    happenConfig['providers']['openai']['settings'].addAll({'context_limit': 100000, 'compaction_headroom': 80000});
  }
  if (scenario['mcp'] == true) {
    final mcp = {'command': 'dart', 'args': ['mcp-server'], 'env': env};
    config.writeln('[mcp_servers.dart]\ncommand = ${jsonEncode(mcp['command'])}\nargs = ${jsonEncode(mcp['args'])}\nrequired = true\ndefault_tools_approval_mode = "approve"');
    config.writeln('[mcp_servers.dart.env]');
    for (final entry in env.entries) { config.writeln('${entry.key} = ${jsonEncode(entry.value)}'); }
    happenConfig['mcp_servers'] = {'dart': mcp};
    await run(['dart', 'pub', 'get', '--offline'], env, '$output/pub-get.log', cancellation, cwd: work);
    // This SDK delegates mcp-server to a remote package. Prepare its real
    // executable before either harness starts, avoiding simultaneous first-use
    // installs in the shared isolated cache. Every measured process is fresh.
    await run(['dart', 'mcp-server', '--help'], env, '$output/mcp-prepare.log', cancellation, cwd: work);
  }
  await File('$codexHome/config.toml').writeAsString(config.toString());
  await save('$data/config.yaml', happenConfig);
  final codexEnv = {...env, 'CONTEXT_CONTRACT_KEY': 'synthetic-context-contract'};
  final prompt = scenario['prompt'] as String;
  final command = [codex, '-C', cwd];
  final times = {'codex': <int>[], 'happen': <int>[]};
  final loopTimes = {'codex': <int>[], 'happen': <int>[]};
  final requestTimings = <Json>[];
  final checks = <String, bool>{};
  final host = await AgentServer.startLocal(directory: data, configPath: '$data/config.yaml', skillsHome: home,
    endpoint: '$endpoint/happen/responses', apiKeyEnv: 'CONTEXT_CONTRACT_UNUSED_${newId()}', telemetry: false);
  final client = AgentClient.local(host);
  try {
    final timedLoop = {'skill', 'search', 'compaction', 'shell', 'image', 'audio'}.contains(scenario['workflow']);
    for (var iteration = -1; iteration < samples; iteration++) {
      final runPath = '$output/run-${iteration < 0 ? 'warmup' : iteration}';
      final starts = {for (final engine in ['codex', 'happen']) engine: peer.requests[engine]?.length ?? 0};
      final loopStarts = {for (final engine in ['codex', 'happen']) engine: peer.loops[engine]?.length ?? 0};
      String? taskID;
      Future<void> turn(String prompt) async {
        final terminal = client.events.stream.firstWhere((event) =>
          ['session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted'].contains(event['type'])).asCancellable(cancellation);
        final admitted = jsonObject(await client.request(taskID == null ? 'session.create' : 'session.prompt', {
          if (taskID == null) ...{'cwd': cwd, 'provider': 'openai', 'model': model} else 'sessionID': taskID,
          'prompt': prompt,
        }).asCancellable(cancellation));
        taskID = admitted['sessionID'] as String;
        final completed = await terminal;
        if (completed['type'] != 'session.execution.succeeded') throw StateError('Agent turn failed: ${completed['data']}');
      }
      for (final engine in iteration.isEven ? ['codex', 'happen'] : ['happen', 'codex']) {
        final watch = Stopwatch()..start();
        final messages = (scenario['messages'] as List? ?? [prompt,
          if (scenario['workflow'] == 'resume') 'Continue and reply READY.']).cast<String>();
        for (var message = 0; message < messages.length; message++) {
          if (engine == 'codex') {
            await run([...command, 'exec',
              if (message == 0) '--skip-git-repo-check' else ...['resume', '--last'],
              '--json', messages[message]], codexEnv, '$runPath/$engine.message-$message.jsonl', cancellation);
          } else {
            await turn(messages[message]);
          }
        }
        watch.stop();
        if (iteration >= 0) times[engine]!.add(watch.elapsedMicroseconds);
      }
      final a = (peer.requests['codex'] ?? []).skip(starts['codex']!).toList();
      final b = (peer.requests['happen'] ?? []).skip(starts['happen']!).toList();
      await save('$runPath/received-request-files.json', {
        for (final engine in ['codex', 'happen']) engine: (peer.files[engine] ?? []).skip(starts[engine]!).toList(),
      });
      if (iteration >= 0) {
        for (final engine in ['codex', 'happen']) {
          final observed = (peer.loops[engine] ?? []).skip(loopStarts[engine]!).toList();
          if (observed.isNotEmpty) loopTimes[engine]!.add(observed.last);
        }
      }
      checks['same_model_calls:run-$iteration'] = a.length == b.length && a.isNotEmpty;
      checks['same_selected_model:run-$iteration'] = [...a, ...b].every((request) => request['model'] == model);
      if (a.isNotEmpty && b.isNotEmpty) {
        final comparison = await compare(a.last, b.last, runPath);
        checks['final_request_equal:run-$iteration'] = comparison.equal;
        requestTimings.add({'run': iteration, ...comparison.timings});
      } else { checks['final_request_equal:run-$iteration'] = false; }
      for (final pair in [('codex', a), ('happen', b)]) {
        checks['${pair.$1}:thread_id_contract:run-$iteration'] = pair.$2.isNotEmpty &&
          pair.$2.every((request) => uuid7(request['prompt_cache_key']) && request['prompt_cache_key'] == pair.$2.first['prompt_cache_key']);
        final input = pair.$2.isEmpty ? <Json>[] : (pair.$2.first['input'] as List).map(jsonObject).toList();
        final serialized = jsonEncode(input.isEmpty ? [] : input.take(input.length - 1).toList());
        checks['${pair.$1}:prompt_last:run-$iteration'] = input.isNotEmpty && text(input.last) == prompt;
        for (final marker in scenario['contains'] as List) { checks['${pair.$1}:contains:$marker:run-$iteration'] = serialized.contains(marker as String); }
        for (final marker in scenario['absent'] as List) { checks['${pair.$1}:absent:$marker:run-$iteration'] = !jsonEncode(input).contains(marker as String); }
        final listed = RegExp(r'^- ([^:\n]+):[^\n]*\(file: ', multiLine: true)
          .allMatches(input.map(text).join('\n')).map((match) => match[1]!).toSet();
        final expected = (scenario['catalog_skills'] as List? ?? []).cast<String>().toSet();
        checks['${pair.$1}:only_fixture_skills:run-$iteration'] = listed.length == expected.length && listed.containsAll(expected);
      }
      checks['happen:admitted_thread_id:run-$iteration'] = b.isNotEmpty && b.first['prompt_cache_key'] == taskID;
      for (var i = 0; i < a.length && i < b.length; i++) {
        for (final pair in [('codex', a[i]), ('happen', b[i])]) {
          final items = (pair.$2['input'] as List).map(jsonObject).toList();
          checks['${pair.$1}:request_item_id_contract:$i:run-$iteration'] = itemIdContract(items,
            thread: pair.$2['prompt_cache_key'] as String?, modelIds: peer.modelIds[pair.$1] ?? {});
          checks['${pair.$1}:shell_id_contract:$i:run-$iteration'] = shellIdContract(items);
        }
        final referenceTools = (a[i]['tools'] as List).map(jsonObject).toList();
        final actualTools = (b[i]['tools'] as List).map(jsonObject).toList();
        final referenceExec = referenceTools.where((tool) => tool['name'] == 'exec').firstOrNull;
        final actualExec = actualTools.where((tool) => tool['name'] == 'exec').firstOrNull;
        const nestedMarker = 'Shared MCP Types:';
        String? nested(Json? tool) {
          final description = tool?['description'] as String? ?? '';
          final start = description.indexOf(nestedMarker);
          return start < 0 ? null : description.substring(start);
        }
        checks['nested_tool_context_equal:$i:run-$iteration'] = nested(referenceExec) != null && nested(referenceExec) == nested(actualExec);
        checks['codex_parallel_tool_calls:$i:run-$iteration'] = a[i]['parallel_tool_calls'] == true;
        checks['happen_parallel_tool_calls:$i:run-$iteration'] = b[i]['parallel_tool_calls'] == true;
        checks['standard_reasoning_context:$i:run-$iteration'] = !jsonObject(a[i]['reasoning']).containsKey('context') &&
          !jsonObject(b[i]['reasoning']).containsKey('context');
        if (scenario['mcp'] == true) {
          for (final entry in {'codex': a[i], 'happen': b[i]}.entries) {
            checks['${entry.key}:discovery_declared:$i:run-$iteration'] = jsonEncode(entry.value['tools']).contains('tools.tool_search');
          }
        }
      }
      if (scenario['result'] case final String marker) {
        for (final engine in ['codex', 'happen']) {
          final requests = engine == 'codex' ? a : b;
          checks['$engine:tool_result_delivered:run-$iteration'] = requests.length > 1 && (requests.last['input'] as List).map(jsonObject)
            .where((item) => ['custom_tool_call_output', 'function_call_output'].contains(item['type']))
            .any((item) => jsonEncode(item).contains(marker));
        }
      }
      if (scenario['workflow'] == 'image') {
        for (final pair in [('codex', a), ('happen', b)]) {
          final outputs = pair.$2.isEmpty ? <Json>[] : (pair.$2.last['input'] as List).map(jsonObject)
            .where((item) => item['type'] == 'custom_tool_call_output' && item['call_id'] == 'image_result').toList();
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
            .where((item) => item['type'] == 'custom_tool_call_output' && item['call_id'] == 'audio_result').toList();
          final parts = outputs.length == 1 && outputs.single['output'] is List
            ? (outputs.single['output'] as List).map(jsonObject).toList() : <Json>[];
          checks['${pair.$1}:recorded_audio_content_order:run-$iteration'] =
            jsonEncode(parts.map((part) => part['type']).toList()) == jsonEncode(['input_text', 'input_text', 'input_text', 'input_text']) &&
            parts[1]['text'] == 'audio-before' && parts[2]['text'] == 'audio content omitted because you do not support audio input' &&
            parts[3]['text'] == 'audio-after';
          checks['${pair.$1}:audio_bytes_not_counted_as_prose:run-$iteration'] = pair.$2.length == 2 &&
            pair.$2.every((request) => (request['input'] as List).last['type'] != 'compaction_trigger');
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
          if (scenario['messages'] case final List messages) {
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
            .where((item) => item['type'] == 'custom_tool_call_output' && item['call_id'] == discovery.key).toList();
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
          if (expected['names'] case final List names) {
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
    if (timedLoop) {
      checks['agent_loop_not_slower_than_codex'] = loopTimes.values.every((times) => times.isNotEmpty) &&
        median(loopTimes['happen']!) <= median(loopTimes['codex']!);
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
        if (event['type'] == 'session.execution.succeeded') {
          completed.add(requiredString(jsonObject(event['data']), 'sessionID'));
          if (completed.length == 16 && !done.isCompleted) done.complete();
        } else if ({'session.execution.failed', 'session.execution.interrupted'}.contains(event['type']) && !done.isCompleted) {
          done.completeError(StateError('Concurrent turn failed: $event'));
        }
      });
      try {
        final admitted = await Future.wait(List.generate(16, (_) => client.request('session.create', {
          'cwd': cwd, 'provider': 'openai', 'model': model, 'prompt': prompt,
        }).asCancellable(cancellation)));
        await done.future.asCancellable(cancellation);
        final ids = admitted.map((value) => jsonObject(value)['sessionID']).toList();
        checks['happen:concurrent_thread_ids_uuid7'] = ids.every(uuid7);
        checks['happen:concurrent_thread_ids_unique'] = ids.toSet().length == ids.length;
        checks['happen:concurrent_thread_ids_monotonic'] = [for (var i = 1; i < ids.length; i++)
          (ids[i - 1] as String).compareTo(ids[i] as String) < 0].every((value) => value);
        checks['happen:concurrent_threads_reached_inference'] = ids.every((id) =>
          peer.requests['happen']!.any((request) => request['prompt_cache_key'] == id));
      } finally { await subscription.cancel(); }
    }
    checks['no_fixture_errors'] = peer.errors.isEmpty;
  } finally {
    await client.close();
    await host.close();
    await peer.close();
  }
  final referenceTime = median(times['codex']!), actualTime = median(times['happen']!);
  checks['not_slower_than_codex'] = actualTime <= referenceTime;
  return {'scenario': scenario['id'], 'passed': checks.values.every((value) => value), 'checks': checks,
    'timing': {'unit': 'microseconds', 'codexMeasurement': 'CLI exec/resume session wall time',
      'happenMeasurement': 'in-process real session wall time', 'codex': times['codex'], 'happen': times['happen'],
      'codexMedian': referenceTime, 'happenMedian': actualTime, 'ratio': actualTime / referenceTime,
      'fasterHarness': actualTime == referenceTime ? 'equal' : actualTime < referenceTime ? 'happen' : 'codex',
      'differenceMicroseconds': (actualTime - referenceTime).abs(), 'requestTimings': requestTimings,
      'agentLoopMeasurement': 'last turn: first model request through final synthetic SSE', 'agentLoop': loopTimes,
      'allObservedAgentLoops': peer.loops,
      'warmupAgentLoop': {for (final engine in peer.loops.keys) engine: peer.loops[engine]!.first},
      'requestArrivals': peer.arrivals}, 'fixtureErrors': peer.errors};
}

void main() {
  const models = ['gpt-6.1-sol', 'gpt-6-sol'];
  const samples = 3;
  const codex = 'codex';
  var output = '';
  late File catalog;
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  final report = <String, dynamic>{'models': models, 'results': <Json>[]};
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
    report['codexVersion'] = (await run([codex, '--version'], env, '$output/version.log', cancellation)).stdout.trim();
    final bundled = File('${root.path}/packages/openai/catalog/models.json');
    report['baseCatalogSHA256'] = sha256.convert(await bundled.readAsBytes()).toString();
    final fastCatalog = jsonObject(jsonDecode(await bundled.readAsString()));
    for (final row in fastCatalog['models'] as List) { row['use_responses_lite'] = false; }
    catalog = File('$output/models.json');
    await save(catalog.path, fastCatalog);
    report['protocolOverrides'] = {'use_responses_lite': false};
    report['catalogSHA256'] = sha256.convert(await catalog.readAsBytes()).toString();
  });
  tearDownAll(() async {
    cancellation.cancel();
    for (final signal in signals) { await signal.cancel(); }
    if (output.isEmpty) return;
    report['passed'] = (report['results'] as List).length == models.length * contextCases.length &&
      (report['results'] as List).every((item) => item['passed'] == true);
    await save('$output/report.json', report);
    print('Context contract evidence: $output/report.json');
  });
  for (final model in models) {
    group(model, () {
      for (final value in contextCases) {
        test(value['id'] as String, () async {
          final path = '$output/$model/${value['id']}';
          final deadline = TimeoutCancellationToken(const Duration(minutes: 2));
          final lifetime = CancellationToken();
          addTearDown(lifetime.cancel);
          Json result;
          try {
            result = await scenario(value, model, codex, path, samples,
              cancellation.merge(deadline).merge(lifetime), catalog.absolute.path);
          } catch (error) {
            result = {'scenario': value['id'], 'model': model, 'passed': false, 'error': error.toString()};
          } finally { deadline.cancel(); }
          result['model'] = model;
          (report['results'] as List).add(result);
          await save('$path/result.json', result);
          final failed = jsonObject(result['checks'] ?? {}).entries.where((entry) => entry.value != true).map((entry) => entry.key).toList();
          expect(result['passed'], isTrue, reason: '${result['error'] ?? failed.join(', ')}\nEvidence: $path/result.json');
        });
      }
    });
  }
}
