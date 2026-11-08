import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

typedef _Question = ({
  Json request,
  Completer<List<List<String>>?> answer,
  CancellationToken cancellation,
});

/// Pending questions belong to the session, so reconnecting clients can answer
/// them. The calling tool controls their lifetime, including steering and Stop.
class SessionQuestions {
  SessionQuestions(this.emit) {
    _mailbox.listen((raw) => unawaited(traceIncoming(jsonObject(raw),
      () => _handle(jsonObject(raw)), service: 'server')));
  }

  final void Function(String sessionID, Json event) emit;
  final _mailbox = ReceivePort();
  final _pending = <String, _Question>{};
  final _operations = <String, CancellationToken>{};
  final _answering = <String>{};
  bool _closed = false;
  SendPort get port => _mailbox.sendPort;

  List<Json> list(String sessionID) => [
    for (final question in _pending.values)
      if (question.request['sessionID'] == sessionID) question.request,
  ];

  _Question _find(String sessionID, String requestID) {
    final question = _pending[requestID];
    if (question == null || question.request['sessionID'] != sessionID ||
        question.answer.isCompleted || question.cancellation.isCancelled || _answering.contains(requestID)) {
      throw StateError('Question is no longer pending');
    }
    return question;
  }

  Future<void> reply(String sessionID, String requestID, Object? answers, {
    required Future<void> Function(String prompt) send,
  }) async {
    final question = _find(sessionID, requestID);
    final accepted = questionAnswers(
      (question.request['questions'] as List).cast<Json>(), answers);
    if (question.request['async'] == true) {
      if (accepted.every((answer) => answer.isEmpty)) throw const FormatException('Provide an answer before submitting');
      _answering.add(requestID);
      try {
        await send(_asyncReply(question.request, accepted));
      } finally {
        _answering.remove(requestID);
      }
    }
    _pending.remove(requestID);
    _emit('question.replied', question.request, {'answers': accepted});
    question.answer.complete(accepted);
    if (question.request['async'] == true) question.cancellation.cancel();
  }

  void reject(String sessionID, String requestID) {
    final question = _find(sessionID, requestID);
    _pending.remove(requestID);
    _emit('question.rejected', question.request);
    question.answer.complete(null);
    if (question.request['async'] == true) question.cancellation.cancel();
  }

  void endTurn(String sessionID) {
    for (final request in list(sessionID).where((request) => request['async'] == true)) {
      final question = _pending.remove(request['id'])!;
      question.cancellation.cancel();
      _emit('question.rejected', request);
    }
  }

  void _emit(String type, Json request, [Json data = const {}]) =>
    emit(request['sessionID'] as String, {
      'type': type, 'data': {'requestID': request['id'], ...data},
    });

  Future<void> _handle(Json message) async {
    final reply = message['reply'] as SendPort?;
    final params = jsonObject(message['params']);
    final operation = message['operation_id'] as String?;
    CancellationToken? cancellation;
    Json? request;
    try {
      if (message['method'] == 'cancel') {
        _operations[params['operation_id']]?.cancel();
        reply?.send({'result': null});
        return;
      }
      if (_closed) throw StateError('Questions are closed');
      if (!{'ask', 'ask_async'}.contains(message['method'])) throw StateError('Unknown question operation');
      final asynchronous = message['method'] == 'ask_async';
      final questions = questionPrompts(params['arguments']);
      cancellation = CancellationToken();
      _operations[operation!] = cancellation;
      request = {
        'id': newId(), 'sessionID': requiredString(params, 'task_id'),
        'questions': questions, 'callID': requiredString(params, 'call_id'),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        if (asynchronous) 'async': true,
      };
      final answer = Completer<List<List<String>>?>();
      _pending[request['id'] as String] = (request: request, answer: answer, cancellation: cancellation);
      _emit('question.asked', request, {'request': request});
      if (asynchronous) {
        reply?.send({'result': {'accepted': true}});
        // Async questions outlive their tool call and are removed when answered
        // or when the turn ends, as in Codex's retained question editor.
        request = null;
        cancellation = null;
        return;
      }
      final answers = await answer.future.asCancellable(cancellation);
      reply?.send({'result': answers == null ? {'rejected': true} : {
        'answers': answers, 'output': questionAnswerText(questions, answers),
      }});
    } catch (error) {
      traceError(error);
      reply?.send({'error': error.toString(), if (error is CancelledException) 'code': 'cancelled'});
    } finally {
      _operations.remove(operation);
      cancellation?.cancel();
      if (request != null && _pending.remove(request['id']) != null) {
        _emit('question.rejected', request);
      }
    }
  }

  void close() {
    _closed = true;
    for (final cancellation in _operations.values) { cancellation.cancel(); }
    for (final question in _pending.values) { question.cancellation.cancel(); }
    _pending.clear();
    _mailbox.close();
  }
}

String _asyncReply(Json request, List<List<String>> answers) {
  final prompts = (request['questions'] as List).cast<Json>();
  return '<send_user_message_question_reply>\n${jsonEncode([
    for (var i = 0; i < prompts.length; i++) if (answers[i].isNotEmpty) {
      'answer': answers[i].join(', '),
      'question': _questionTitle(prompts[i]['question'] as String),
      'questionItemId': jsonEncode(['request_user_input_async', request['callID'], i]),
    },
  ])}\n</send_user_message_question_reply>';
}

String _questionTitle(String title) {
  final bytes = utf8.encode(title);
  var end = bytes.length.clamp(0, 512);
  while (end < bytes.length && end > 0 && bytes[end] & 0xc0 == 0x80) { end--; }
  return utf8.decode(bytes.sublist(0, end)).replaceAll(RegExp(r'[\n\r]'), ' ');
}
