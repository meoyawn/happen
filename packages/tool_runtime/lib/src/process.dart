import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

String get defaultShell => Platform.environment['AGENT_SHELL'] ??
    Platform.environment['SHELL'] ?? (Platform.isWindows ? 'cmd.exe' : 'fish');

/// Shared process ownership and capture, independent of model tool contracts.
class CommandRunner {
  CommandRunner(this.cancellation) {
    _hook = CancellationHook(cancellation, () => unawaited(close()));
  }
  final CancellationToken cancellation;
  final _commands = <RunningCommand>{};
  CancellationHook? _hook;
  Future<void>? _closing;
  final _starting = <Future<RunningCommand>>{};

  Future<RunningCommand> start(String executable, List<String> arguments, {
    required String directory,
    required CancellationToken cancellation,
    Duration? timeout,
  }) {
    this.cancellation.throwIfCancelled();
    cancellation.throwIfCancelled();
    if (_closing != null) throw StateError('Command runner is closed');
    final operation = _start(executable, arguments, directory, cancellation, timeout);
    _starting.add(operation);
    unawaited(operation.then<void>((_) => _starting.remove(operation),
      onError: (Object _, StackTrace _) { _starting.remove(operation); }));
    return operation;
  }

  Future<RunningCommand> _start(String executable, List<String> arguments,
    String directory, CancellationToken cancellation, Duration? timeout) async {
    final folder = Directory('${Directory.systemTemp.path}/happen-tool-output');
    await folder.create(recursive: true);
    this.cancellation.throwIfCancelled();
    cancellation.throwIfCancelled();
    // A supervisor owns a separate POSIX job group. Killing just the requested
    // shell can otherwise leave curl, git, or a pipeline holding its pipes open.
    final process = await Process.start(
      Platform.isWindows ? executable : '/bin/bash',
      Platform.isWindows ? arguments : ['--noprofile', '--norc', '-c', _supervisor, 'happen-command', executable, ...arguments],
      workingDirectory: directory,
    );
    final command = RunningCommand._(process, File('${folder.path}/${newId()}.txt'), timeout);
    _commands.add(command);
    final hook = CancellationHook(cancellation.merge(this.cancellation), command.kill);
    unawaited(command.done.then<void>((_) {
      hook.dispose(); _commands.remove(command);
    }, onError: (Object _, StackTrace _) {
      hook.dispose();
      _commands.remove(command);
    }));
    if (cancellation.isCancelled || this.cancellation.isCancelled || _closing != null) {
      command.kill();
      await command.done;
      this.cancellation.throwIfCancelled();
      cancellation.throwIfCancelled();
      throw StateError('Command runner is closed');
    }
    return command;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _hook?.dispose(); _hook = null;
    await Future.wait(_starting.toList().map((operation) => operation.then<void>((_) {},
      onError: (Object _, StackTrace _) {})));
    final commands = _commands.toList();
    for (final command in _commands) { command.kill(); }
    await Future.wait(commands.map((command) => command.done));
    _commands.clear();
  }
}

const _supervisor = r'''
set -m
"$@" <&0 &
child=$!
trap 'trap - TERM INT HUP EXIT; kill -KILL -- -"$child" 2>/dev/null; wait "$child" 2>/dev/null' TERM INT HUP EXIT
wait "$child" 2>/dev/null
result=$?
exit "$result"
''';

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
  bool _killed = false;

  Future<void> write(String chars, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    if (chars == '\u0003') { _process.kill(ProcessSignal.sigint); return; }
    _process.stdin.write(chars);
    await _process.stdin.flush().asCancellable(cancellation);
  }
  void kill() {
    if (_killed) return;
    _killed = true;
    if (Platform.isWindows) {
      unawaited(Process.run('taskkill', ['/PID', '${_process.pid}', '/T', '/F']).then<void>((result) {
        if (result.exitCode != 0) _process.kill();
      },
        onError: (Object _, StackTrace _) { _process.kill(); }));
    } else {
      _process.kill(ProcessSignal.sigterm);
    }
  }
  String takeOutput() {
    final text = '${_output.toString()}${_truncated ? '\n[output truncated]' : ''}';
    _output.clear(); _truncated = false; return text;
  }

  Future<({String text, bool truncated})> capture({int? maxBytes = 50 * 1024, required CancellationToken cancellation}) async {
    await done.asCancellable(cancellation);
    cancellation.throwIfCancelled();
    final size = await outputFile.length();
    final truncated = maxBytes != null && size > maxBytes;
    final input = ownStream(outputFile.openRead(truncated ? size - maxBytes : 0), cancellation);
    try {
      final bytes = await input.stream.fold<List<int>>([], (result, chunk) => result..addAll(chunk)).asCancellable(cancellation);
      cancellation.throwIfCancelled();
      return (text: utf8.decode(bytes, allowMalformed: true), truncated: truncated);
    } finally { await input.close(); }
  }
}
