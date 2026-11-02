@Tags(['e2e'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:crypto/crypto.dart';
import 'package:openai/openai.dart';
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

/// Ignore transport identity only. Never omit tools, prompts or message boundaries.
Object? canonical(Object? value) {
  if (value is List) return value.map(canonical).toList();
  if (value is Map) {
    final map = Map<String, dynamic>.from(value);
    final item = {'message', 'function_call', 'custom_tool_call',
      'function_call_output', 'custom_tool_call_output', 'reasoning', 'compaction'}.contains(map['type']) ||
      map.containsKey('role') && map.containsKey('content');
    if (item) {
      map.remove('id');
      map.remove('internal_chat_message_metadata_passthrough');
    }
    if ({'custom_tool_call_output', 'function_call_output'}.contains(map['type']) && map['output'] is List) {
      map['output'] = [for (final raw in map['output'] as List) () {
        final part = jsonObject(raw);
        if (part['type'] != 'input_text' || part['text'] is! String) return part;
        final text = part['text'] as String;
        if (RegExp(r'^Script (completed|failed)\nWall time [0-9.]+ seconds\nOutput:\n$').hasMatch(text)) {
          return {...part, 'text': text.replaceFirst(RegExp(r'Wall time [0-9.]+ seconds'), 'Wall time <DURATION> seconds')};
        }
        try {
          final printed = jsonDecode(text);
          if (printed is Map && printed['chunk_id'] is String && printed['wall_time_seconds'] is num && printed['output'] is String) {
            return {...part, 'text': jsonEncode({...printed, 'chunk_id': '<CHUNK_ID>', 'wall_time_seconds': '<DURATION>'})};
          }
        } on FormatException { /* Ordinary printed prose remains byte-for-byte. */ }
        return part;
      }()];
    }
    if (map.containsKey('role') && map.containsKey('content')) {
      map['type'] ??= 'message';
      if (map['content'] is String) {
        map['content'] = [{'type': map['role'] == 'assistant' ? 'output_text' : 'input_text', 'text': map['content']}];
      }
    }
    final keys = map.keys.toList()..sort();
    return {for (final key in keys) key: canonical(map[key])};
  }
  return value;
}

Future<Json> compare(List<Json> reference, List<Json> actual, String path) async {
  final left = canonical(reference), right = canonical(actual);
  await save('$path/codex.json', reference);
  await save('$path/happen.json', actual);
  await save('$path/codex.canonical.json', left);
  await save('$path/happen.canonical.json', right);
  final a = encoder.convert(left).split('\n'), b = encoder.convert(right).split('\n');
  var index = 0;
  while (index < a.length && index < b.length && a[index] == b[index]) { index++; }
  final equal = index == a.length && index == b.length;
  if (!equal) {
    await File('$path/first-difference.txt').writeAsString('Line ${index + 1}\n'
      'Codex: ${index < a.length ? a[index] : '<end>'}\n'
      'Happen: ${index < b.length ? b[index] : '<end>'}\n');
  }
  return {'equal': equal, if (!equal) 'firstDifferentLine': index + 1};
}

Future<({HttpServer server, Future<void> Function() close, Map<String, List<Json>> requests,
  List<String> errors, Map<String, List<int>> loops, Map<String, List<List<int>>> arrivals})>
    responsesPeer(Json scenario, CancellationToken cancellation) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  Future<void>? closing;
  Future<void> close() => closing ??= server.close(force: true);
  final hook = CancellationHook(cancellation, () => unawaited(close()));
  final requests = <String, List<Json>>{}, errors = <String>[];
  final watches = <String, Stopwatch>{}, loops = <String, List<int>>{};
  final arrivals = <String, List<List<int>>>{};
  server.listen((http) async {
    try {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(http).join()));
      final engine = http.uri.pathSegments.first;
      final watch = watches.putIfAbsent(engine, () {
        arrivals.putIfAbsent(engine, () => []).add([]);
        return Stopwatch()..start();
      });
      arrivals[engine]!.last.add(watch.elapsedMicroseconds);
      if (engine == 'happen') {
        final key = scenario['endpoint_key'];
        if (http.headers.value(HttpHeaders.authorizationHeader) != (key == null ? null : 'Bearer $key') ||
            http.headers.value('chatgpt-account-id') != null) {
          throw StateError('Unexpected credentials at the local Responses endpoint');
        }
      }
      final captured = requests.putIfAbsent(engine, () => [])..add(body);
      final completed = {for (final item in (body['input'] as List).map(jsonObject))
        if (['custom_tool_call_output', 'function_call_output'].contains(item['type'])) item['call_id']};
      final steps = scenario['responses'] as List? ?? [[{
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
      final inputTokens = scenario['workflow'] == 'compaction' && !compact && !restored ? 21000 : 100;
      final response = {'id': 'resp_fixture_${captured.length}', 'object': 'response', 'status': 'completed',
        'output': output, 'usage': {'input_tokens': inputTokens, 'output_tokens': 10, 'total_tokens': inputTokens + 10}};
      http.response.headers.contentType = ContentType('text', 'event-stream');
      void event(Json value) => http.response.write('data: ${jsonEncode(value)}\n\n');
      event({'type': 'response.created', 'response': {...response, 'status': 'in_progress', 'output': []}});
      for (var i = 0; i < output.length; i++) {
        event({'type': 'response.output_item.added', 'output_index': i, 'item': output[i]});
        event({'type': 'response.output_item.done', 'output_index': i, 'item': output[i]});
      }
      event({'type': 'response.completed', 'response': response});
      if (output.any((item) => item['type'] == 'message') &&
          output.every((item) => !{'function_call', 'custom_tool_call'}.contains(item['type']))) {
        final watch = watches.remove(engine)!..stop();
        loops.putIfAbsent(engine, () => []).add(watch.elapsedMicroseconds);
      }
    } catch (error) {
      errors.add(error.toString());
      http.response.statusCode = 500;
    } finally { await http.response.close(); }
  });
  return (server: server, close: () async { hook.dispose(); await close(); },
    requests: requests, errors: errors, loops: loops, arrivals: arrivals);
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
  final cwd = '$work/${scenario['cwd'] ?? '.'}';
  await Directory(cwd).create(recursive: true);
  final env = isolatedEnvironment(home, codexHome);
  await run(['git', 'init', '--quiet', work], env, '$output/git.log', cancellation);
  if (scenario['global_instructions'] case final String instructions) {
    for (final path in [codexHome, data]) { await File('$path/AGENTS.md').writeAsString(instructions); }
  }
  final peer = await responsesPeer(jsonObject(jsonDecode(
    jsonEncode(scenario).replaceAll('{{WORK_URI}}', Directory(work).uri.toString()))), cancellation);
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
    'settings': <String, dynamic>{'reasoning': 'low', 'web_search': 'disabled'}}}};
  if (scenario['workflow'] == 'compaction') {
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
  final checks = <String, bool>{};
  final host = await AgentServer.startLocal(directory: data, configPath: '$data/config.yaml', skillsHome: home,
    endpoint: '$endpoint/happen/responses', apiKeyEnv: 'CONTEXT_CONTRACT_UNUSED_${newId()}', telemetry: false);
  final client = AgentClient.local(host);
  try {
    for (var sample = 0; sample <= samples; sample++) {
      final inputs = <String, List<Json>>{};
      for (final engine in sample.isEven ? ['codex', 'happen'] : ['happen', 'codex']) {
        final path = '$output/sample-$sample/$engine';
        if (engine == 'codex') {
          final result = await run([...command, 'debug', 'prompt-input', prompt], codexEnv, '$path/process.log', cancellation);
          if (sample > 0) times[engine]!.add(result.microseconds);
          inputs[engine] = (jsonDecode(result.stdout) as List).map(jsonObject).toList();
        } else {
          final watch = Stopwatch()..start();
          final snapshot = jsonObject(await client.request('debug.prompt-input', {
            'cwd': cwd, 'provider': 'openai', 'model': model, 'prompt': prompt,
          }).asCancellable(cancellation));
          inputs[engine] = gptInput((snapshot['input'] as List).map((item) => ConversationItem.fromJson(jsonObject(item))));
          watch.stop();
          if (sample > 0) times[engine]!.add(watch.elapsedMicroseconds);
        }
      }
      final comparison = await compare(inputs['codex']!, inputs['happen']!, '$output/sample-$sample/initial');
      checks['initial_context_equal:$sample'] = comparison['equal'] == true;
      for (final engine in inputs.keys) {
        final serialized = jsonEncode(inputs[engine]!.take(inputs[engine]!.length - 1).toList());
        checks['$engine:prompt_last:$sample'] = text(inputs[engine]!.last) == prompt;
        for (final marker in scenario['contains'] as List) { checks['$engine:contains:$marker:$sample'] = serialized.contains(marker as String); }
        for (final marker in scenario['absent'] as List) { checks['$engine:absent:$marker:$sample'] = !jsonEncode(inputs[engine]).contains(marker as String); }
        final catalogText = inputs[engine]!.map(text).join('\n');
        final listed = RegExp(r'^- ([^:\n]+):[^\n]*\(file: ', multiLine: true)
          .allMatches(catalogText).map((match) => match[1]!).toSet();
        final expected = (scenario['catalog_skills'] as List? ?? []).cast<String>().toSet();
        checks['$engine:only_fixture_skills:$sample'] = listed.length == expected.length && listed.containsAll(expected);
      }
    }
    final timedLoop = {'skill', 'search', 'compaction'}.contains(scenario['workflow']);
    for (var iteration = 0; iteration < (timedLoop ? samples : 1); iteration++) {
      final runPath = '$output/run-$iteration';
      final starts = {for (final engine in ['codex', 'happen']) engine: peer.requests[engine]?.length ?? 0};
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
        if (engine == 'codex') {
          await run([...command, 'exec', '--json', '--skip-git-repo-check', prompt], codexEnv, '$runPath/$engine.events.jsonl', cancellation);
          if (scenario['workflow'] == 'resume') {
            await run([...command, 'exec', 'resume', '--last', '--json', 'Continue and reply READY.'],
              codexEnv, '$runPath/$engine.resume.jsonl', cancellation);
          }
        } else {
          await turn(prompt);
          if (scenario['workflow'] == 'resume') await turn('Continue and reply READY.');
          await save('$runPath/context.json', await readContextSnapshot(client, taskID!, cancellation: cancellation));
        }
      }
      final a = (peer.requests['codex'] ?? []).skip(starts['codex']!).toList();
      final b = (peer.requests['happen'] ?? []).skip(starts['happen']!).toList();
      await save('$runPath/codex.requests.json', a);
      await save('$runPath/happen.requests.json', b);
      checks['same_model_calls:run-$iteration'] = a.length == b.length && a.isNotEmpty;
      checks['same_selected_model:run-$iteration'] = [...a, ...b].every((request) => request['model'] == model);
      for (var i = 0; i < a.length && i < b.length; i++) {
        await save('$runPath/request-$i/codex.envelope.json', {...a[i]}..remove('input')..remove('prompt_cache_key'));
        await save('$runPath/request-$i/happen.envelope.json', {...b[i]}..remove('input')..remove('prompt_cache_key'));
        final referenceTools = (a[i]['tools'] as List).map(jsonObject).toList();
        final actualTools = (b[i]['tools'] as List).map(jsonObject).toList();
        await save('$runPath/request-$i/tool-discrepancies.json', {
          'missing': referenceTools.map((tool) => tool['name']).toSet().difference(actualTools.map((tool) => tool['name']).toSet()).toList(),
          'extra': actualTools.map((tool) => tool['name']).toSet().difference(referenceTools.map((tool) => tool['name']).toSet()).toList(),
          'changed': [for (final reference in referenceTools)
            for (final actual in actualTools)
              if (reference['name'] == actual['name'] && jsonEncode(canonical(reference)) != jsonEncode(canonical(actual))) reference['name']],
        });
        for (final pair in [('codex', referenceTools), ('happen', actualTools)]) {
          for (final tool in pair.$2.where((tool) => tool['name'] == 'exec')) {
            await File('$runPath/request-$i/${pair.$1}.exec-description.txt').writeAsString(tool['description'] as String);
          }
        }
        final comparison = await compare((a[i]['input'] as List).map(jsonObject).toList(),
          (b[i]['input'] as List).map(jsonObject).toList(), '$runPath/request-$i');
        checks['request_context_equal:$i:run-$iteration'] = comparison['equal'] == true;
        checks['request_envelope_equal:$i:run-$iteration'] = jsonEncode(canonical({...a[i]}..remove('input')..remove('prompt_cache_key')..remove('client_metadata'))) ==
          jsonEncode(canonical({...b[i]}..remove('input')..remove('prompt_cache_key')..remove('client_metadata')));
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
        }
      }
    }
    checks['no_fixture_errors'] = peer.errors.isEmpty;
  } finally {
    await client.close();
    await host.close();
    await save('$output/captured-requests.json', peer.requests);
    await peer.close();
  }
  final referenceTime = median(times['codex']!), actualTime = median(times['happen']!);
  checks['not_slower_than_codex'] = actualTime <= referenceTime;
  if ({'skill', 'search', 'compaction'}.contains(scenario['workflow'])) {
    checks['agent_loop_not_slower_than_codex'] = (peer.loops['codex']?.isNotEmpty ?? false) &&
      (peer.loops['happen']?.isNotEmpty ?? false) && median(peer.loops['happen']!) <= median(peer.loops['codex']!);
  }
  return {'scenario': scenario['id'], 'passed': checks.values.every((value) => value), 'checks': checks,
    'timing': {'unit': 'microseconds', 'codexMeasurement': 'CLI prompt-input wall time',
      'happenMeasurement': 'in-process prompt preparation wall time', 'codex': times['codex'], 'happen': times['happen'],
      'codexMedian': referenceTime, 'happenMedian': actualTime, 'ratio': actualTime / referenceTime,
      'agentLoopMeasurement': 'first model request through final synthetic SSE', 'agentLoop': peer.loops,
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
    output = '${root.path}/.local/context-contract/${DateTime.now().microsecondsSinceEpoch}';
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
