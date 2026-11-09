import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:protocol/protocol.dart';

import 'terminal_process.dart';

/// The execution host owns shells; the connection owns their lifetime.
class ServerTerminals {
  ServerTerminals(this.emit);
  final void Function(String owner, Json event) emit;
  final _events = ReceivePort();
  final _owners = <String>{};
  Future<IsolateOwner>? _starting;
  Future<void>? _closing;

  Future<IsolateOwner> _start() async {
    _events.listen((raw) {
      final message = jsonObject(raw);
      final owner = message['owner'] as String;
      if (_owners.contains(owner)) emit(owner, jsonObject(message['event']));
    });
    final worker = await IsolateOwner.start(_terminalMain, {'events': _events.sendPort}, service: 'server.terminals');
    unawaited(worker.done.then((_) {
      if (_closing == null) {
        for (final owner in _owners) {
          emit(owner, {'method': 'terminal/unavailable', 'params': {'message': 'Terminal worker stopped. Open a new terminal.'}});
        }
      }
    }));
    return worker;
  }

  Future<Json> request(String owner, String method, Json params, CancellationToken cancellation) async {
    if (_closing != null) throw StateError('Terminals are closing');
    _owners.add(owner);
    final worker = await (_starting ??= _start()).asCancellable(cancellation);
    cancellation.throwIfCancelled();
    return jsonObject(await callIsolate(worker.port, method, {...params, 'owner': owner}, cancellation: cancellation));
  }

  Future<void> detach(String owner) async {
    _owners.remove(owner);
    if (_starting == null || _closing != null) return;
    await callIsolate((await _starting!).port, 'detach', {'owner': owner}, timeout: const Duration(seconds: 10));
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try { if (_starting != null) await (await _starting!).close(); }
    finally { _events.close(); _owners.clear(); }
  }
}

Future<void> _terminalMain(List<Object?> arguments) async {
  final events = jsonObject(arguments[1])['events'] as SendPort;
  final inbox = ReceivePort();
  final terminals = <String, _TerminalProcess>{};
  final operations = <Object?, CancellationToken>{};
  final pending = <Future<void>>{};
  var closing = false;
  (arguments[0] as SendPort).send(inbox.sendPort);
  inbox.listen((raw) {
    final request = jsonObject(raw), reply = request['reply'] as SendPort?;
    final method = request['method'] as String;
    if (method == 'cancel') { operations[request['params']['operation_id']]?.cancel(); return; }
    final params = jsonObject(request['params']);
    if (method == 'close') {
      closing = true;
      for (final token in operations.values) { token.cancel(); }
      unawaited(() async {
        try {
          await Future.wait(terminals.values.toList().map((terminal) => terminal.close()));
          await Future.wait(pending.toList());
          reply?.send({'result': null});
        } catch (error) { reply?.send({'error': error.toString()}); }
        finally { inbox.close(); }
      }());
      return;
    }
    if (closing) { reply?.send({'error': 'Terminals are closing'}); return; }
    final cancellation = CancellationToken();
    operations[request['operation_id']] = cancellation;
    late final Future<void> operation;
    operation = Future<void>(() async {
      try {
        final owner = requiredString(params, 'owner');
        if (method == 'detach') {
          final owned = terminals.values.where((terminal) => terminal.owner == owner).toList();
          await Future.wait(owned.map((terminal) => terminal.close()));
          for (final terminal in owned) { terminals.remove(terminal.id); }
          reply?.send({'result': <String, dynamic>{}});
          return;
        }
        final id = requiredString(params, 'terminalId'); validateTaskId(id);
        var terminal = terminals[id];
        if (terminal != null && terminal.owner != owner) throw StateError('Terminal belongs to another connection');
        Object? result;
        switch (method) {
          case 'terminal/open':
            if (terminal != null) throw StateError('Terminal is already open');
            if (terminals.values.where((terminal) => terminal.owner == owner).length >= 16) {
              throw StateError('Close a terminal before opening another');
            }
            final cwd = requiredString(params, 'cwd');
            if (cwd.contains('\x00')) throw const FormatException('Invalid terminal directory');
            final command = params['command'] as String?;
            if (command != null && (command.length > 65536 || command.contains('\x00'))) {
              throw const FormatException('Invalid terminal command');
            }
            terminal = _TerminalProcess(owner, id, (event) => events.send({'owner': owner, 'event': event}));
            terminals[id] = terminal;
            try { result = await terminal.open(cwd, command, _size(params), cancellation); }
            catch (_) { await terminal.close(); terminals.remove(id); rethrow; }
          case 'terminal/close':
            await terminal?.close();
            terminals.remove(id);
            result = <String, dynamic>{};
          case 'terminal/write':
            if (terminal == null) throw StateError('Terminal is closed');
            final data = requiredString(params, 'data');
            if (data.length > 65536) throw const FormatException('Terminal input is too large');
            await terminal.write(data, cancellation);
            result = <String, dynamic>{};
          case 'terminal/resize':
            if (terminal == null) throw StateError('Terminal is closed');
            terminal.resize(_size(params));
            result = <String, dynamic>{};
          case 'terminal/ack':
            terminal?.acknowledge(params['sequence'] as int);
            result = <String, dynamic>{};
          default: throw ArgumentError('Unknown terminal operation');
        }
        reply?.send({'result': result});
      } catch (error) {
        reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
      } finally {
        operations.remove(request['operation_id']);
        pending.remove(operation);
      }
    });
    pending.add(operation);
  });
}

