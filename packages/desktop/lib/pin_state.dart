sealed class PinWriteState {
  const PinWriteState();
}

final class PinWriteIdle extends PinWriteState {
  const PinWriteIdle();
}

final class PinWritePending extends PinWriteState {
  PinWritePending(Iterable<String> previous, Iterable<String> order)
    : previous = List.unmodifiable(previous), order = List.unmodifiable(order);
  final List<String> previous, order;
}

final class PinWriteCommitted extends PinWriteState {
  PinWriteCommitted(Iterable<String> order) : order = List.unmodifiable(order);
  final List<String> order;
}

final class PinWriteFailed extends PinWriteState {
  const PinWriteFailed(this.write, this.error);
  final PinWritePending write;
  final Object error;
}

PinWriteState transitionPinWrite(PinWriteState current, PinWriteState next) => switch ((current, next)) {
  (PinWriteIdle() || PinWriteCommitted() || PinWriteFailed(), PinWritePending()) => next,
  (PinWritePending(), PinWriteCommitted() || PinWriteFailed()) => next,
  _ => throw StateError('Invalid pin write transition'),
};
