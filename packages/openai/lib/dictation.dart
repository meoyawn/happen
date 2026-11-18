import 'dart:convert';
import 'dart:typed_data';

const openAIDictationAuthorizeMethod = 'dictation.authorize';
const dictationSocketPath = '/dictation';
const dictationSampleRate = 16000;
const dictationMaxAudioBytes = dictationSampleRate * 2 * 600;
const dictationMaxFrameBytes = 64 * 1024;

String? dictationErrorMessage(Object failure) {
  final message = failure.toString();
  for (final known in [
    "Didn't quite catch that. Please try again",
    'Check your connection and try again',
    'Sign in to ChatGPT on this computer to use dictation',
    'Finish signing in before starting dictation',
    'Dictation is temporarily limited. Please try again later.',
    'The signed-in workspace changed. Start dictation again.',
    'Your current IP address is not authorized for this workspace.',
    'Start dictation again',
  ]) {
    if (message.contains(known)) return known;
  }
  return null;
}

Uint8List dictationWav(Uint8List pcm) {
  final data = ByteData(44);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, 36 + pcm.length, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, dictationSampleRate, Endian.little);
  data.setUint32(28, dictationSampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)..add(bytes)..add(pcm)).takeBytes();
}
