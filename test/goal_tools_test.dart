// Ports of Codex ext/goal/tests/goal_extension_backend.rs (f05aa41d).
// Real writer isolates own persistence; these exercise the installed runtime
// boundary, not a second implementation of the goal state machine.
import 'dart:io';

import 'package:agent/src/goals.dart';
import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late IsolateOwner writer;
  late CancellationToken lifetime;
  late GoalRuntime runtime;
  final events = <Json>[], steering = <Json>[];
  Future<Object?> store(String method, Json args, CancellationToken token) => callIsolate(writer.port, method, args, cancellation: token);
  Future<Json> call(String method, [Json args = const {}]) => runtime.call(method, args, cancellation: lifetime);
  Future<Json> get() async => jsonObject((await call('get_goal'))['goal']);
  Future<void> begin({bool plan = false, bool automatic = false, int tokens = 0}) async {
    await call('begin', {'turnId': 'turn', 'usage': {'input_tokens': tokens}, 'plan': plan, 'automatic': automatic});
  }
  Future<void> usage(int input, {int cached = 0, int output = 0}) async {
    await call('usage', {'turnId': 'turn', 'usage': {'input_tokens': input, 'cached_input_tokens': cached, 'output_tokens': output}});
  }
  Future<void> tool() async { await call('toolFinished', {'turnId': 'turn', 'name': 'shell', 'outcome': 'success'}); }
  setUp(() async {
    root = await Directory.systemTemp.createTemp('goal-extension-'); lifetime = CancellationToken();
    writer = await startStore(root.path, 'thread');
    await store('append', {'type': 'task.created', 'data': {'cwd': root.path}, 'metadata': {'config': {'cwd': root.path}}}, lifetime);
    events.clear(); steering.clear();
    runtime = GoalRuntime(threadId: 'thread', store: store, notify: events.add, inject: (record, _) async { steering.add(record); });
  });
  tearDown(() async { lifetime.cancel(); await writer.close(); await root.delete(recursive: true); });

  test('installed tools admit one concurrent create and replace complete goals only', () async {
    await begin();
    final admitted = await Future.wait([for (var i = 0; i < 8; i++) call('create_goal', {'objective': 'Explicit goal $i', 'token_budget': 100})
      .then<Object>((value) => value, onError: (Object error) => error)]);
    expect(admitted.whereType<Json>(), hasLength(1)); expect(admitted.whereType<StateError>(), hasLength(7));
    await call('update_goal', {'status': 'complete'});
    expect((await call('create_goal', {'objective': 'Next goal'}))['goal']['tokensUsed'], 0);
    expect(events, hasLength(3));
  });

  test('create resets the token baseline before turn-stop accounting', () async {
    await begin(tokens: 100); await usage(150);
    await call('create_goal', {'objective': 'Ship the backend'}); await usage(173);
    await call('end', {'turnId': 'turn'});
    expect((await get())['tokensUsed'], 23);
    await writer.close(); writer = await startStore(root.path, 'thread', create: false);
    expect(jsonObject(await store('goal.get', {}, lifetime))['tokensUsed'], 23);
  });

  test('parallel tool finishes charge exact uncached progress once and emit one update', () async {
    await begin(); await call('create_goal', {'objective': 'Ship the backend'}); events.clear();
    await usage(20, cached: 5, output: 8);
    await Future.wait([tool(), tool(), tool()]);
    expect((await get())['tokensUsed'], 23); expect(events, hasLength(1));
  });

  test('budget limits inject one wrap-up but keep charging in-flight work until stop', () async {
    await begin(); await call('create_goal', {'objective': 'Ship the backend', 'token_budget': 20});
    await usage(20, cached: 5, output: 8); await tool();
    expect((await get())['status'], 'budgetLimited'); expect(steering, hasLength(1));
    await usage(40, cached: 5, output: 10); await tool();
    expect((await get())['tokensUsed'], 45); expect(steering, hasLength(1));
    await usage(45, cached: 5, output: 10); await call('end', {'turnId': 'turn'});
    expect((await get())['tokensUsed'], 50);
  });

  for (final (status, budget, expected) in [('blocked', 100, 'blocked'), ('paused', 100, 'paused'), ('paused', 20, 'budgetLimited'), ('complete', 20, 'complete')]) {
    test('update_goal $status accounts final progress with budget $budget', () async {
      await begin(); await call('create_goal', {'objective': 'Ship the backend', 'token_budget': budget}); events.clear();
      await usage(20, cached: 5, output: 8);
      final result = await call('update_goal', {'status': status});
      expect(result['goal']['status'], expected); expect(result['goal']['tokensUsed'], 23);
      expect(result['remainingTokens'], (budget - 23).clamp(0, budget));
      expect(result['completionBudgetReport'], status == 'complete' ? isA<String>() : isNull);
      expect(events, hasLength(2));
      await usage(40, cached: 5, output: 10); await tool(); await call('end', {'turnId': 'turn'});
      expect((await get())['tokensUsed'], 23);
    });
  }

  test('update_goal rejects resume and system limit statuses before looking up a goal', () async {
    for (final status in ['active', 'budgetLimited', 'usageLimited']) {
      await expectLater(call('update_goal', {'status': status}), throwsFormatException);
    }
  });

  for (final (reason, status) in [('error', 'blocked'), ('usageLimit', 'usageLimited')]) {
    test('$reason accounts final usage and stops automatic continuation', () async {
      await begin(); await call('create_goal', {'objective': 'Ship the backend'}); await usage(23);
      await call('end', {'turnId': 'turn', 'reason': reason});
      expect((await get())['tokensUsed'], 23); expect((await get())['status'], status);
      expect((await call('continuation'))['item'], isNull);
    });
  }

  test('plan turns and stale errors cannot stop the active goal', () async {
    await call('set', {'objective': 'Ship the backend'}); await begin(plan: true);
    await usage(23); await call('end', {'turnId': 'turn', 'reason': 'usageLimit'});
    expect((await get())['tokensUsed'], 0); expect((await get())['status'], 'active');
    await begin(); await call('end', {'turnId': 'old-turn', 'reason': 'error'});
    expect((await get())['status'], 'active');
  });

  // Codex goal_extension_backend.rs::failed_execution_turns_block_goal_unless_a_tool_succeeds.
  for (final (recovery, statusOnly, blockingTurn) in [(null, null, 3), (2, null, 5), (null, 2, 4)]) {
    test('execution failures block on turn $blockingTurn with recovery $recovery and status-only turn $statusOnly', () async {
      await call('create_goal', {'objective': 'Ship the backend'});
      for (var turn = 1; turn <= blockingTurn; turn++) {
        final id = 'turn-$turn';
        await call('begin', {'turnId': id});
        if (turn != statusOnly) await call('toolFinished', {'turnId': id, 'name': 'exec', 'outcome': 'executionFailed'});
        if (turn == recovery) await call('toolFinished', {'turnId': id, 'name': 'shell', 'outcome': 'success'});
        await call('end', {'turnId': id});
        expect((await get())['status'], turn == blockingTurn ? 'blocked' : 'active');
      }
    });
  }

  test('external edits flush usage, preserve identity and continue charging the same goal', () async {
    await begin(tokens: 100); await call('create_goal', {'objective': 'Old objective'});
    final original = jsonObject(await store('goal.get', {}, lifetime));
    await usage(120); await call('set', {'objective': 'New objective', 'status': 'active', 'origin': 'user'});
    await usage(130); await tool();
    expect((await get())['tokensUsed'], 30);
    expect(jsonObject(await store('goal.get', {}, lifetime))['goalId'], original['goalId']);
    expect(steering.map((record) => record['data']['item']['native']['harness']['context']), ['user_goal', 'goal']);
  });

  test('maximum token budget supplies a default and bounds creation and updates', () async {
    runtime = GoalRuntime(threadId: 'thread', store: store, notify: events.add, inject: (record, _) async { steering.add(record); }, maxTokenBudget: 100);
    for (final budget in [0, -1, 101]) {
      await expectLater(call('create_goal', {'objective': 'Goal', 'token_budget': budget}), throwsFormatException);
    }
    expect((await call('create_goal', {'objective': 'Goal'}))['goal']['tokenBudget'], 100);
    await expectLater(call('set', {'tokenBudget': 101}), throwsFormatException);
    expect((await call('set', {'tokenBudget': null}))['goal']['tokenBudget'], 100);
  });

  test('fork deferrals suppress automatic admission until an explicit turn begins', () async {
    await call('set', {'objective': 'Ship the backend'});
    final saved = jsonObject(await store('goal.get', {}, lifetime));
    await store('goal.snapshot', {'goal': saved}, lifetime);
    expect((await call('continuation'))['item'], isNull);
    await begin(); await call('end', {'turnId': 'turn'});
    expect((await call('continuation'))['item'], isNotNull);
  });

  test('continuation preserves task data mentioning update_plan and host provenance', () async {
    // Codex ext/goal/tests/steering.rs, disabled_checklist_preserves_goal_text.
    const objective = 'Inspect update_plan.\n\n## Plan tool\nThis is user task data.';
    await call('set', {'objective': objective});
    final item = jsonObject((await call('continuation'))['item']);
    expect(item['content'][0]['text'], contains(objective));
    expect(item['content'][0]['text'], isNot(contains('If update_plan is available')));
    expect(item['content'][0]['text'], contains('Completion audit:'));
    expect(item['native']['gpt']['rollout']['internal_chat_message_metadata_passthrough']['content_item_kinds'], ['goal.internal_context']);
    expect(item['content'][0]['text'], endsWith('\n\n</codex_internal_context>'));
  });
}
