// SQLite transaction budgets from Codex state/runtime/goals.rs and
// thread-store/src/local/thread_history_materialization{,_pipeline}.rs.
// Count SQLite's native commit hook, not SQL strings or mocked storage calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late TaskStore store;
  var commits = 0;
  setUp(() {
    root = Directory.systemTemp.createTempSync('sqlite-commit-budget-'); store = TaskStore(root.path, 'thread');
    store.append('task.created', {}, metadata: {'config': <String, Object?>{}});
    commits = 0; store.db.raw.commitFilter = () { commits++; return true; };
  });
  tearDown(() { store.close(); root.deleteSync(recursive: true); });
  void budget(int expected, void Function() action) {
    commits = 0; action(); expect(commits, expected);
  }
  Json line(int index) => {'type': 'event_msg', 'payload': {'type': 'item_completed', 'turn_id': 'turn',
    'item': {'type': 'UserMessage', 'id': 'user-$index', 'content': <Json>[]}}};

  test('one live canonical batch and its projection share one SQLite commit', () {
    budget(1, () => store.appendBatch([
      {'type': 'turn.started', 'data': {'id': 'turn'}},
      {'type': 'input.committed', 'data': {'item': ConversationItem.user('Hello').toJson()}},
    ]));
    expect(store.db.select('SELECT * FROM thread_items'), hasLength(1));
    budget(0, store.native.catchUp);
    budget(0, () {
      store.append('model.started', {'assistantMessageID': 'assistant'});
      for (var i = 0; i < 50; i++) { store.append('text.delta', {'delta': 'a'}); }
      store.append('tool.started', {'call_id': 'call', 'name': 'exec', 'input': 'text(1)'});
    });
  });

  test('each changed goal uses one commit; reads, stale writes and empty accounting add none', () {
    budget(1, () => store.goal('replace', {'objective': 'Goal', 'tokenBudget': 100}));
    budget(1, () => store.goal('account', {'tokenDelta': 23}));
    budget(1, () => store.goal('update', {'status': 'paused'}));
    budget(0, () {
      store.goal('get', {}); store.goal('hasDeferral', {}); store.goal('update', {});
      store.goal('account', {'tokenDelta': 0, 'timeDeltaSeconds': 0});
      store.goal('update', {'status': 'complete', 'expectedGoalId': 'stale'});
    });
    final goal = jsonObject(store.goal('get', {}));
    budget(1, () => store.goal('snapshot', {'goal': goal}));
    budget(1, () => store.goal('clearDeferral', {}));
    budget(1, () => store.goal('delete', {}));
  });

  test('terminal reported spending and the failed turn share one commit without changing the context baseline', () {
    store.append('turn.started', {'id': 'failed-turn'});
    budget(1, () => store.append('turn.failed', {'error': 'Incomplete response returned, reason: max_output_tokens',
      'incompleteUsage': {'response_id': 'incomplete', 'usage': {'input_tokens': 120, 'output_tokens': 30,
        'cached_input_tokens': 0, 'cache_write_input_tokens': 0, 'reasoning_output_tokens': 0, 'total_tokens': 150}}}));
    expect(store.db.select("SELECT line FROM rollout_lines WHERE json_extract(line,'\$.type') IS 'token_usage_record'"), hasLength(1));
    expect(store.modelSnapshot()['tokens'], isNull);
    expect(store.native.items(), isEmpty);
    budget(0, store.native.catchUp);
  });

  test('cold tool settlement and its reset notice share one commit; warm ownership writes nothing', () {
    budget(0, () => store.startToolRuntime('old'));
    store.append('host_tool.started', {'id': 'command', 'name': 'exec_command', 'arguments': {'cmd': 'read value'}});
    final call = ToolCall(id: 'pending', name: 'exec', input: 'await pending();');
    store.append('model.completed', {'assistantMessageID': 'assistant', 'output': [ConversationItem(role: 'assistant', content: [call.toJson()]).toJson()]});
    budget(1, () => store.startToolRuntime('new'));
    final context = store.modelContext();
    expect(context.where((item) => item['native']?['harness']?['reason'] == 'tool_runtime_restarted'), hasLength(1));
    expect(context.expand((item) => item['content'] as List).where((part) => part['call_id'] == 'pending'), hasLength(1));
    budget(0, () => store.startToolRuntime('new'));
  });

  test('catch-up retains Codex 256-step commit boundaries rather than committing each row', () {
    store.db.execute('BEGIN'); store.native.record([for (var i = 0; i < 600; i++) line(i)]); store.db.execute('COMMIT');
    budget(3, store.native.catchUp);
    expect(store.db.select('SELECT * FROM thread_items'), hasLength(600));
    budget(0, store.native.catchUp);
  });

  test('projection failure preserves canonical durability without an extra commit', () {
    store.db.execute("CREATE TRIGGER broken BEFORE INSERT ON thread_items BEGIN SELECT RAISE(ABORT,'projection fault'); END");
    budget(1, () => store.native.append([line(1)]));
    expect(store.db.select('SELECT * FROM thread_items'), isEmpty);
    expect(store.db.select('SELECT * FROM rollout_lines'), hasLength(2));
    store.db.execute('DROP TRIGGER broken');
    budget(1, store.native.catchUp);
    expect(store.db.select('SELECT * FROM thread_items'), hasLength(1));
  });

  test('byte-bounded catch-up includes the threshold-crossing record in the current commit', () {
    store.db.execute('BEGIN');
    store.native.record([for (var i = 0; i < 3; i++) {'type': 'response_item',
      'payload': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'x' * 600000}]}}]);
    store.db.execute('COMMIT');
    budget(2, store.native.catchUp);
  });

  test('fork initialization checkpoints the child once, regardless of inherited state size', () async {
    store.append('turn.started', {'id': 'active'});
    store.append('input.committed', {'item': ConversationItem.user('Shared prefix').toJson()});
    for (var i = 0; i < 20; i++) { store.keyValue('set', {'key': 'key-$i', 'value': i}); }
    store.goal('replace', {'objective': 'Shared goal', 'tokenBudget': 100});
    final port = ReceivePort(), drained = Completer<void>();
    var childCommits = 0;
    final subscription = port.listen((Object? raw) {
      final value = jsonObject(raw);
      if (value['event']?['name'] == 'sqlite.commit') childCommits++;
      if (value['done'] == true) drained.complete();
    });
    final token = CancellationToken();
    commits = 0;
    try {
      await withTrace(TraceContext(sink: port.sendPort, service: 'storage'), () => store.fork('fork', cancellation: token));
      port.sendPort.send({'done': true}); await drained.future;
      expect(commits, 0, reason: 'A fork must not write to the parent.');
      expect(childCommits, 3, reason: 'WAL header + schema + one atomic fork initialization.');
      final child = TaskStore(root.path, 'fork', create: false);
      try {
        expect(child.keyValue('get', {'key': 'key-19'}), 19);
        expect(jsonObject(child.goal('get', {}))['objective'], 'Shared goal');
        expect(child.modelContext(), hasLength(1));
      } finally { child.close(); }
    } finally { token.cancel(); await subscription.cancel(); port.close(); }
  });

  test('import uses initialization plus the same bounded commits as Codex materialization', () async {
    final path = File('${root.path}/many.jsonl');
    final lines = <Json>[{'type': 'session_meta', 'payload': {'id': 'source', 'history_mode': 'paginated'}},
      for (var i = 0; i < 600; i++) line(i)];
    await path.writeAsString([for (final (i, line) in lines.indexed)
      jsonEncode({'timestamp': '2026-01-01T00:00:00Z', 'ordinal': i, ...line})].join('\n'));
    final port = ReceivePort(), drained = Completer<void>();
    var importedCommits = 0;
    final subscription = port.listen((Object? raw) {
      final value = jsonObject(raw);
      if (value['event']?['name'] == 'sqlite.commit') importedCommits++;
      if (value['done'] == true) drained.complete();
    });
    final cancellation = CancellationToken();
    try {
      await withTrace(TraceContext(sink: port.sendPort, service: 'storage'), () =>
        TaskStore.importFrom(root.path, path.path, newTaskId: (_) async => 'imported', cancellation: cancellation));
      port.sendPort.send({'done': true}); await drained.future;
      // Codex sqlite/connection.rs also initializes WAL before migrations.
      // One WAL-header commit, one schema transaction, ceil(601 / 256) batches.
      expect(importedCommits, 5);
      final imported = TaskStore(root.path, 'imported', create: false);
      try { expect(imported.db.select('SELECT * FROM thread_items'), hasLength(600)); }
      finally { imported.close(); }
    } finally { cancellation.cancel(); await subscription.cancel(); port.close(); }
  });
}
