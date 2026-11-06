sealed class RenameState {
  const RenameState();
}

final class RenameIdle extends RenameState {
  const RenameIdle();
}

final class RenameEditing extends RenameState {
  const RenameEditing();
}

final class RenameSaving extends RenameState {
  const RenameSaving(this.title);
  final String title;
}

final class RenameFailed extends RenameState {
  const RenameFailed(this.title, this.error);
  final String title;
  final Object error;
}

RenameState transitionRename(RenameState current, RenameState next) => switch ((current, next)) {
  (RenameIdle() || RenameFailed(), RenameEditing()) => next,
  (RenameEditing(), RenameIdle() || RenameSaving()) => next,
  (RenameSaving(), RenameIdle() || RenameFailed()) => next,
  _ => throw StateError('Invalid thread rename transition'),
};
