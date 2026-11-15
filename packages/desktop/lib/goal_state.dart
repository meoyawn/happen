import 'package:protocol/protocol.dart';

sealed class ComposerMode {
  const ComposerMode();
}

final class MessageComposer extends ComposerMode {
  const MessageComposer();
}

final class GoalComposer extends ComposerMode {
  const GoalComposer();
}

ComposerMode transitionComposerMode(ComposerMode current, ComposerMode next) => switch ((current, next)) {
  (MessageComposer() || GoalComposer(), MessageComposer() || GoalComposer()) => next,
};

typedef GoalMutation = ({String? objective, String? status, bool clear});

sealed class GoalWriteState {
  const GoalWriteState();
}

final class GoalWriteIdle extends GoalWriteState {
  const GoalWriteIdle();
}

final class GoalWritePending extends GoalWriteState {
  const GoalWritePending(this.mutation);
  final GoalMutation mutation;
}

final class GoalWriteFailed extends GoalWriteState {
  const GoalWriteFailed(this.write, this.error);
  final GoalWritePending write;
  final Object error;
}

GoalWriteState transitionGoalWrite(GoalWriteState current, GoalWriteState next) => switch ((current, next)) {
  (GoalWriteIdle() || GoalWriteFailed(), GoalWritePending()) => next,
  (GoalWritePending(), GoalWriteIdle() || GoalWriteFailed()) => next,
  _ => throw StateError('Invalid goal write transition'),
};

/// Only a leading command selects Goal mode; quoted commands remain text.
RegExpMatch? goalCommand(String text) => RegExp(r'^\s*/go+al(?:\s+|$)').firstMatch(text);

Json? savedGoal(Object? value) => value is Map<String, dynamic> ? Map.unmodifiable(value) : null;
