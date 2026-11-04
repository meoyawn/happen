// T3Code MessagesTimeline / CodexAdapterV2 item lifecycle contracts, in Flutter.
import 'package:desktop/conversation.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';

void main() {
  test('completion replaces deltas and late deltas cannot resurrect finished text', () {
    final items = <String, Json>{};
    for (final event in [
      {'method': 'item/started', 'params': {'turnId': 'turn', 'item': {'id': 'reply', 'type': 'agentMessage', 'text': ''}}},
      {'method': 'item/agentMessage/delta', 'params': {'turnId': 'turn', 'itemId': 'reply', 'delta': 'Partial'}},
      {'method': 'item/completed', 'params': {'turnId': 'turn', 'item': {'id': 'reply', 'type': 'agentMessage', 'text': 'Final', 'completedAtMs': 2}}},
      {'method': 'item/agentMessage/delta', 'params': {'turnId': 'turn', 'itemId': 'reply', 'delta': 'late'}},
    ]) { applyThreadNotification(items, event); }
    expect(items['reply']?['text'], 'Final');
    expect(items['reply']?['live'], false);
  });

  testWidgets('native user items, reasoning, tools and final answers render in order without duplicate optimistic input', (tester) async {
    final task = DesktopTask('thread', 'Conversation')..loaded = true;
    task.messages.addAll({
      'user': {'id': 'user', 'type': 'userMessage', 'clientId': 'sent', 'order': 0,
        'content': [{'type': 'text', 'text': 'Inspect the file'}]},
      'thought': {'id': 'thought', 'type': 'reasoning', 'order': 1, 'summary': ['Check the input'], 'content': <Object?>[]},
      'read': {'id': 'read', 'type': 'dynamicToolCall', 'order': 2, 'tool': 'read',
        'arguments': {'path': 'input.txt'}, 'status': 'completed', 'contentItems': [{'type': 'inputText', 'text': '42'}]},
      'answer': {'id': 'answer', 'type': 'agentMessage', 'order': 3, 'text': 'The answer is 42', 'phase': 'final_answer'},
    });
    task.pending['msg_sent'] = {'id': 'sent', 'prompt': 'Inspect the file', 'delivery': 'steer'};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConversationTranscript(task: task, directory: '/project', onRetry: () {}))));
    await tester.pumpAndSettle();
    expect(find.text('Inspect the file', findRichText: true), findsOneWidget);
    expect(find.text('The answer is 42', findRichText: true), findsOneWidget);
    expect(find.textContaining('Used', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
