import 'package:agent/src/goals.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('goal operations serialize concurrent creates and cannot pause past an exhausted budget', () async {
    final cancellation = CancellationToken();
    addTearDown(cancellation.cancel);
    var tokens = 0;
    final goals = GoalRuntime(taskId: newUuidV7(), tokens: () => tokens,
      load: (_) async => {}, save: (_, _) async {});
    Future<Json> call(String method, [Json arguments = const {}]) => goals.call(method, arguments, cancellation: cancellation);
    final admitted = await Future.wait([for (var index = 0; index < 8; index++)
      call('create_goal', {'objective': 'Explicit goal $index', 'token_budget': 10})
        .then<Object>((value) => value, onError: (Object error) => error)]);
    expect(admitted.whereType<Map>(), hasLength(1));
    expect(admitted.whereType<StateError>(), hasLength(7));
    tokens = 10;
    await call('account');
    expect((await call('update_goal', {'status': 'paused'}))['goal']['status'], 'budget_limited');
    expect((await call('get_goal'))['remainingTokens'], 0);
    expect((await call('get_goal'))['goal']['tokensUsed'], 10);
    expect((await call('update_goal', {'status': 'complete'}))['completionBudgetReport'], isA<String>());
    final next = await call('create_goal', {'objective': 'The next explicit goal'});
    expect(next['remainingTokens'], isNull);
    expect(next['goal']['tokensUsed'], 0);
  });
}