PtySize _size(Json params) {
  final columns = params['columns'] as int? ?? 80, rows = params['rows'] as int? ?? 24;
  if (columns < 1 || columns > 1000 || rows < 1 || rows > 1000) throw const FormatException('Invalid terminal dimensions');
  return PtySize(columns: columns, rows: rows);
}

sealed class _TerminalState { const _TerminalState(); }
class _Starting extends _TerminalState { const _Starting(); }
class _Running extends _TerminalState { const _Running(this.session); final PtySession session; }
class _Exited extends _TerminalState { const _Exited(this.code); final int code; }
class _Failed extends _TerminalState { const _Failed(this.message, this.session); final String message; final PtySession? session; }
class _Closing extends _TerminalState { const _Closing(); }
class _Closed extends _TerminalState { const _Closed(); }

class _TerminalProcess {
  _TerminalProcess(this.owner, this.id, this.emit);
  final String owner, id;
  final void Function(Json) emit;
  final _lifetime = CancellationToken();
  _TerminalState _state = const _Starting();
  Future<Json>? _opening;
  Future<void>? _closing, _watching;
  StreamSubscription<String>? _output;
  final _outputDone = Completer<void>();
  final _unacknowledged = Queue<(int, int)>();
  int _sequence = 0, _pendingBytes = 0;

  void _transition(_TerminalState next) {
    final valid = switch ((_state, next)) {
      (_Starting(), _Running() || _Failed() || _Closing()) => true,
      (_Running(), _Exited() || _Failed() || _Closing()) => true,
      (_Exited() || _Failed(), _Closing()) => true,
      (_Closing(), _Closed()) => true,
      _ => false,
    };
    if (!valid) throw StateError('Invalid terminal transition: ${_state.runtimeType} to ${next.runtimeType}');
    _state = next;
  }

  void _event(String method, Json params) {
    if (!_lifetime.isCancelled) emit({'method': 'terminal/$method', 'params': {'terminalId': id, ...params}});
  }

  Future<Json> open(String cwd, String? command, PtySize size, CancellationToken cancellation) =>
    _opening = _open(cwd, command, size, cancellation);

