import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

// Sends a supplied 16 kHz mono PCM16 WAV directly through the desktop protocol.
// Credentials come from a running local Happen server and are never printed.
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('Usage: dart run tool/verify_dictation.dart SOCKET_PATH PCM16_WAV_PATH');
    exitCode = 64;
    return;
  }
  final cancellation = CancellationToken();
  final limit = Timer(const Duration(seconds: 45), cancellation.cancel);
  AgentClient? client;
  final clock = Stopwatch()..start();
  var stopping = false, partials = 0;
  final stream = TranscriptionStream(onTranscript: (text) {
    if (!stopping) partials++;
    print(jsonEncode({'event': stopping ? 'finalizing' : 'live_text', 'ms': clock.elapsedMilliseconds, 'characters': text.length}));
  }, onError: () => print('{"event":"stream_failed"}'));
  try {
    client = await AgentClient.connect(Uri(scheme: 'unix', path: args[0]), cancellation: cancellation);
    final auth = await client.desktopAuthorization(cancellation: cancellation);
    final wav = await File(args[1]).readAsBytes();
    final data = ByteData.sublistView(wav);
    if (wav.length < 12 || ascii.decode(wav.sublist(0, 4)) != 'RIFF' || ascii.decode(wav.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('Expected a WAV file');
    }
    Uint8List? pcm;
    var formatMatches = false;
    for (var offset = 12; offset + 8 <= wav.length;) {
      final length = data.getUint32(offset + 4, Endian.little);
      if (offset + 8 + length > wav.length) throw const FormatException('Truncated WAV chunk');
      if (ascii.decode(wav.sublist(offset, offset + 4)) == 'fmt ' && length >= 16) {
        formatMatches = data.getUint16(offset + 8, Endian.little) == 1 &&
          data.getUint16(offset + 10, Endian.little) == 1 &&
          data.getUint32(offset + 12, Endian.little) == 16000 &&
          data.getUint16(offset + 22, Endian.little) == 16;
      }
      if (ascii.decode(wav.sublist(offset, offset + 4)) == 'data') {
        pcm = Uint8List.sublistView(wav, offset + 8, offset + 8 + length);
        break;
      }
      offset += 8 + length + length % 2;
    }
    if (!formatMatches || pcm == null || pcm.isEmpty || pcm.length % 2 != 0) {
      throw const FormatException('Expected 16 kHz mono PCM16 WAV data');
    }
    await stream.connect(auth, cancellation: cancellation);
    print('{"event":"connected"}');
    for (var offset = 0; offset < pcm.length; offset += 3200) {
      stream.append(Uint8List.sublistView(pcm, offset, (offset + 3200).clamp(0, pcm.length)));
      await cancellableDelay(const Duration(milliseconds: 100), cancellation);
    }
    for (var i = 0; i < 10; i++) {
      stream.append(Uint8List(3200));
      await cancellableDelay(const Duration(milliseconds: 100), cancellation);
    }
    stopping = true;
    final text = await stream.finish();
    print(jsonEncode({'event': 'completed', 'live_updates': partials, 'text': text, 'ms': clock.elapsedMilliseconds}));
    if (partials == 0) exitCode = 2;
  } catch (error) {
    print(jsonEncode({'event': 'probe_failed', 'kind': error.runtimeType.toString()}));
    exitCode = 1;
  } finally {
    limit.cancel();
    cancellation.cancel();
    stream.close();
    await client?.close();
  }
}
