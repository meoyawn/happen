import 'dart:async';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'package:tool_runtime/tool_runtime.dart';

class HostTools {
  HostTools(this.cwd, this.cancellation) {
    _runner = CommandRunner(cancellation);
  }
  final String cwd;
  final CancellationToken cancellation;
  final _commands = <int, _Command>{};
  late final CommandRunner _runner;

  Future<Object?> call(String name, Object? raw, {required CancellationToken cancellation, String? cwd}) async {
    this.cancellation.throwIfCancelled();
    cancellation.throwIfCancelled();
    final directory = cwd ?? this.cwd;
    if (name == 'apply_patch') {
      if (raw is! String) {
        throw const FormatException('apply_patch expects a raw patch string');
      }
      return applyPatch(directory, raw, cancellation: cancellation);
    }
    final input = jsonObject(raw);
    switch (name) {
      case 'view_image':
        final path = requiredString(input, 'path');
        final images = await prepareInputAttachments([{
          'type': 'image', 'name': 'Image',
          'path': File.fromUri(Directory(directory).absolute.uri.resolveUri(Uri.file(path))).path,
          'detail': input['detail'] ?? 'high',
        }], cancellation: cancellation.merge(this.cancellation));
        return {'image_url': attachmentDataUrl(images.single), 'detail': images.single['detail']};
      case 'shell_command':
        final timeout = (input['timeout_ms'] as num? ?? 10000).toInt();
        if (timeout < 0) throw const FormatException('timeout_ms must be non-negative');
        final watch = Stopwatch()..start();
        final command = await _runner.start(
          input['shell'] as String? ?? defaultShell,
          [if (input['login'] != false) '-l', '-c', requiredString(input, 'command')],
          directory: input['workdir'] as String? ?? directory,
          cancellation: cancellation,
          timeout: Duration(milliseconds: timeout),
        );
        try {
          await command.done.asCancellable(cancellation);
          cancellation.throwIfCancelled();
          if (command.timedOut) throw TimeoutException('Shell command timed out', Duration(milliseconds: timeout));
          final text = command.takeOutput();
          return {
            'wall_time_seconds': watch.elapsedMicroseconds / 1000000,
            'exit_code': command.exitCode,
            'output': clippedText(text, ((input['max_output_tokens'] as num? ?? 10000).toInt() * 4).clamp(1, maxToolOutputBytes)),
          };
        } finally {
          if (command.exitCode == null) command.kill();
          await command.done;
        }
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
          directory: input['workdir'] as String? ?? directory,
          cancellation: this.cancellation,
        ));
        var id = int.parse(newId().substring(0, 13), radix: 16);
        while (_commands.containsKey(id)) { id = int.parse(newId().substring(0, 13), radix: 16); }
        _commands[id] = command;
        return _poll(
          id,
          input,
          defaultWait: 10000,
          maxWait: 30000,
          minWait: 250,
          cancellation: cancellation,
        );
      case 'write_stdin':
        final id = input['session_id'] as int;
        final command = _commands[id];
        if (command == null) throw StateError('Unknown command session: $id');
        final chars = input['chars'] as String? ?? '';
        if (chars.isNotEmpty) {
          await command.process.write(chars, cancellation: cancellation);
        }
        return _poll(
          id,
          input,
          defaultWait: chars.isEmpty ? 5000 : 250,
          maxWait: chars.isEmpty ? 300000 : 30000,
          minWait: 1,
          cancellation: cancellation,
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
    required CancellationToken cancellation,
  }) async {
    final command = _commands[id]!;
    if (command.polling) {
      throw StateError('A poll is already pending for this command');
    }
    command.polling = true;
    final watch = Stopwatch()..start();
    final waiting = CancellationToken();
    final link = CancellationHook(cancellation.merge(this.cancellation), waiting.cancel);
    try {
      final wait = Duration(
        milliseconds: (input['yield_time_ms'] as num? ?? defaultWait)
            .toInt()
            .clamp(minWait, maxWait),
      );
      await Future.any<void>([command.process.done, cancellableDelay(wait, waiting)]).asCancellable(waiting);
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
      link.dispose();
      waiting.cancel();
      command.polling = false;
    }
  }

  Future<void> close() async {
    await _runner.close();
    _commands.clear();
  }
}

class _Command {
  _Command(this.process);
  final RunningCommand process;
  bool polling = false;
}
