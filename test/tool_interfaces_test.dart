import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CancellationToken cancellation;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('provider-tools-');
    cancellation = CancellationToken();
  });
  tearDown(() async { cancellation.cancel(); await root.delete(recursive: true); });

  test('providers share patch and process execution while preserving their contracts', () async {
    final openai = const OpenAIToolInterface().createRuntime(root.path, cancellation);
    final opencode = const OpenCodeToolInterface().createRuntime(root.path, cancellation);
    addTearDown(openai.close); addTearDown(opencode.close);
    final context = ToolExecution(call: opencode.call, catalog: (_) async => const OpenCodeToolInterface().hostCatalog,
      values: const {}, cancellation: cancellation);
    expect(await openai.call('apply_patch', '*** Begin Patch\n*** Add File: shared.txt\n+before\n*** End Patch', cancellation: cancellation), contains('A '));
    final patched = await opencode.execute(_call('patch', {'patchText':
      '*** Begin Patch\n*** Update File: shared.txt\n@@\n-before\n+after\n*** End Patch'}), context);
    expect(patched['output'], contains('M '));
    expect(await File('${root.path}/shared.txt').readAsString(), 'after\n');

    for (final tty in [false, true]) {
      final pending = jsonObject(await openai.call('exec_command', {
        'cmd': '${tty ? 'test -t 0 && test -t 1 && test -t 2 || exit 77; stty -echo; ' : ''}'
          r'read value; printf "received:%s" "$value"',
        'shell': '/bin/sh', 'login': false, 'yield_time_ms': 250, 'tty': tty,
      }, cancellation: cancellation));
      expect(pending['session_id'], isA<int>(), reason: 'tty=$tty must start the requested kind of interactive process');
      expect(pending['session_id'], inInclusiveRange(1000, 99999));
      expect(pending['chunk_id'], matches(r'^[0-9a-f]{6}$'));
      expect(pending['exit_code'], isNull);
      final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
      final token = cancellation.merge(deadline), output = StringBuffer();
      try {
        var settled = jsonObject(await openai.call('write_stdin', {'session_id': pending['session_id'], 'chars': 'hello\n'}, cancellation: token));
        output.write(settled['output']);
        while (settled['session_id'] != null) {
          settled = jsonObject(await openai.call('write_stdin', {'session_id': settled['session_id'], 'yield_time_ms': 1000}, cancellation: token));
          output.write(settled['output']);
        }
        expect(output.toString(), 'received:hello', reason: 'tty=$tty');
        expect(settled['exit_code'], 0); expect(settled['session_id'], isNull);
      } finally { deadline.cancel(); }
    }
    final native = await opencode.execute(_call('shell', {'command': 'printf native'}), context);
    expect(native, containsPair('output', 'native'));
    expect(native['exit'], 0);
    expect(native['exit_code'], isNull);
    expect(native['truncated'], isFalse);
  });

  test('Codex nested patches expose missing context, verify before writing, and recover on correction', () async {
    const interface = OpenAIToolInterface();
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final context = ToolExecution(call: runtime.call, catalog: (_) async => interface.hostCatalog,
      values: const {}, cancellation: cancellation);
    final target = File('${root.path}/file.txt'), receipt = File('${root.path}/receipt.txt');
    const original = 'summary: before\n  - Ran the production product\n';
    await target.writeAsString(original);
    const badPatch = '*** Begin Patch\n*** Add File: receipt.txt\n+created\n'
      '*** Update File: file.txt\n@@\n-summary: before\n+summary: after\n'
      '@@\n-  Ran the production product\n+  Ran the production product\n*** End Patch';
    Future<Json> exec(String patch) => runtime.execute(ToolCall(id: newId(), namespace: 'functions',
      name: 'exec', format: 'text', input: 'text(await tools.apply_patch(${jsonEncode(patch)}));'), context);
    final failed = await exec(badPatch);
    expect(failed['error'], contains('Failed to find expected lines in ${target.path}:\n  Ran the production product'));
    expect((failed['output'] as List).join('\n'), contains('Ran the production product'));
    expect(await target.readAsString(), original);
    expect(await receipt.exists(), isFalse, reason: 'Codex verifies the whole tool proposal before committing any file');
    const goodPatch = '*** Begin Patch\n*** Add File: receipt.txt\n+created\n'
      '*** Update File: file.txt\n@@\n-summary: before\n+summary: after\n'
      '@@\n-  - Ran the production product\n+  - Ran the production product reliably\n*** End Patch';
    final completed = await exec(goodPatch);
    expect(completed['error'], isNull);
    expect(await target.readAsString(), 'summary: after\n  - Ran the production product reliably\n');
    expect(await receipt.readAsString(), 'created\n');
  });

  test('Codex direct patch receipts use the applied plan for lenient patch syntax', () async {
    const interface = OpenAIToolInterface(codeModeOnly: false);
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final result = await runtime.execute(ToolCall(id: newId(), namespace: 'functions', name: 'apply_patch',
      format: 'text', input: '<<\'EOF\'\n  *** Begin Patch\n  *** Add File: file.txt\n+hello\n  *** End Patch\nEOF\n'),
      ToolExecution(call: runtime.call, catalog: (_) async => interface.hostCatalog, values: const {}, cancellation: cancellation));
    expect(result['output'], endsWith('Success. Updated the following files:\nA file.txt\n'));
    expect(await File('${root.path}/file.txt').readAsString(), 'hello\n');
  });

  test('Codex rejects multiple operations on the same source before writing', () async {
    final runtime = const OpenAIToolInterface().createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final target = File('${root.path}/file.txt');
    await target.writeAsString('before\n');
    await expectLater(runtime.call('apply_patch', '*** Begin Patch\n*** Add File: file.txt\n+first\n'
      '*** Update File: file.txt\n@@\n-before\n+second\n*** End Patch', cancellation: cancellation),
      throwsA(predicate<Object>((error) => error.toString().contains('multiple operations target ${target.path}'))));
    expect(await target.readAsString(), 'before\n');
  });

  test('OpenCode file tools use upstream path keys, paging, exact replacement, and search', () async {
    final runtime = const OpenCodeToolInterface().createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final context = ToolExecution(call: runtime.call, catalog: (_) async => [], values: const {}, cancellation: cancellation);
    Future<Json> run(String name, Json input) => runtime.execute(_call(name, input), context);
    await run('write', {'path': 'src/example.txt', 'content': 'alpha\r\nalpha\r\nomega\r\n'});
    expect((await run('read', {'path': 'src/example.txt', 'offset': 2, 'limit': 1}))['output'],
      'Read file src/example.txt, lines 2-2\n2: alpha\n[Output truncated. Continue reading with offset: 3]');
    await expectLater(run('read', {'input': 'return 42;'}), throwsFormatException);
    await expectLater(run('edit', {'path': 'src/example.txt', 'oldString': 'alpha', 'newString': 'beta'}), throwsStateError);
    expect(await File('${root.path}/src/example.txt').readAsString(), 'alpha\r\nalpha\r\nomega\r\n');
    await run('edit', {'path': 'src/example.txt', 'oldString': 'alpha', 'newString': 'beta', 'replaceAll': true});
    expect(await File('${root.path}/src/example.txt').readAsString(), 'beta\r\nbeta\r\nomega\r\n');
    expect((await run('glob', {'pattern': '**/*.txt'}))['output'], contains('/src/example.txt'));
    expect((await run('grep', {'pattern': 'beta', 'literal': true, 'include': '*.txt'}))['output'], contains('Found 2 matches'));
    expect((await run('read', {'path': 'src'}))['output'], 'Read directory src, entries 1-1\nexample.txt');
    await expectLater(run('shell', {'cmd': 'echo wrong contract'}), throwsFormatException);
  });

  test('OpenCode execute uses nested tools, paged search, implicit returns, and MCP values', () async {
    const interface = OpenCodeToolInterface();
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final catalog = interface.externalCatalog([
      for (final name in ['alpha', 'probe', 'zeta']) {
        'name': 'mcp__archive__$name', 'namespace': 'mcp__archive', 'tool_name': name,
        'description': 'Inspect an archived record',
        'parameters': {'type': 'object', 'properties': {'key': {'type': 'string'}}},
      },
    ]);
    final invoked = <String>[];
    final context = ToolExecution(catalog: (_) async => catalog, values: const {}, cancellation: cancellation,
      call: (name, input, {required cancellation}) async {
        invoked.add(name);
        return {'content': [{'type': 'text', 'text': jsonEncode({'key': jsonObject(input)['key'], 'complete': true})}]};
      });
    final result = await runtime.execute(_call('execute', {'code': '''
const page = await search({namespace: "tools.archive", limit: 1, offset: 1});
const value = await tools.archive.probe({key: "saved"});
({page, value})
'''}), context);
    final output = jsonObject(jsonDecode(result['output'] as String));
    expect(output['page']['items'][0]['path'], 'tools.archive.probe');
    expect(output['page']['remaining'], 1);
    expect(output['page']['next'], {'offset': 2});
    expect(output['value'], {'key': 'saved', 'complete': true});
    expect(invoked, ['mcp__archive__probe']);
    expect((result['toolCalls'] as List).map((call) => call['status']), everyElement('completed'));
    expect(interface.definitions.map((tool) => tool.name), isNot(contains('tool_search')));
    expect(interface.definitions.every((tool) => tool.namespace == null && tool.format == 'json'), isTrue);
  });

  test('Codex code mode exposes sorted metadata and dispatches normalized callable names', () async {
    const interface = OpenAIToolInterface();
    expect(interface.nestedDiscovery, isNull);
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final catalog = interface.externalCatalog([
      {'name': 'mcp__archive___probe', 'namespace': 'mcp__archive_', 'tool_name': 'probe',
        'description': 'Inspect an archived record', 'parameters': {'type': 'object'}},
      {'name': 'client___probe', 'namespace': 'client', 'tool_name': '_probe',
        'description': 'Inspect a client record', 'parameters': {'type': 'object'}},
    ]);
    final invoked = <String>[];
    final context = ToolExecution(catalog: (_) async => [...catalog, catalog.first],
      values: const {}, cancellation: cancellation, call: (name, input, {required cancellation}) async {
        invoked.add(name);
        return input;
      });
    final result = await runtime.execute(ToolCall(id: newId(), namespace: 'functions', name: 'exec', format: 'text', input: '''
export const moduleValue = 7;
text(ALL_TOOLS.map(tool => ({name: tool.name, keys: Object.keys(tool).sort()})));
text(await tools.mcp__archive_probe({key: "archive"}));
text(await tools.client_probe({key: "client"}));
text({moduleValue, moduleThis: this === undefined});
'''), context);
    expect(result['error'], isNull, reason: 'exec evaluates module grammar, not an AsyncFunction wrapper');
    expect((result['output'] as List).cast<String>().map(jsonDecode).toList(), [
      [
        {'name': 'client_probe', 'keys': ['description', 'name']},
        {'name': 'mcp__archive_probe', 'keys': ['description', 'name']},
      ],
      {'key': 'archive'}, {'key': 'client'},
      {'moduleValue': 7, 'moduleThis': true},
    ]);
    expect(invoked, ['mcp__archive___probe', 'client___probe']);
  });

  test('Codex nested calls snapshot JSON inputs and expose serialization errors at the call site', () async {
    const interface = OpenAIToolInterface();
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final inputs = <Object?>[];
    final result = await runtime.execute(ToolCall(id: newId(), name: 'exec', format: 'text', input: r'''
const input = {nested: {value: "before"}};
const pending = tools.echo(input);
input.nested.value = "after";
text(await pending);
const circular = {}; circular.self = circular;
const caught = [];
for (const value of [1n, circular, {toJSON() { throw new Error("bad arguments"); }}]) {
  try { tools.echo(value); caught.push(false); }
  catch (_) { caught.push(true); }
}
text(caught);
text(await tools.echo({toJSON() { return ["ready"]; }}));
'''), ToolExecution(catalog: (_) async => [{'name': 'echo', 'description': 'Echo input'}],
      values: const {}, cancellation: cancellation,
      call: (_, input, {required cancellation}) async { inputs.add(input); return input; }));
    expect(result['error'], isNull, reason: 'Invalid arguments must be catchable before host dispatch');
    expect((result['output'] as List).cast<String>().map(jsonDecode).toList(), [
      {'nested': {'value': 'before'}}, [true, true, true], ['ready'],
    ]);
    expect(inputs, [
      {'nested': {'value': 'before'}}, ['ready'],
    ]);
  });

  test('Codex code mode preserves MCP result envelopes and printable host failures', () async {
    const interface = OpenAIToolInterface();
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    const rpcError = 'RPCError when invoking method evaluate: invalid scope parameter: '
      'Cannot evaluate against a VM-internal object';
    const replies = {
      'rpc': {'isError': true, 'content': [{'type': 'text', 'text': rpcError}]},
      'structured': {'content': [{'type': 'text', 'text': 'ordinary text'}],
        'structuredContent': {'answer': 42}},
      'text': {'content': [{'type': 'text', 'text': 'ready'}]},
    };
    final catalog = interface.externalCatalog([
      for (final name in [...replies.keys, 'transport']) {
        'name': 'mcp__archive__$name', 'namespace': 'mcp__archive', 'tool_name': name,
        'description': 'Inspect a record', 'parameters': {'type': 'object'},
      },
    ]);
    final result = await runtime.execute(ToolCall(id: newId(), namespace: 'functions',
      name: 'exec', format: 'text', input: '''
const results = await Promise.allSettled([
  tools.mcp__archive__rpc({}),
  tools.mcp__archive__structured({}),
  tools.mcp__archive__text({}),
  tools.mcp__archive__transport({}),
]);
text(results);
if (results[0].value.isError) text(results[0].value.content);
text(results[1].value.structuredContent);
'''), ToolExecution(catalog: (_) async => catalog, values: const {}, cancellation: cancellation,
      call: (name, _, {required cancellation}) async {
        if (name == 'mcp__archive__transport') throw StateError('MCP transport disconnected');
        return replies[name.substring('mcp__archive__'.length)];
      }));
    expect(result['error'], isNull);
    expect((result['output'] as List).cast<String>().map(jsonDecode).toList(), [
      [
        for (final reply in replies.values) {'status': 'fulfilled', 'value': reply},
        {'status': 'rejected', 'reason': 'Bad state: MCP transport disconnected'},
      ],
      replies['rpc']!['content'],
      {'answer': 42},
    ]);
  });

  test('Codex exec yields real cells; wait drains output, completes, and terminates host work', () async {
    const interface = OpenAIToolInterface();
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final entered = Completer<void>(), release = Completer<void>();
    CancellationToken? child;
    final context = ToolExecution(catalog: (_) async => [{'name': 'block', 'description': 'Wait for release'}], values: const {}, cancellation: cancellation,
      call: (_, _, {required cancellation}) async {
        child = cancellation;
        if (!entered.isCompleted) entered.complete();
        await release.future.asCancellable(cancellation);
        return 'released';
      });
    Future<Json> exec(String source) => runtime.execute(ToolCall(id: newId(), namespace: 'functions',
      name: 'exec', input: source), context);
    final running = await exec('// @exec: {"yield_time_ms": 0}\ntext("first"); text(await tools.block({})); store("answer", 42);');
    await entered.future;
    expect(running['output'], ['first']);
    final id = running['cell_id'] as String;
    expect(id, '1');
    expect(interface.formatResult(_call('wait', {}), running), contains('Script running with cell ID $id'));
    final waiting = await runtime.execute(_call('wait', {'cell_id': id, 'yield_time_ms': 0}), context);
    expect(waiting['cell_id'], id);
    expect(waiting['output'], isEmpty, reason: 'A wait must not replay already consumed output');
    expect(child!.isCancelled, isFalse);
    release.complete();
    final completed = await runtime.execute(_call('wait', {'cell_id': id}), context);
    expect(completed['cell_id'], isNull);
    expect(completed['output'], ['released']);
    expect(completed['values'], {'answer': 42});
    expect((await runtime.execute(_call('wait', {'cell_id': id}), context))['error'], 'exec cell $id not found');

    CancellationToken? blocked;
    final yielded = await runtime.execute(ToolCall(id: newId(), name: 'exec',
      input: 'text("before"); yield_control(); await tools.block({}); text("after");'),
      ToolExecution(catalog: (_) async => [{'name': 'block', 'description': 'Wait for cancellation'}], values: const {}, cancellation: cancellation,
        call: (_, _, {required cancellation}) {
          blocked = cancellation;
          return CancellableCompleter<Object?>(cancellation).future;
        }));
    expect(yielded['output'], ['before']);
    expect(yielded['cell_id'], '2');
    final stopped = await runtime.execute(_call('wait', {'cell_id': yielded['cell_id'], 'terminate': true}), context);
    expect(stopped['terminated'], isTrue);
    expect(stopped['output'], isEmpty);
    expect(blocked!.isCancelled, isTrue);
    expect(cancellation.isCancelled, isFalse);
    expect(interface.formatResult(_call('wait', {}), stopped), contains('Script terminated'));

    final a = await exec('yield_control(); await new Promise(resolve => setTimeout(resolve, 50)); store("a", 1);');
    final b = await exec('store("b", 2);');
    expect(b['values'], containsPair('b', 2));
    final merged = await runtime.execute(_call('wait', {'cell_id': a['cell_id']}), context);
    expect(merged['values'], {'answer': 42, 'a': 1, 'b': 2});

    for (final source in [
      'text("before-exit"); try { exit(); } finally { while (true) {} }',
      'await new Promise(resolve => setTimeout(() => { text("before-exit"); exit(); }, 0));',
    ]) {
      final ended = await exec(source);
      expect(ended['error'], isNull, reason: 'exit terminates native execution, including finally blocks and timer callbacks');
      expect(ended['output'], ['before-exit']);
    }

    for (final failed in [false, true]) {
      final pending = await exec('yield_control(); await tools.block({}); store("settled", true); '
        '${failed ? 'throw new Error("settled failure");' : 'text("settled");'}');
      final deadline = TimeoutCancellationToken(const Duration(seconds: 3));
      try {
        while (runtime.hasRunningCells) {
          await cancellableDelay(Duration.zero, cancellation.merge(deadline));
        }
      } finally { deadline.cancel(); }
      final settled = await runtime.execute(_call('wait', {'cell_id': pending['cell_id'], 'terminate': true}), context);
      expect(settled['terminated'], isNull, reason: 'A completed result takes precedence over a late termination request');
      expect(settled['values'], containsPair('settled', true));
      if (failed) { expect(settled['error'], contains('settled failure')); }
      else { expect(settled['output'], ['settled']); }
    }
  });

  test('OpenCode cancels unawaited calls and reports background completion without polling', () async {
    const interface = OpenCodeToolInterface();
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    final nativeContext = ToolExecution(call: runtime.call, catalog: (_) async => [], values: const {}, cancellation: cancellation);
    expect((await runtime.execute(_call('shell', {'command': 'sleep 0.1; printf finished', 'background': true}), nativeContext))['status'], 'running');
    expect(await runtime.notifications(wait: true, cancellation: cancellation), [contains('finished')]);
    final cell = CancellationToken();
    final execution = runtime.execute(_call('execute', {'code': 'tools.archive.wait({}); return "done";'}),
      ToolExecution(catalog: (_) async => [{'name': 'archive.wait'}], values: const {}, cancellation: cell,
        call: (_, _, {required cancellation}) => CancellableCompleter<Object?>(cancellation).future));
    expect((await execution.timeout(const Duration(seconds: 2)))['output'], 'done');
    expect(cell.isCancelled, isTrue);
  });
}

ToolCall _call(String name, Json input) => ToolCall(id: newId(), name: name, format: 'json', input: jsonEncode(input));
