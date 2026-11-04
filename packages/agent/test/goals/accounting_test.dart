// Port of Codex ext/goal/tests/accounting.rs (f05aa41d).
import 'package:agent/src/goal_accounting.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

Json usage(int input, int cached, int output) => {
  'input_tokens': input, 'cached_input_tokens': cached, 'output_tokens': output,
};

void main() {
  test('goal accounting uses the turn-start baseline for exact uncached deltas', () {
    final state = GoalAccountingState();
    state.startTurn('turn-1', usage(100, 10, 30));
    expect(state.recordTokenUsage('turn-1', usage(120, 14, 42)), {'turnDelta': 28, 'threadUnflushedDelta': 28});
  });

  test('goal accounting ignores plan-mode turns', () {
    final state = GoalAccountingState();
    state.startTurn('turn-1', {}, plan: true);
    expect(state.recordTokenUsage('turn-1', usage(20, 5, 8)), isNull);
  });

  test('empty continuations need three turns without activity or goal changes', () {
    for (final (interruption, blockingTurn) in [
      ('none', 3), ('user', 6), ('tool', 6), ('goal', 5), ('reset', 6),
      ('missing final', 6), ('partial answer', 6), ('abort', 3), ('mixed', 3),
      ('tool after abort', 6), ('user after abort', 6),
    ]) {
      final state = GoalAccountingState();
      for (var turn = 1; turn <= blockingTurn; turn++) {
        final id = '$turn', goal = interruption == 'goal' && turn >= 3 ? 'new' : 'goal';
        state.startTurn(id, {}); state.markTurnGoalActive(id, goal);
        final aborted = {'abort', 'tool after abort', 'user after abort'}.contains(interruption) || interruption == 'mixed' && turn == 2;
        if (turn == 3 && interruption == 'partial answer') {
          state.recordItem(id, {'type': 'agentMessage', 'text': ' \n', 'phase': 'partial_answer'});
        } else if (!(aborted || turn == 3 && interruption == 'missing final')) {
          state.recordItem(id, {'type': 'agentMessage', 'text': ' \n', 'phase': 'final_answer'});
        }
        if (aborted) state.interruptTurn(id);
        if (!(turn == 3 && {'user', 'user after abort'}.contains(interruption))) state.markGoalContinuation(id);
        if (turn == 3 && {'tool', 'tool after abort'}.contains(interruption)) state.recordToolOutcome(id, 'shell', 'unsuccessful');
        if (turn == 3 && interruption == 'reset') state.resetEmptyResponses();
        expect(state.emptyResponseGoal(id), turn == blockingTurn ? goal : null, reason: '$interruption, turn $turn');
        state.finishTurn(id);
      }
    }
  });

  test('execution failures do not transfer to a replacement goal', () {
    final state = GoalAccountingState();
    for (var turn = 1; turn <= 4; turn++) {
      final id = 'turn-$turn';
      state.startTurn(id, {}); state.markTurnGoalActive(id, turn == 1 ? 'first' : 'second');
      state.recordToolOutcome(id, 'exec', 'executionFailed');
      if (turn == 1) state.markCurrentTurnGoalActive('second');
      expect(state.executionFailureGoal(id), turn == 4 ? 'second' : null);
      state.finishTurn(id);
      if (turn == 3) state.resetIdleProgress();
    }
  });

  test('script errors and failures before execution do not block goals', () {
    for (final outcome in ['unsuccessful', 'notExecuted']) {
      final state = GoalAccountingState();
      for (var turn = 1; turn <= 3; turn++) {
        final id = 'turn-$turn';
        state.startTurn(id, {}); state.markTurnGoalActive(id, 'goal');
        state.recordToolOutcome(id, 'exec', outcome);
        expect(state.executionFailureGoal(id), isNull); state.finishTurn(id);
      }
    }
  });

  test('a successful tool resets failures before an interrupted turn ends', () {
    final state = GoalAccountingState();
    for (var turn = 1; turn <= 4; turn++) {
      final id = 'turn-$turn';
      state.startTurn(id, {}); state.markTurnGoalActive(id, 'goal');
      state.recordToolOutcome(id, turn == 3 ? 'shell' : 'exec', turn == 3 ? 'success' : 'executionFailed');
      if (turn != 3) expect(state.executionFailureGoal(id), isNull);
      state.finishTurn(id);
    }
  });

  test('descendant usage received during persistence remains pending after the checkpoint', () {
    final state = GoalAccountingState();
    state.startTurn('turn-1', {}); state.markCurrentTurnGoalActive('goal-1');
    state.recordDescendantUsage(usage(20, 5, 8)); state.recordDescendantUsage(usage(8, 2, 4));
    final first = state.progressSnapshot('turn-1')!;
    expect(first['tokenDelta'], 33);
    state.recordDescendantUsage(usage(6, 1, 3));
    state.markProgressAccounted(first, 'active', turnId: 'turn-1');
    expect(state.progressSnapshot('turn-1')!['tokenDelta'], 8);
  });
}
