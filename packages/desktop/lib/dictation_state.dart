sealed class DictationState {
  const DictationState();
}

final class DictationIdle extends DictationState {
  const DictationIdle();
}

final class DictationStarting extends DictationState {
  const DictationStarting();
}

final class DictationRecording extends DictationState {
  const DictationRecording();
}

final class DictationTranscribing extends DictationState {
  const DictationTranscribing();
}

final class DictationFailed extends DictationState {
  const DictationFailed(this.error, {this.canRetry = false, this.microphonePermissionDenied = false});
  final String error;
  final bool canRetry;
  final bool microphonePermissionDenied;
}

final class DictationDisposed extends DictationState {
  const DictationDisposed();
}

DictationState transitionDictation(DictationState current, DictationState next) => switch ((current, next)) {
  (_, DictationDisposed()) => next,
  (DictationDisposed(), _) => throw StateError('Dictation is disposed'),
  (_, DictationIdle()) => next,
  (DictationIdle() || DictationFailed(), DictationStarting()) => next,
  (DictationStarting(), DictationRecording() || DictationFailed()) => next,
  (DictationRecording(), DictationTranscribing() || DictationFailed()) => next,
  (DictationTranscribing(), DictationFailed()) => next,
  (DictationFailed(canRetry: true), DictationTranscribing()) => next,
  _ => throw StateError('Invalid dictation transition'),
};
