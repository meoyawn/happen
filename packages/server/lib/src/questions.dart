import 'dart:async';
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
  bool _closed = false;
  SendPort get port => _mailbox.sendPort;

  List<Json> list(String sessionID) => [
    for (final question in _pending.values)
      if (question.request['sessionID'] == sessionID) question.request,
  ];

  _Question _find(String sessionID, String requestID) {
    final question = _pending[requestID];
    if (question == null || question.request['sessionID'] != sessionID ||
        question.answer.isCompleted || question.cancellation.isCancelled) {
      throw StateError('Question is no longer pending');
    }
    return question;
  }

  void reply(String sessionID, String requestID, Object? answers) {
    final question = _find(sessionID, requestID);
    final accepted = questionAnswers(
      (question.request['questions'] as List).cast<Json>(), answers);
    _pending.remove(requestID);
    _emit('question.replied', question.request, {'answers': accepted});
    question.answer.complete(accepted);
  }

  void reject(String sessionID, String requestID) {
    final question = _find(sessionID, requestID);
    _pending.remove(requestID);
    _emit('question.rejected', question.request);
    question.answer.complete(null);
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
      if (message['method'] != 'ask') throw StateError('Unknown question operation');
      final questions = questionPrompts(params['arguments']);
      cancellation = CancellationToken();
      _operations[operation!] = cancellation;
      request = {
        'id': newId(), 'sessionID': requiredString(params, 'task_id'),
        'questions': questions, 'callID': requiredString(params, 'call_id'),
      };
      final answer = Completer<List<List<String>>?>();
      _pending[request['id'] as String] = (request: request, answer: answer, cancellation: cancellation);
      _emit('question.asked', request, {'request': request});
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
    _mailbox.close();
  }
}
