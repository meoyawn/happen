part of 'session.dart';

sealed class _AnnotationWriteState { const _AnnotationWriteState(); }
final class _AnnotationWriteIdle extends _AnnotationWriteState { const _AnnotationWriteIdle(); }
final class _AnnotationWritePending extends _AnnotationWriteState {
  const _AnnotationWritePending(this.revision);
  final int revision;
}
final class _AnnotationWriteSaved extends _AnnotationWriteState {
  const _AnnotationWriteSaved(this.revision);
  final int revision;
}
final class _AnnotationWriteFailed extends _AnnotationWriteState {
  const _AnnotationWriteFailed(this.revision, this.error);
  final int revision;
  final Object error;
}

_AnnotationWriteState _transitionAnnotationWrite(_AnnotationWriteState current, _AnnotationWriteState next) => switch ((current, next)) {
  (_, _AnnotationWritePending()) => next,
  (_AnnotationWritePending(revision: final before), _AnnotationWriteSaved(revision: final after) ||
    _AnnotationWriteFailed(revision: final after)) when before == after => next,
  _ => throw StateError('Invalid annotation persistence transition'),
};

extension AnnotationDrafts on DesktopSession {
  List<ResponseAnnotation> annotationsFor(String draft) => _annotationDrafts[draft] ?? const [];

  void putAnnotation(String draft, ResponseAnnotation annotation) {
    final previous = annotationsFor(draft);
    final index = previous.indexWhere((item) => item.id == annotation.id);
    if (index >= 0 && previous[index].annotation == annotation.annotation &&
        previous[index].text == annotation.text && previous[index].messageId == annotation.messageId &&
        previous[index].startOffset == annotation.startOffset && previous[index].endOffset == annotation.endOffset &&
        identical(previous[index].browser, annotation.browser)) { return; }
    final next = List<ResponseAnnotation>.of(previous);
    if (index < 0) { next.add(annotation); } else { next[index] = annotation; }
    _annotationDrafts[draft] = List.unmodifiable(next);
    annotationChanges.value++;
    saveDrafts();
  }

  void removeAnnotation(String draft, String id) {
    final previous = annotationsFor(draft);
    final next = previous.where((item) => item.id != id).toList(growable: false);
    if (previous.length == next.length) return;
    if (next.isEmpty) { _annotationDrafts.remove(draft); }
    else { _annotationDrafts[draft] = List.unmodifiable(next); }
    annotationChanges.value++;
    saveDrafts();
  }

  /// An acknowledgement consumes only the immutable versions actually sent.
  void _consumeAnnotations(String draft, List<ResponseAnnotation> sent, {String? adopt}) {
    final next = annotationsFor(draft).where((item) => !sent.any((snapshot) => identical(item, snapshot))).toList(growable: false);
    _annotationDrafts.remove(draft);
    if (next.isNotEmpty) _annotationDrafts[adopt ?? draft] = List.unmodifiable(next);
    if (sent.isNotEmpty || adopt != null) {
      annotationChanges.value++;
      saveDrafts();
    }
  }
}
