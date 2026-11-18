import 'dart:typed_data';

import 'package:flutter/services.dart';

const dictationMethods = MethodChannel('happen/dictation');

typedef LiveDictation = ({void Function(Uint8List) append, Future<String> Function() finish, void Function() close});

sealed class DictationCaptureEvent {
  const DictationCaptureEvent(this.id);
  final String id;
}

final class DictationAudio extends DictationCaptureEvent {
  const DictationAudio(super.id, this.pcm, this.rms);
  final Uint8List pcm;
  final double rms;
}

final class DictationCaptureFailure extends DictationCaptureEvent {
  const DictationCaptureFailure(super.id);
}