  Future<Json> _open(String cwd, String? command, PtySize size, CancellationToken cancellation) async {
    final hook = CancellationHook(cancellation, () { unawaited(close()); });
    PtySession? pty;
    try {
      cancellation.throwIfCancelled(); _lifetime.throwIfCancelled();
      // Project scripts use portable shell syntax even when the user's login
      // shell is fish. Interactive terminals keep the host's preferred shell.
      final shell = Platform.isWindows ? 'powershell.exe'
        : command == null ? Platform.environment['SHELL'] ?? '/bin/sh' : '/bin/sh';
      // Own the eventual native handle even if cancellation races with spawn.
      pty = await Pty.spawn(PtySpawnOptions(executable: shell,
        arguments: command == null ? (Platform.isWindows ? const ['-NoLogo'] : const ['-il'])
          : Platform.isWindows ? ['-NoLogo', '-Command', command] : ['-c', command],
        workingDirectory: cwd, size: size, outputWindowBytes: 65536,
        environment: PtyEnvironment.inherit(overrides: const {'TERM': 'xterm-256color'}, remove: {
          ...Platform.environment.keys.where((key) => key.startsWith('MOON_')), 'TERMINFO', 'TERMINFO_DIRS',
        })));
      if (_lifetime.isCancelled || cancellation.isCancelled) {
        _kill(pty); await pty.close();
        throw const CancelledException();
      }
      _transition(_Running(pty));
      _output = pty.utf8Output().listen((data) {
        if (_lifetime.isCancelled) return;
        _pendingBytes += data.length * 2;
        _unacknowledged.add((++_sequence, data.length * 2));
        _event('output', {'sequence': _sequence, 'data': data});
        if (_pendingBytes >= 262144) _output?.pause();
      }, onError: (Object error) => _fail(error), onDone: () { if (!_outputDone.isCompleted) _outputDone.complete(); });
      _watching = _watch(pty);
      return {'terminalId': id, 'pid': pty.pid, 'platform': Platform.operatingSystem};
    } catch (error) {
      _fail(error);
      if (!_lifetime.isCancelled) await pty?.close();
      rethrow;
    } finally { hook.dispose(); }
  }

  Future<void> _watch(PtySession pty) async {
    try {
      final exit = await pty.done.asCancellable(_lifetime);
      await _outputDone.future.asCancellable(_lifetime);
      final code = switch (exit) { PtyExitCode(:final code) => code, PtySignalExit(:final signal) => -signal };
      _transition(_Exited(code));
      _event('exited', {'code': code});
      await pty.close();
    } on CancelledException { /* close() owns the process and native cleanup. */ }
    catch (error) { _fail(error); }
  }

  void _fail(Object error) {
    if (_lifetime.isCancelled || _state is _Failed || _state is _Exited) return;
    final session = switch (_state) { _Running(:final session) => session, _ => null };
    _transition(_Failed(error.toString(), session));
    _event('error', {'message': error.toString()});
    unawaited(close());
  }

  Future<void> write(String data, CancellationToken cancellation) async {
    final state = _state;
    if (state is! _Running) throw StateError('Terminal is not running');
    await state.session.input.writeUtf8(data).asCancellable(cancellation.merge(_lifetime));
  }

  void resize(PtySize size) {
    if (_state case _Running(:final session)) session.resize(size);
  }

  void acknowledge(int sequence) {
    if (sequence < 0 || sequence > _sequence) throw const FormatException('Invalid terminal acknowledgement');
    while (_unacknowledged.isNotEmpty && _unacknowledged.first.$1 <= sequence) {
      _pendingBytes -= _unacknowledged.removeFirst().$2;
    }
    if (_pendingBytes < 262144 && _output?.isPaused == true) _output!.resume();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    final session = switch (_state) { _Running(:final session) => session, _Failed(:final session) => session, _ => null };
    _transition(const _Closing());
    _lifetime.cancel();
    if (session != null) _kill(session);
    try {
      try { await _opening; } catch (_) { /* A cancelled spawn still releases its eventual handle. */ }
      await _output?.cancel();
      await session?.close();
      await _watching;
    } finally {
      _unacknowledged.clear();
      _transition(const _Closed());
    }
  }

  void _kill(PtySession pty) {
    try { killTerminalProcessTree(pty.pid); }
    catch (error) { stderr.writeln('Terminal process cleanup: $error'); }
    finally { try { pty.kill(); } on PtyException { /* Native close still drains resources. */ } }
  }
}
