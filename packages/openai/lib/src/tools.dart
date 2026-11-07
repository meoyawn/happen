import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ai/ai.dart';
import 'package:code_mode/code_mode.dart' show truncateTextOutput;
import 'package:protocol/protocol.dart';

import 'package:tool_runtime/tool_runtime.dart';

class HostTools {
  HostTools(this.cwd, this.cancellation) {
    _runner = CommandRunner(cancellation);
    unawaited(_runner.prewarmShell(codexShell(), directory: cwd, cancellation: cancellation));
  }
  final String cwd;
  final CancellationToken cancellation;
  final _commands = <int, _Command>{};
  final _completions = <Future<void>>{};
  final _random = Random.secure();
  late final CommandRunner _runner;

  Future<Object?> call(String name, Object? raw, {required CancellationToken cancellation, String? cwd,
    String? callId, ToolItemEvent? onItem, ToolPatchEvent? onPatch}) async {
    this.cancellation.throwIfCancelled();
    cancellation.throwIfCancelled();
    final directory = cwd ?? this.cwd;
    if (name == 'apply_patch') {
      if (raw is! String) {
        throw const FormatException('apply_patch expects a raw patch string');
      }
      return applyPatch(directory, raw, cancellation: cancellation, callId: callId, onItem: onItem, onPatch: onPatch);
    }
    final input = jsonObject(raw);
    switch (name) {
      case 'clock__curr_time':
        return {'current_time': '${DateTime.now().toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} UTC'};
      case 'clock__sleep':
        final duration = input['duration_ms'];
        if (input.keys.any((key) => key != 'duration_ms') || duration is! int || duration < 1 || duration > 43200000) {
          return {'error': 'duration_ms must be between 1 and 43200000'};
        }
        final item = <String, dynamic>{'type': 'Extension', 'kind': 'clock.sleep', 'id': callId, 'durationMs': duration};
        await onItem?.call('started', item);
        final watch = Stopwatch()..start();
        try {
          await cancellableDelay(Duration(milliseconds: duration), cancellation.merge(this.cancellation));
          return {'output': 'Wall time: ${(watch.elapsedMicroseconds / 1000000).toStringAsFixed(4)} seconds\nSleep completed.'};
        } finally { await onItem?.call('completed', item); }
      case 'view_image':
        final path = requiredString(input, 'path');
        final images = await prepareInputAttachments([{
          'type': 'image', 'name': 'Image',
          'path': File.fromUri(Directory(directory).absolute.uri.resolveUri(Uri.file(path))).path,
          'detail': input['detail'] ?? 'high',
        }], cancellation: cancellation.merge(this.cancellation));
        final item = <String, dynamic>{'type': 'ImageView', 'id': callId,
          'path': File.fromUri(Directory(directory).absolute.uri.resolveUri(Uri.file(path))).path};
        final source = attachmentDataUrl(images.single);
        await onItem?.call('started', item);
        await onItem?.call('completed', {...item, 'image_url': source});
        return {'image_url': source, 'detail': images.single['detail']};
      case 'shell_command':
        final timeout = (input['timeout_ms'] as num? ?? 10000).toInt();
        if (timeout < 0) throw const FormatException('timeout_ms must be non-negative');
        final watch = Stopwatch()..start();
        final command = await _runner.start(
          codexShell(input['shell'] as String?),
          [if (input['login'] != false) '-l', '-c', requiredString(input, 'command')],
          directory: input['workdir'] as String? ?? directory,
          cancellation: cancellation,
          timeout: Duration(milliseconds: timeout),
          shellSnapshot: Directory(input['workdir'] as String? ?? directory).absolute.uri == Directory(directory).absolute.uri,
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
        if (input['sandbox_permissions'] != null &&
            input['sandbox_permissions'] != 'use_default') {
          throw UnsupportedError('Permission escalation is not implemented');
        }
        final shell = codexShell(input['shell'] as String?), text = requiredString(input, 'cmd');
        final args = [if (input['login'] != false) '-l', '-c', text];
        final workdir = Directory(directory).absolute.uri.resolveUri(Uri.directory(input['workdir'] as String? ?? '.')).toFilePath();
        // Core tools/events.rs owns the lifecycle, not the model's function
        // output. Even an already-exited process retains its allocated ID.
        final item = <String, dynamic>{'type': 'CommandExecution', 'id': callId,
          'command': [shell, ...args], 'cwd': workdir, 'parsed_cmd': [{'type': 'unknown', 'cmd': text}],
          'source': 'unified_exec_startup', 'status': 'in_progress', 'process_id': null,
          'plugin_id': null, 'script_path': null, 'aggregated_output': null, 'exit_code': null, 'duration': null};
        final _Command command;
        try {
          command = _Command(await _runner.start(shell, args, directory: workdir,
            cancellation: this.cancellation, tty: input['tty'] == true,
            shellSnapshot: Directory(workdir).absolute.uri == Directory(directory).absolute.uri));
        } catch (error) {
          cancellation.throwIfCancelled();
          final message = 'Failed to create unified exec process: $error';
          await onItem?.call('started', item);
          await onItem?.call('completed', {...item, 'status': 'failed', 'aggregated_output': message,
            'exit_code': -1, 'duration': {'secs': 0, 'nanos': 0}});
          throw StateError(message);
        }
        var id = 1000 + _random.nextInt(99000);
        while (_commands.containsKey(id)) { id = 1000 + _random.nextInt(99000); }
        _commands[id] = command;
        item['process_id'] = '$id';
        await onItem?.call('started', item);
        if (onItem != null) {
          final completion = command.completion = _completeCommand(command, item, onItem);
          _completions.add(completion);
          unawaited(completion.then<void>((_) => _completions.remove(completion),
            onError: (Object _, StackTrace _) { _completions.remove(completion); }));
        }
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
      final tokens = (input['max_output_tokens'] as num? ?? 10000).toInt().clamp(0, maxToolOutputBytes ~/ 4);
      final code = command.process.exitCode;
      if (code != null) await command.completion;
      if (code != null) _commands.remove(id);
      return {
        'chunk_id': _random.nextInt(0x1000000).toRadixString(16).padLeft(6, '0'),
        'wall_time_seconds': watch.elapsedMicroseconds / 1000000,
        if (code != null) 'exit_code': code else 'session_id': id,
        'original_token_count': (utf8.encode(text).length + 3) ~/ 4,
        'output': truncateTextOutput(text, maxTokens: tokens),
      };
    } finally {
      link.dispose();
      waiting.cancel();
      command.polling = false;
    }
  }

  Future<void> close() async {
    await _runner.close();
    await Future.wait(_completions.toList());
    _commands.clear();
  }

  // Codex unified_exec/async_watcher.rs: finish the original command exactly
  // once, independently of yield/poll boundaries and inference-isolate lifetime.
  Future<void> _completeCommand(_Command command, Json item, ToolItemEvent emit) async {
    final watch = Stopwatch()..start();
    await command.process.done;
    final cleanup = TimeoutCancellationToken(const Duration(seconds: 10));
    try {
      final output = await command.process.capture(maxBytes: maxToolOutputBytes, cancellation: cleanup);
      final milliseconds = watch.elapsedMilliseconds;
      await emit('completed', {...item, 'status': command.process.exitCode == 0 ? 'completed' : 'failed',
        'aggregated_output': output.text, 'exit_code': command.process.exitCode,
        'duration': {'secs': milliseconds ~/ 1000, 'nanos': milliseconds % 1000 * 1000000}});
    } finally { cleanup.cancel(); }
  }
}

class _Command {
  _Command(this.process);
  final RunningCommand process;
  Future<void> completion = Future<void>.value();
  bool polling = false;
}
