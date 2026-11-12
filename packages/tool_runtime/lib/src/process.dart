import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:protocol/protocol.dart';

import 'shell_snapshot_scripts.dart';

part 'shell_snapshot.dart';

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
  final _snapshotCancellation = CancellationToken();
  final _snapshots = <String, _ShellCapture>{};
  final _captures = <Future<_ShellSnapshot?>>{};

  /// Speculative initialization never blocks the model and belongs to this
  /// runtime, rather than any individual tool call.
  Future<void> prewarmShell(String executable, {required String directory,
    required CancellationToken cancellation}) async {
    try {
      cancellation.throwIfCancelled();
      await _snapshotFor(this, executable, directory, prewarm: true)
          .asCancellable(cancellation);
    } on CancelledException { /* Owner shutdown aborts speculative capture. */ }
  }

  Future<RunningCommand> start(String executable, List<String> arguments, {
    required String directory,
    required CancellationToken cancellation,
    Duration? timeout,
    bool tty = false,
    bool shellSnapshot = false,
  }) {
    this.cancellation.throwIfCancelled();
    cancellation.throwIfCancelled();
    // execve and PTY argv cannot represent NUL. Do not let native CString
    // conversion silently run a truncated command instead of failing launch.
    if ([executable, directory, ...arguments].any((value) => value.contains('\u0000'))) {
      throw const FormatException('Process arguments and working directory must not contain NUL');
    }
    if (_closing != null) throw StateError('Command runner is closed');
    final operation = _start(executable, arguments, directory, cancellation, timeout, tty, shellSnapshot);
    _starting.add(operation);
    unawaited(operation.then<void>((_) => _starting.remove(operation),
      onError: (Object _, StackTrace _) { _starting.remove(operation); }));
    return operation;
  }

  Future<RunningCommand> _start(String executable, List<String> arguments,
    String directory, CancellationToken cancellation, Duration? timeout, bool tty, bool shellSnapshot) async {
    Directory? transport;
    Future<void>? settled;
    Map<String, String>? environment;
    if (shellSnapshot && _snapshotShell(executable) != null &&
        arguments.length == 3 && arguments[0] == '-l' && arguments[1] == '-c') {
      final snapshot = await _snapshotFor(this, executable, directory)
          .asCancellable(cancellation.merge(this.cancellation));
      if (snapshot != null) {
        try {
          final replay = await _replayShell(snapshot, _snapshotShell(executable)!, arguments,
              cancellation: cancellation.merge(this.cancellation));
          arguments = replay.arguments;
          environment = replay.environment;
          transport = replay.transport;
        } on FileSystemException { /* Preserve ordinary login startup on transport failure. */ }
        on FormatException { /* Preserve fallback when env-only replay exceeds its launch budget. */ }
      }
    }
    try {
      final folder = Directory('${Directory.systemTemp.path}/happen-tool-output');
      await folder.create(recursive: true);
      this.cancellation.throwIfCancelled();
      cancellation.throwIfCancelled();
      // A supervisor owns a separate POSIX job group. Killing just the requested
      // shell can otherwise leave curl, git, or a pipeline holding its pipes open.
      final file = File('${folder.path}/${newId()}.txt');
      final RunningCommand command;
      if (tty) {
        // Own the eventual session even when cancellation races native spawn.
        final terminal = await Pty.spawn(PtySpawnOptions(
          executable: Platform.isWindows ? executable : '/bin/bash',
          arguments: Platform.isWindows ? arguments : ['--noprofile', '--norc', '-c', _ptyLaunch,
            'happen-pty', transport?.path ?? '', executable, ...arguments], workingDirectory: directory,
          environment: PtyEnvironment.replace({...(environment ?? Platform.environment), 'TERM': 'xterm-256color'})));
        command = RunningCommand._terminal(terminal, file, timeout);
      } else {
        final process = await Process.start(
          Platform.isWindows ? executable : '/bin/bash',
          Platform.isWindows ? arguments : ['--noprofile', '--norc', '-c', _supervisor, 'happen-command', transport?.path ?? '', executable, ...arguments],
          workingDirectory: directory,
          environment: environment,
        );
        command = RunningCommand._(process, file, timeout);
      }
      _commands.add(command);
      settled = command.done;
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
    } finally {
      if (transport != null) {
        final owned = transport;
        if (settled == null) {
          await _removeShellTransport(owned);
        } else {
          unawaited(settled.then<void>((_) => _removeShellTransport(owned),
              onError: (Object _, StackTrace _) => _removeShellTransport(owned)));
        }
      }
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _hook?.dispose(); _hook = null;
    _snapshotCancellation.cancel();
    for (final entry in _snapshots.values) { entry.retire(); }
    await Future.wait(_captures.toList().map((operation) => operation.then<void>((_) {},
        onError: (Object _, StackTrace _) {})));
    _snapshots.clear();
    await Future.wait(_starting.toList().map((operation) => operation.then<void>((_) {},
      onError: (Object _, StackTrace _) {})));
    final commands = _commands.toList();
    for (final command in _commands) { command.kill(); }
    await Future.wait(commands.map((command) => command.done));
    _commands.clear();
  }
}

