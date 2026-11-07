sealed class ArchiveWriteState {
  const ArchiveWriteState();
}

final class ArchiveWriteIdle extends ArchiveWriteState {
  const ArchiveWriteIdle();
}

final class ArchiveWritePending extends ArchiveWriteState {
  const ArchiveWritePending(this.previous, this.archived);
  final bool previous, archived;
}

final class ArchiveWriteCommitted extends ArchiveWriteState {
  const ArchiveWriteCommitted(this.archived);
  final bool archived;
}

final class ArchiveWriteFailed extends ArchiveWriteState {
  const ArchiveWriteFailed(this.write, this.error);
  final ArchiveWritePending write;
  final Object error;
}

ArchiveWriteState transitionArchiveWrite(ArchiveWriteState current, ArchiveWriteState next) => switch ((current, next)) {
  (ArchiveWriteIdle() || ArchiveWriteCommitted() || ArchiveWriteFailed(), ArchiveWritePending()) => next,
  (ArchiveWritePending(), ArchiveWriteCommitted() || ArchiveWriteFailed()) => next,
  _ => throw StateError('Invalid archive write transition'),
};
