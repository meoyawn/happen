// Ported from codex-rs/state/src/runtime/goals.rs and
// app-server/src/request_processors/thread_fork_goal.rs (Codex f05aa41d).
// Codex's goal tables live in the thread's sole SQLite file in Happen.
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late IsolateOwner writer;
  late CancellationToken lifetime;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-goals-');
    lifetime = CancellationToken();
    writer = await startStore(root.path, 'thread');
    await callIsolate(writer.port, 'append', {'type': 'task.created', 'data': {'cwd': root.path},
      'metadata': {'config': {'cwd': root.path}}}, cancellation: lifetime);
  });
  tearDown(() async { lifetime.cancel(); await writer.close(); await root.delete(recursive: true); });
  Future<Object?> call(String method, [Json params = const {}]) =>
    callIsolate(writer.port, 'goal.$method', params, cancellation: lifetime);
  Future<Json> replace({String status = 'active', int? budget = 100}) async => jsonObject(await call('replace', {
    'objective': 'optimize the benchmark', 'status': status, 'tokenBudget': budget,
  }));
  Future<Json> get() async => jsonObject(await call('get'));
  Future<Json> account(int tokens, int seconds, {String mode = 'activeOnly', String? id}) async =>
    jsonObject(await call('account', {'tokenDelta': tokens, 'timeDeltaSeconds': seconds, 'mode': mode, 'expectedGoalId': ?id}));

  test('replace, partial update, delete and reopen retain the goal identity and full state', () async {
    final original = await replace(budget: 100000);
    expect(original['goalId'], isA<String>());
    expect(await get(), original);
    final updated = jsonObject(await call('update', {'status': 'paused', 'tokenBudget': 200000}));
    expect(updated, {...original, 'status': 'paused', 'tokenBudget': 200000, 'updatedAtMs': updated['updatedAtMs']});
    await writer.close(); writer = await startStore(root.path, 'thread', create: false);
    expect(await get(), updated);
    final replacement = await replace(budget: null);
    expect(replacement['goalId'], isNot(original['goalId']));
    expect(replacement['tokenBudget'], isNull);
    expect(replacement['tokensUsed'], 0); expect(replacement['timeUsedSeconds'], 0);
    expect(await call('delete'), replacement);
    expect(await call('get'), isNull); expect(await call('delete'), isNull);
  });

  for (final method in ['replace', 'insert']) {
    test('$method applies a zero budget immediately at the storage boundary', () async {
      final goal = jsonObject(await call(method, {'objective': 'stay within budget', 'status': 'active', 'tokenBudget': 0}));
      expect(goal['status'], 'budget_limited'); expect(goal['tokensUsed'], 0); expect(goal['timeUsedSeconds'], 0);
    });
  }

  test('insert replaces complete goals only and serializes competing creates', () async {
    final inserts = await Future.wait([for (var i = 0; i < 8; i++) call('insert', {'objective': 'goal $i', 'tokenBudget': 100})]);
    expect(inserts.whereType<Json>(), hasLength(1));
    final original = await get();
    for (final status in ['active', 'paused', 'blocked', 'usage_limited', 'budget_limited']) {
      await call('update', {'status': status});
      expect(await call('insert', {'objective': 'must not replace'}), isNull);
      expect((await get())['goalId'], original['goalId']);
    }
    await call('update', {'status': 'complete'});
    final next = jsonObject(await call('insert', {'objective': 'next explicit goal'}));
    expect(next['goalId'], isNot(original['goalId'])); expect(next['tokensUsed'], 0);
  });

  test('stale updates and accounting cannot mutate a replacement goal', () async {
    final first = await replace(), replacement = await replace(budget: 10);
    expect(await call('update', {'status': 'complete', 'expectedGoalId': first['goalId']}), isNull);
    final outcome = await account(5, 5, id: first['goalId'] as String);
    expect(outcome, {'updated': false, 'goal': replacement});
    expect(await get(), replacement);
    expect(jsonObject(await call('update', {'status': 'complete', 'expectedGoalId': replacement['goalId']}))['status'], 'complete');
  });

  test('objective changes preserve usage, identity and creation time', () async {
    final original = await replace(); await account(30, 12);
    final updated = jsonObject(await call('update', {'objective': 'draft clearly', 'status': 'paused', 'tokenBudget': 200}));
    expect(updated['goalId'], original['goalId']); expect(updated['createdAtMs'], original['createdAtMs']);
    expect(updated['objective'], 'draft clearly'); expect(updated['tokensUsed'], 30); expect(updated['timeUsedSeconds'], 12);
  });

  test('concurrent partial updates and additive accounting preserve independent changes', () async {
    await replace(budget: 100000);
    await Future.wait([call('update', {'status': 'paused'}), call('update', {'tokenBudget': 200000})]);
    expect((await get())['status'], 'paused'); expect((await get())['tokenBudget'], 200000);
    await call('update', {'status': 'active'});
    await Future.wait([account(40, 4), account(60, 6)]);
    expect((await get())['tokensUsed'], 100); expect((await get())['timeUsedSeconds'], 10);
  });

  test('pause affects active goals only; usage limits also supersede budget limits', () async {
    await replace(); expect(jsonObject(await call('pause'))['status'], 'paused');
    expect(await call('pause'), isNull);
    await call('update', {'status': 'complete'}); expect(await call('pause'), isNull);
    expect((await get())['status'], 'complete');
    for (final status in ['active', 'budget_limited']) {
      await replace(status: status);
      expect(jsonObject(await call('usageLimit'))['status'], 'usage_limited');
      expect(await call('usageLimit'), isNull);
    }
  });

  test('budget-limited goals still account in-flight usage until the turn stops', () async {
    await replace(budget: 20);
    await account(5, 7); await account(15, 3);
    expect((await get())['status'], 'budget_limited');
    await account(5, 5);
    expect((await get())['tokensUsed'], 25); expect((await get())['timeUsedSeconds'], 15);
    final stopped = await get();
    expect(await account(5, 5, mode: 'activeStatusOnly'), {'updated': false, 'goal': stopped});
  });

  for (final (status, mode, expectedStatus) in [
    ('paused', 'activeOnly', 'paused'), ('complete', 'activeOnly', 'complete'),
    ('complete', 'activeOrComplete', 'complete'), ('paused', 'activeOrStopped', 'budget_limited'),
    ('blocked', 'activeOrStopped', 'budget_limited'), ('usage_limited', 'activeOrStopped', 'budget_limited'),
  ]) {
    test('$mode accounting for $status follows the Codex status filter', () async {
      await replace(status: status, budget: 20);
      final result = await account(25, 3, mode: mode);
      final updated = mode != 'activeOnly';
      expect(result['updated'], updated);
      final goal = jsonObject(result['goal']);
      expect(goal['status'], expectedStatus); expect(goal['tokensUsed'], updated ? 25 : 0);
      expect(goal['timeUsedSeconds'], updated ? 3 : 0);
    });
  }

  test('lowered budgets stop active work; pause and block cannot override budget exhaustion', () async {
    await replace(); await account(50, 1);
    expect(jsonObject(await call('update', {'tokenBudget': 40}))['status'], 'budget_limited');
    for (final status in ['active', 'paused', 'blocked']) {
      expect(jsonObject(await call('update', {'status': status}))['status'], 'budget_limited');
    }
    expect(jsonObject(await call('update', {'status': 'active', 'tokenBudget': null}))['status'], 'active');
    expect((await get())['tokenBudget'], isNull);
    final before = await get();
    expect(await account(-100, -100), {'updated': false, 'goal': before});
  });

  test('fork snapshots preserve progress and defer continuation without coupling later writes', () async {
    final original = await replace(); await account(30, 12);
    await callIsolate(writer.port, 'fork', {'id': 'child'}, cancellation: lifetime);
    final child = await startStore(root.path, 'child', create: false);
    try {
      final inherited = jsonObject(await callIsolate(child.port, 'goal.get', {}, cancellation: lifetime));
      expect(inherited['threadId'], 'child'); expect(inherited['goalId'], original['goalId']);
      expect(inherited['tokensUsed'], 30); expect(inherited['timeUsedSeconds'], 12);
      expect(await callIsolate(child.port, 'goal.hasDeferral', {}, cancellation: lifetime), true);
      await callIsolate(child.port, 'goal.clearDeferral', {}, cancellation: lifetime);
      expect(await callIsolate(child.port, 'goal.hasDeferral', {}, cancellation: lifetime), false);
      await callIsolate(child.port, 'goal.update', {'status': 'complete'}, cancellation: lifetime);
      expect((await get())['status'], 'active');
    } finally { await child.close(); }
    final path = '${root.path}/portable.jsonl';
    await callIsolate(writer.port, 'export', {'path': path}, cancellation: lifetime);
    await writer.close(); writer = await startStore(root.path, 'thread', create: false);
    expect((await get())['tokensUsed'], 30);
    await TaskStore.importFrom(root.path, path, newTaskId: (_) async => 'imported', cancellation: lifetime);
    final imported = await startStore(root.path, 'imported', create: false);
    try {
      final copy = jsonObject(await callIsolate(imported.port, 'goal.get', {}, cancellation: lifetime));
      expect(copy['threadId'], 'imported'); expect(copy['tokensUsed'], 30); expect(copy['status'], 'active');
    } finally { await imported.close(); }
    expect(root.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.sqlite')), hasLength(3));
  });
}
