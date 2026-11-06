import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Run with tool/test_isolated.dart: this probe changes only that disposable
// source snapshot while a real writer remains alive across VM hot reload.
Future<void> main(List<String> arguments) async {
  final source = Platform.environment['HAPPEN_TEST_REPORT_ROOT'];
  final workspace = Directory.current;
  if (source == null || workspace.resolveSymbolicLinksSync() == Directory(source).resolveSymbolicLinksSync()) {
    throw StateError('Run through tool/test_isolated.dart');
  }
  final ownerFile = File('${workspace.path}/packages/storage/lib/src/owner.dart');
  final lifecycleFile = File('${workspace.path}/packages/storage/lib/src/lifecycle.dart');
  final ownerSource = await ownerFile.readAsString(), lifecycleSource = await lifecycleFile.readAsString();
  var dispatch = ownerSource;
  if (arguments.contains('--inline-loop')) {
    // Control: restore dispatch inside the suspended loop to reproduce the bug.
    final helper = dispatch.indexOf('// Enter a fresh handler');
    final body = dispatch.substring(dispatch.indexOf('  if (store != null', helper), dispatch.lastIndexOf('\n}'))
      .replaceFirst('  return switch (method)', '  final result = switch (method)');
    dispatch = dispatch.substring(0, helper).replaceFirst(
      "final result = await _storeRequest(store, requiredString(request, 'method'), params, cancellation);",
      "final method = requiredString(request, 'method');\n$body",
    );
  }
  final initialOwner = dispatch.replaceFirst("configuration: params['configuration'] as Json?,",
    "configuration: params['configuration'] as Json?, reloadSentinel: 0,");
  final initialLifecycle = lifecycleSource.replaceFirst('Json? configuration,', 'Json? configuration, int? reloadSentinel,');
  if (initialOwner == dispatch || initialLifecycle == lifecycleSource) throw StateError('Fork signature not found');
  final fixture = File('${workspace.path}/store_reload_fixture.dart');
  Process? child;
  WebSocket? socket;
  StreamIterator<String>? output;
  StreamIterator<dynamic>? replies;
  StreamSubscription<String>? errors;
  final stderrText = StringBuffer();
  try {
    await ownerFile.writeAsString(initialOwner);
    await lifecycleFile.writeAsString(initialLifecycle);
    await fixture.writeAsString(_fixture);
    child = await Process.start(Platform.resolvedExecutable,
      ['--enable-vm-service=0', '--disable-service-auth-codes', 'run', fixture.path], workingDirectory: workspace.path);
    errors = child.stderr.transform(utf8.decoder).listen((text) {
      if (stderrText.length < 8192) stderrText.write(text);
    });
    final lines = StreamIterator(child.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    output = lines;
    Future<Map<String, dynamic>> next() async {
      while (await lines.moveNext().timeout(const Duration(seconds: 45))) {
        if (lines.current.startsWith('{')) return jsonDecode(lines.current) as Map<String, dynamic>;
      }
      throw StateError('Probe exited: $stderrText');
    }
    final ready = await next();
    final http = Uri.parse(ready['service'] as String);
    socket = await WebSocket.connect(http.replace(scheme: 'ws', path: '${http.path}ws').toString());
    final responses = StreamIterator(socket);
    replies = responses;
    var request = 0;
    Future<Map<String, dynamic>> rpc(String method, [Map<String, dynamic> params = const {}]) async {
      final id = ++request;
      socket!.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
      while (await responses.moveNext().timeout(const Duration(seconds: 45))) {
        final reply = jsonDecode(responses.current as String) as Map<String, dynamic>;
        if (reply['id'] != id) continue;
        if (reply['error'] != null) throw StateError('${reply['error']}');
        return reply['result'] as Map<String, dynamic>;
      }
      throw StateError('VM service closed');
    }
    // Remove an argument after the writer has already entered its mailbox.
    await ownerFile.writeAsString(dispatch);
    await lifecycleFile.writeAsString(lifecycleSource);
    final vm = await rpc('getVM');
    final reload = await rpc('reloadSources', {'isolateId': vm['isolates'][0]['id'], 'force': true});
    if (reload['success'] != true) throw StateError('Hot reload failed: $reload');
    child.stdin.writeln('fork');
    final fork = await next();
    if (fork['error'] != null) throw StateError('Existing writer failed after hot reload: ${fork['error']}');
    if (fork['writer'] != ready['writer'] || jsonEncode(fork['turns']) != '["one"]' ||
        fork['model'] != 'fork-override' || jsonEncode(fork['parentTurns']) != '["one","two"]') {
      throw StateError('Fork changed writer, boundary, configuration, or parent: $fork');
    }
    stdout.writeln('PASS: existing writer forks with current arguments after hot reload; prefix, overrides and parent verified.');
  } finally {
    await socket?.close();
    await replies?.cancel();
    child?.stdin.writeln('close');
    if (child != null) {
      try { await child.exitCode.timeout(const Duration(seconds: 5)); }
      on TimeoutException { child.kill(ProcessSignal.sigkill); await child.exitCode; }
    }
    await output?.cancel();
    await errors?.cancel();
    await ownerFile.writeAsString(ownerSource);
    await lifecycleFile.writeAsString(lifecycleSource);
    if (await fixture.exists()) await fixture.delete();
  }
}

const _fixture = r'''
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('store-reload-');
  final owner = await startStore(root.path, 'parent');
  final lifetime = CancellationToken();
  final config = {'cwd': root.path, 'provider': 'openai', 'model': 'fixture', 'provider_settings': {'reasoning': 'high'}};
  Future<List<Object?>> turns(String id) async {
    final page = jsonObject(await readSession(root.path, id, 'thread/read', {'includeTurns': true}, cancellation: lifetime));
    return (page['thread']['turns'] as List).map((turn) => turn['id']).toList();
  }
  try {
    await callIsolate(owner.port, 'append', {'type': 'task.created', 'data': config, 'metadata': {'config': config}});
    for (final id in ['one', 'two']) {
      await callIsolate(owner.port, 'append_batch', {'events': [
        {'type': 'turn.started', 'data': {'turnId': id}},
        {'type': 'input.committed', 'data': {'item': ConversationItem.user('Question $id').toJson()}},
        {'type': 'turn.completed', 'data': {}},
      ]});
    }
    stdout.writeln(jsonEncode({'service': (await Service.getInfo()).serverUri.toString(), 'writer': identityHashCode(owner)}));
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line == 'close') break;
      try {
        await callIsolate(owner.port, 'fork', {'id': 'child', 'lastTurnId': 'one', 'configuration': {...config, 'model': 'fork-override'}});
        final page = jsonObject(await readSession(root.path, 'child', 'thread/read', {}, cancellation: lifetime));
        stdout.writeln(jsonEncode({'writer': identityHashCode(owner), 'turns': await turns('child'),
          'model': page['configuration']['model'], 'parentTurns': await turns('parent')}));
      } catch (error) { stdout.writeln(jsonEncode({'error': '$error'})); }
    }
  } finally { await owner.close(); lifetime.cancel(); await root.delete(recursive: true); }
}
''';
