import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'patch.dart';

class HostTools {
  HostTools(this.cwd, this.cancellation) {
    _hook = CancellationHook(cancellation, close);
  }
  final String cwd;
  final CancellationToken cancellation;
  final _commands = <int, _Command>{};
  int _next = 0;
  CancellationHook? _hook;

  Future<Object?> call(String name, Object? raw) async {
    cancellation.throwIfCancelled();
    if (name == 'apply_patch') {
      if (raw is! String)
        throw const FormatException('apply_patch expects a raw patch string');
      return applyPatch(cwd, raw);
    }
    final input = jsonObject(raw);
    switch (name) {
      case 'exec_command':
        if (_commands.length >= 32)
          throw StateError('Too many running command sessions');
        if (input['tty'] == true)
          throw UnsupportedError(
            'PTY allocation is not implemented; use tty:false',
          );
        if (input['sandbox_permissions'] != null &&
            input['sandbox_permissions'] != 'use_default') {
          throw UnsupportedError('Permission escalation is not implemented');
        }
        final shell =
            input['shell'] as String? ??
            Platform.environment['AGENT_SHELL'] ??
            'fish';
        final process = await Process.start(shell, [
          if (input['login'] != false) '-l',
          '-c',
          requiredString(input, 'cmd'),
        ], workingDirectory: input['workdir'] as String? ?? cwd);
        if (cancellation.isCancelled) {
          process.kill(ProcessSignal.sigkill);
          cancellation.throwIfCancelled();
        }
        final command = _Command(process);
        final id = ++_next;
        _commands[id] = command;
        return _poll(
          id,
          input,
          defaultWait: 10000,
          maxWait: 30000,
          minWait: 250,
        );
      case 'write_stdin':
        final id = input['session_id'] as int;
        final command = _commands[id];
        if (command == null) throw StateError('Unknown command session: $id');
        final chars = input['chars'] as String? ?? '';
        if (chars.isNotEmpty) {
          if (chars == '\u0003') {
            command.process.kill(ProcessSignal.sigint);
          } else {
            command.process.stdin.write(chars);
            await command.process.stdin.flush();
          }
        }
        return _poll(
          id,
          input,
          defaultWait: chars.isEmpty ? 5000 : 250,
          maxWait: chars.isEmpty ? 300000 : 30000,
          minWait: 1,
        );
      default:
        throw StateError('Unknown tool: $name');
    }
  }

  Future<Json> _poll(
    int id,
    Json input, {
    required int defaultWait,
    required int maxWait,
    required int minWait,
  }) async {
    final command = _commands[id]!;
    if (command.polling)
      throw StateError('A poll is already pending for this command');
    command.polling = true;
    final watch = Stopwatch()..start();
    try {
      final wait = Duration(
        milliseconds: (input['yield_time_ms'] as num? ?? defaultWait)
            .toInt()
            .clamp(minWait, maxWait),
      );
      await command.done
          .timeout(wait, onTimeout: () {})
          .asCancellable(cancellation);
      cancellation.throwIfCancelled();
      final text = command.take();
      final budget = ((input['max_output_tokens'] as num? ?? 10000).toInt() * 4)
          .clamp(1, maxToolOutputBytes);
      final code = command.exitCode;
      if (code != null) _commands.remove(id);
      return {
        'chunk_id': newId(),
        'wall_time_seconds': watch.elapsedMicroseconds / 1000000,
        if (code != null) 'exit_code': code else 'session_id': id,
        'original_token_count': (text.length / 4).ceil(),
        'output': clippedText(text, budget),
      };
    } finally {
      command.polling = false;
    }
  }

  void close() {
    _hook?.dispose();
    _hook = null;
    for (final command in _commands.values) {
      command.process.kill(ProcessSignal.sigkill);
    }
    _commands.clear();
  }
}

class _Command {
  _Command(this.process) {
    done = Future.wait([
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(_append),
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(_append),
      process.exitCode.then((code) {
        exitCode = code;
      }),
    ]).then((_) {});
    unawaited(done.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  final Process process;
  late final Future<void> done;
  int? exitCode;
  bool polling = false, truncated = false;
  final _output = StringBuffer();
  void _append(String value) {
    final available = maxToolOutputBytes - _output.length;
    if (available > 0)
      _output.write(value.substring(0, value.length.clamp(0, available)));
    if (value.length > available) truncated = true;
  }

  String take() {
    final result =
        _output.toString() + (truncated ? '\n[output truncated]' : '');
    _output.clear();
    truncated = false;
    return result;
  }
}
