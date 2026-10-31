import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

String get defaultShell => Platform.environment['AGENT_SHELL'] ??
    Platform.environment['SHELL'] ?? (Platform.isWindows ? 'cmd.exe' : 'fish');

/// Shared process ownership and capture, independent of model tool contracts.
class CommandRunner {
  CommandRunner(this.cancellation) {
    _hook = CancellationHook(cancellation, close);
  }
  final CancellationToken cancellation;
  final _commands = <RunningCommand>{};
  CancellationHook? _hook;

  Future<RunningCommand> start(String executable, List<String> arguments, {
    required String directory,
    Duration? timeout,
  }) async {
    cancellation.throwIfCancelled();
    final folder = Directory('${Directory.systemTemp.path}/happen-tool-output');
    await folder.create(recursive: true);
    cancellation.throwIfCancelled();
    final process = await Process.start(executable, arguments, workingDirectory: directory);
    if (cancellation.isCancelled) {
      process.kill(ProcessSignal.sigkill);
      cancellation.throwIfCancelled();
    }
    final command = RunningCommand._(process, File('${folder.path}/${newId()}.txt'), timeout);
    _commands.add(command);
    unawaited(command.done.then<void>((_) => _commands.remove(command), onError: (Object _, StackTrace _) {
      _commands.remove(command);
    }));
    return command;
  }

  void close() {
    _hook?.dispose(); _hook = null;
    for (final command in _commands) { command.kill(); }
    _commands.clear();
  }
}

class RunningCommand {
  RunningCommand._(this._process, this.outputFile, Duration? timeout) {
    final sink = outputFile.openWrite();
    void append(String value) {
      final available = maxToolOutputBytes - _output.length;
      if (available > 0) _output.write(value.substring(0, value.length.clamp(0, available)));
      if (value.length > available) _truncated = true;
    }
    final timer = timeout == null ? null : Timer(timeout, () { timedOut = true; kill(); });
    done = Future.wait([
      for (final stream in [_process.stdout, _process.stderr]) stream.map((bytes) {
        sink.add(bytes); return bytes;
      }).transform(const Utf8Decoder(allowMalformed: true)).forEach(append),
      _process.exitCode,
    ]).then((results) async {
      await sink.close();
      exitCode = results.last as int;
    }).whenComplete(() async { timer?.cancel(); await sink.close(); });
    unawaited(done.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  final Process _process;
  final File outputFile;
  late final Future<void> done;
  int? exitCode;
  bool timedOut = false;
  final _output = StringBuffer();
  bool _truncated = false;

  Future<void> write(String chars) async {
    if (chars == '\u0003') { _process.kill(ProcessSignal.sigint); return; }
    _process.stdin.write(chars);
    await _process.stdin.flush();
  }
  void kill() => _process.kill(ProcessSignal.sigkill);
  String takeOutput() {
    final text = '${_output.toString()}${_truncated ? '\n[output truncated]' : ''}';
    _output.clear(); _truncated = false; return text;
  }

  Future<({String text, bool truncated})> capture({int? maxBytes = 50 * 1024}) async {
    await done;
    final size = await outputFile.length();
    final truncated = maxBytes != null && size > maxBytes;
    final bytes = await outputFile.openRead(truncated ? size - maxBytes : 0)
        .fold<List<int>>([], (result, chunk) => result..addAll(chunk));
    return (text: utf8.decode(bytes, allowMalformed: true), truncated: truncated);
  }
}