const _supervisor = _openSnapshot + r'''
set -m
"$@" <&0 &
child=$!
trap 'trap - TERM INT HUP EXIT; kill -KILL -- -"$child" 2>/dev/null; wait "$child" 2>/dev/null' TERM INT HUP EXIT
wait "$child" 2>/dev/null
result=$?
exit "$result"
''';

// The native PTY owns child supervision and exit status. Only snapshot replay
// needs a shell step before handing over to the requested executable.
const _ptyLaunch = _openSnapshot + r'''
exec "$@"
''';

class RunningCommand {
  RunningCommand._(Process process, this.outputFile, Duration? timeout) : _process = process, _terminal = null {
    _capture([process.stdout, process.stderr], process.exitCode, timeout);
  }
  RunningCommand._terminal(PtySession terminal, this.outputFile, Duration? timeout) : _terminal = terminal, _process = null {
    _capture([terminal.output], terminal.done.then((exit) => switch (exit) {
      PtyExitCode(:final code) => code, PtySignalExit(:final signal) => -signal,
    }), timeout);
  }
  void _capture(List<Stream<List<int>>> streams, Future<int> status, Duration? timeout) {
    final sink = outputFile.openWrite();
    void append(String value) {
      final available = maxToolOutputBytes - _output.length;
      if (available > 0) _output.write(value.substring(0, value.length.clamp(0, available)));
      if (value.length > available) _truncated = true;
    }
    final timer = timeout == null ? null : Timer(timeout, () { timedOut = true; kill(); });
    done = Future.wait([
      for (final stream in streams) stream.map((bytes) {
        sink.add(bytes); return bytes;
      }).transform(const Utf8Decoder(allowMalformed: true)).forEach(append),
      status,
    ]).then((results) {
      exitCode = results.last as int;
    }).whenComplete(() async {
      timer?.cancel();
      try { await sink.close(); }
      finally { await _terminal?.close(); }
    });
    unawaited(done.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  final Process? _process;
  final PtySession? _terminal;
  final File outputFile;
  late final Future<void> done;
  int? exitCode;
  bool timedOut = false;
  final _output = StringBuffer();
  bool _truncated = false;
  bool _killed = false;

  Future<void> write(String chars, {required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    if (_terminal case final terminal?) {
      // Keep large writes cooperative between bounded terminal input chunks.
      for (var offset = 0; offset < chars.length;) {
        cancellation.throwIfCancelled();
        var end = (offset + 1024).clamp(0, chars.length);
        if (end < chars.length && chars.codeUnitAt(end - 1) >= 0xd800 && chars.codeUnitAt(end - 1) <= 0xdbff) end--;
        await terminal.input.writeUtf8(chars.substring(offset, end)).asCancellable(cancellation);
        offset = end;
        await cancellableDelay(Duration.zero, cancellation);
      }
      return;
    }
    final process = _process!;
    if (chars == '\u0003') { process.kill(ProcessSignal.sigint); return; }
    process.stdin.write(chars);
    await process.stdin.flush().asCancellable(cancellation);
  }
  void kill() {
    if (_killed || exitCode != null) return;
    _killed = true;
    if (_terminal case final terminal?) {
      try { terminal.kill(); }
      on PtyClosedException { /* Native shutdown already owns the process. */ }
      return;
    }
    final process = _process!;
    if (Platform.isWindows) {
      unawaited(Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']).then<void>((result) {
        if (result.exitCode != 0) process.kill();
      },
        onError: (Object _, StackTrace _) { process.kill(); }));
    } else {
      process.kill(ProcessSignal.sigterm);
    }
  }
  String takeOutput() {
    final text = '$_output${_truncated ? '\n[output truncated]' : ''}';
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
