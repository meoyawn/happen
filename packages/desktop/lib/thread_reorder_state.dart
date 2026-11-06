sealed class ThreadReorderState {
  const ThreadReorderState();
}

final class ThreadReorderIdle extends ThreadReorderState {
  const ThreadReorderIdle();
}

final class ThreadReorderDragging extends ThreadReorderState {
  ThreadReorderDragging(this.sourceIndex, Iterable<String> order)
    : order = List.unmodifiable(order);
  final int sourceIndex;
  final List<String> order;
}

final class ThreadReorderDropping extends ThreadReorderState {
  ThreadReorderDropping(this.drag, this.targetIndex)
    : order = _reordered(drag.order, drag.sourceIndex, targetIndex);
  final ThreadReorderDragging drag;
  final int targetIndex;
  final List<String> order;
}

final class ThreadReorderSaving extends ThreadReorderState {
  const ThreadReorderSaving(this.drop);
  final ThreadReorderDropping drop;
}

final class ThreadReorderSaved extends ThreadReorderState {
  const ThreadReorderSaved(this.write);
  final ThreadReorderSaving write;
}

final class ThreadReorderFailed extends ThreadReorderState {
  const ThreadReorderFailed(this.write, this.error);
  final ThreadReorderSaving write;
  final Object error;
}

enum ThreadReorderCancelReason { escape, pointerCancelled, changed, disposed }

final class ThreadReorderCancelled extends ThreadReorderState {
  const ThreadReorderCancelled(this.reason);
  final ThreadReorderCancelReason reason;
}

ThreadReorderState transitionThreadReorder(ThreadReorderState current, ThreadReorderState next) =>
  switch ((current, next)) {
    (ThreadReorderIdle() || ThreadReorderSaved() || ThreadReorderFailed() || ThreadReorderCancelled(),
      ThreadReorderDragging()) => next,
    (ThreadReorderDragging(), ThreadReorderDropping() || ThreadReorderIdle() || ThreadReorderCancelled()) => next,
    (ThreadReorderDropping(), ThreadReorderSaving() || ThreadReorderCancelled()) => next,
    (ThreadReorderSaving(), ThreadReorderSaved() || ThreadReorderFailed() || ThreadReorderCancelled()) => next,
    _ => throw StateError('Invalid thread reorder transition'),
  };

List<String> _reordered(List<String> ids, int from, int to) {
  final order = ids.toList();
  order.insert(to, order.removeAt(from));
  return List.unmodifiable(order);
}
