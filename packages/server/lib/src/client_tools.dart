import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:protocol/protocol.dart';

/// Client tools belong to one live connection and one task. No browser state or
/// client credentials cross this boundary; the owner executes each request.
class ClientToolBridge {
  ClientToolBridge() {
    _mailbox.listen((raw) => unawaited(_handle(jsonObject(raw))));
  }

  final _mailbox = ReceivePort();
  final _registrations = <String, _Registration>{};
  final _calls = <String, _Call>{};
  bool _closed = false;
  SendPort get port => _mailbox.sendPort;

  Json register(
    String task,
    String owner,
    Object? raw,
    void Function(Json) send,
  ) {
    if (_closed) throw StateError('Client tool bridge is closed');
    final previous = _registrations[task];
    if (previous != null && previous.owner != owner) {
      throw StateError(
        'Client tools for this task belong to another connection',
      );
    }
    if (raw is! List ||
        raw.length > 128 ||
        utf8.encode(jsonEncode(raw)).length > 256 * 1024) {
      throw const FormatException('Client tool catalog exceeds its limit');
    }
    final tools = <String, Json>{};
    for (final value in raw) {
      final tool = jsonObject(value);
      final name = requiredString(tool, 'name');
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(name) ||
          tools.containsKey(name)) {
        throw const FormatException('Invalid or duplicate client tool name');
      }
      final schema = jsonObject(tool['inputSchema']);
      if (schema['type'] != 'object') {
        throw const FormatException(
          'Client tool inputSchema must describe an object',
        );
      }
      tools[name] = {
        'name': name,
        'description': requiredString(tool, 'description'),
        'parameters': schema,
        'format': 'json',
        'namespace': 'client',
      };
    }
    final registration = _Registration(owner, tools, send);
    _registrations[task] = registration;
    // Removed or replaced definitions invalidate only calls admitted under that
    // definition. An unchanged call keeps its original owner and result channel.
    for (final call
        in _calls.values.where((call) => call.task == task).toList()) {
      if (jsonEncode(previous?.tools[call.name]) !=
          jsonEncode(tools[call.name])) {
        _fail(
          call,
          'Client tool changed before its result arrived; its outcome is unknown',
        );
      }
    }
    if (tools.isEmpty) _registrations.remove(task);
    return snapshot(task);
  }

  Json snapshot(String task) => {
    'tools': [...?_registrations[task]?.tools.values],
  };

  void complete(String owner, Json message) {
    final call = _calls[message['id']];
    if (call == null || call.owner != owner) {
      throw StateError(
        'Client tool request is unknown or belongs to another connection',
      );
    }
    if (call.result.isCompleted)
      throw StateError('Client tool request is already complete');
    if (message.containsKey('error')) {
      call.result.completeError(
        StateError(
          'Client tool failed: ${clippedText(jsonEncode(message['error']), 4096)}',
        ),
      );
      return;
    }
    final result = jsonObject(message['result']);
    if (utf8.encode(jsonEncode(result)).length > maxToolOutputBytes) {
      call.result.completeError(
        StateError('Client tool output exceeds 64 KiB'),
      );
      return;
    }
    if (result['success'] is! bool ||
        result['contentItems'] is! List ||
        (result['contentItems'] as List).any(
          (value) =>
              value is! Map ||
              value['type'] != 'inputText' ||
              value['text'] is! String,
        )) {
      call.result.completeError(
        const FormatException(
          'Expected success and text contentItems from client tool',
        ),
      );
      return;
    }
    call.result.complete(result);
  }

  void detach(String owner) {
    _registrations.removeWhere(
      (_, registration) => registration.owner == owner,
    );
    for (final call
        in _calls.values.where((call) => call.owner == owner).toList()) {
      _fail(
        call,
        'Client disconnected before returning the tool result; its outcome is unknown',
      );
    }
  }

  void _fail(_Call call, String reason) {
    if (!call.result.isCompleted) call.result.completeError(StateError(reason));
    call.send({
      'method': 'tools.cancel',
      'params': {'call_id': call.id},
    });
  }

  Future<void> _handle(Json request) async {
    final reply = request['reply'] as SendPort?;
    final params = jsonObject(request['params']);
    final operation = request['operation_id'] as String?;
    _Call? call;
    TimeoutCancellationToken? deadline;
    try {
      if (request['method'] == 'cancel') {
        for (final pending
            in _calls.values
                .where((call) => call.operation == params['operation_id'])
                .toList()) {
          pending.cancellation.cancel();
        }
        reply?.send({'result': null});
        return;
      }
      if (_closed) throw StateError('Client tool bridge is closed');
      final task = requiredString(params, 'task_id');
      if (request['method'] == 'catalog') {
        reply?.send({'result': snapshot(task)});
        return;
      }
      if (request['method'] != 'call')
        throw StateError('Unknown client tool operation');
      final name = requiredString(params, 'name');
      final registration = _registrations[task];
      if (registration == null || !registration.tools.containsKey(name)) {
        throw StateError(
          'Client tool is unavailable; inspect the current catalog',
        );
      }
      if (_calls.length >= 256 ||
          _calls.values
                  .where((call) => call.owner == registration.owner)
                  .length >=
              32) {
        throw StateError('Too many pending client tool calls');
      }
      final arguments = jsonObject(params['arguments']);
      if (utf8.encode(jsonEncode(arguments)).length > 256 * 1024) {
        throw const FormatException('Client tool arguments exceed 256 KiB');
      }
      call = _Call(
        newId(),
        operation!,
        task,
        registration.owner,
        name,
        registration.send,
      );
      _calls[call.id] = call;
      deadline = TimeoutCancellationToken(const Duration(seconds: 60));
      final pendingCall = call;
      final result = call.result.future.asCancellable(
        call.cancellation.merge(deadline),
        onCancel: () {
          pendingCall.send({
            'method': 'tools.cancel',
            'params': {'call_id': pendingCall.id},
          });
        },
      );
      registration.send({
        'id': call.id,
        'method': 'tools.call',
        'params': {
          'task_id': task,
          'call_id': call.id,
          'namespace': 'client',
          'tool': name,
          'arguments': arguments,
        },
      });
      reply?.send({'result': await result});
    } catch (error) {
      reply?.send({
        'error': error.toString(),
        if (error is CancelledException) 'code': 'cancelled',
      });
    } finally {
      if (call != null) {
        _calls.remove(call.id);
        call.cancellation.cancel();
      }
      deadline?.cancel();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final call in _calls.values.toList()) {
      call.cancellation.cancel();
    }
    _registrations.clear();
    _mailbox.close();
  }
}

class _Registration {
  _Registration(this.owner, this.tools, this.send);
  final String owner;
  final Map<String, Json> tools;
  final void Function(Json) send;
}

class _Call {
  _Call(this.id, this.operation, this.task, this.owner, this.name, this.send);
  final String id, operation, task, owner, name;
  final void Function(Json) send;
  final result = Completer<Json>();
  final cancellation = CancellationToken();
}
