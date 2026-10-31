import 'dart:async';

import 'package:protocol/protocol.dart';

import 'package:tool_runtime/tool_runtime.dart';

class HostTools {
  HostTools(this.cwd, this.cancellation) {
    _runner = CommandRunner(cancellation);
  }
  final String cwd;
  final CancellationToken cancellation;
  final _commands = <int, _Command>{};
  int _next = 0;
  late final CommandRunner _runner;

  Future<Object?> call(String name, Object? raw) async {
    cancellation.throwIfCancelled();
    if (name == 'apply_patch') {
      if (raw is! String) {
        throw const FormatException('apply_patch expects a raw patch string');
      }
      return applyPatch(cwd, raw);
    }
    final input = jsonObject(raw);
    switch (name) {
      case 'exec_command':
        if (_commands.length >= 32) {
          throw StateError('Too many running command sessions');
        }
        if (input['tty'] == true) {
          throw UnsupportedError(
            'PTY allocation is not implemented; use tty:false',
          );
        }
        if (input['sandbox_permissions'] != null &&
            input['sandbox_permissions'] != 'use_default') {
          throw UnsupportedError('Permission escalation is not implemented');
        }
        final command = _Command(await _runner.start(
          input['shell'] as String? ?? defaultShell,
          [if (input['login'] != false) '-l', '-c', requiredString(input, 'cmd')],
          directory: input['workdir'] as String? ?? cwd,
        ));
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
          await command.process.write(chars);
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
    if (command.polling) {
      throw StateError('A poll is already pending for this command');
    }
    command.polling = true;
    final watch = Stopwatch()..start();
    try {
      final wait = Duration(
        milliseconds: (input['yield_time_ms'] as num? ?? defaultWait)
            .toInt()
            .clamp(minWait, maxWait),
      );
      await command.process.done
          .timeout(wait, onTimeout: () {})
          .asCancellable(cancellation);
      cancellation.throwIfCancelled();
      final text = command.process.takeOutput();
      final budget = ((input['max_output_tokens'] as num? ?? 10000).toInt() * 4)
          .clamp(1, maxToolOutputBytes);
      final code = command.process.exitCode;
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
    _runner.close();
    _commands.clear();
  }
}

class _Command {
  _Command(this.process);
  final RunningCommand process;
  bool polling = false;
}
