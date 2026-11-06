import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

// Background naming has its own inference exchange; foreground scripts and
// their request counts describe the conversation's turns.
List<Json>? threadNameReply(Json body) {
  if ((body['tools'] as List? ?? []).isNotEmpty) return null;
  const title = '{"title":"Fixture conversation"}';
  if (body['tool_choice'] == 'none' && body['input'] is List) {
    return [{'type': 'response.completed', 'response': {'status': 'completed', 'output': [
      {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': title}]},
    ]}}];
  }
  if (body['messages'] is List && body['max_tokens'] == 256) {
    return [{'choices': [{'delta': {'content': title}, 'finish_reason': 'stop'}]}];
  }
  return null;
}

Future<bool> respondToThreadName(HttpRequest request, Json body) async {
  final events = threadNameReply(body);
  if (events == null) return false;
  request.response.headers.contentType = ContentType('text', 'event-stream');
  for (final event in events) { request.response.write('data: ${jsonEncode(event)}\n\n'); }
  if (body['messages'] is List) request.response.write('data: [DONE]\n\n');
  await request.response.close();
  return true;
}
