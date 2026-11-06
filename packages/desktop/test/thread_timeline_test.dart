// T3Code MessagesTimeline / CodexAdapterV2 item lifecycle contracts, in Flutter.
import 'package:desktop/conversation.dart';
import 'package:desktop/conversation_activity.dart';
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
    await tester.tap(find.text('Worked'));
    await tester.pumpAndSettle();
    expect(find.text('Read 1 file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('steering shows Thinking until new reasoning, tools or text take over', (tester) async {
    final task = DesktopTask('thread', 'Steering')..loaded = true..running = true;
    addTearDown(task.liveText.dispose);
    task.turns['turn'] = {'id': 'turn', 'status': 'inProgress'};
    Finder thinking(String label) => find.byWidgetPredicate((widget) =>
      widget is ThinkingLabel && widget.label == label);
    void item(Json value, {bool live = false}) => applyThreadNotification(task.messages, {
      'method': live ? 'item/started' : 'item/completed',
      'params': {'turnId': 'turn', 'item': value},
    });
    Future<void> render() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConversationTranscript(
        task: task, directory: '/project', onRetry: () {}))));
      await tester.pump();
    }
    item({'id': 'user', 'type': 'userMessage', 'content': [{'type': 'text', 'text': 'Start'}]});
    item({'id': 'old', 'type': 'reasoning', 'summary': ['Earlier thought']}, live: true);
    await render();
    expect(thinking('Earlier thought'), findsOneWidget);

    for (final id in ['steer', 'second-steer']) {
      item({'id': id, 'type': 'userMessage', 'content': [{'type': 'text', 'text': id}]});
      task.lastSentID = id;
      await render();
      expect(thinking('Thinking'), findsOneWidget);
      expect(thinking('Earlier thought'), findsNothing);
      expect(tester.getTopLeft(thinking('Thinking')).dy,
        greaterThan(tester.getBottomLeft(find.text(id, findRichText: true)).dy));
    }

    item({'id': 'next', 'type': 'reasoning', 'summary': ['Checking the follow-up']}, live: true);
    await render();
    expect(thinking('Checking the follow-up'), findsOneWidget);
    expect(thinking('Thinking'), findsNothing);

    item({'id': 'read', 'type': 'dynamicToolCall', 'tool': 'read',
      'arguments': {'path': 'input.txt'}, 'status': 'inProgress'}, live: true);
    await render();
    expect(thinking('Thinking'), findsNothing);
    expect(thinking('Checking the follow-up'), findsNothing);

    item({'id': 'read', 'type': 'dynamicToolCall', 'tool': 'read',
      'arguments': {'path': 'input.txt'}, 'status': 'completed'});
    await render();
    expect(thinking('Thinking'), findsOneWidget);

    item({'id': 'after-tool', 'type': 'reasoning', 'summary': ['Checking the result']}, live: true);
    await render();
    expect(thinking('Checking the result'), findsOneWidget);
    expect(thinking('Thinking'), findsNothing);

    item({'id': 'answer', 'type': 'agentMessage', 'text': 'Answering the follow-up'}, live: true);
    await render();
    expect(thinking('Thinking'), findsNothing);

    item({'id': 'answer', 'type': 'agentMessage', 'text': 'Done', 'phase': 'final_answer'});
    task.turns['turn'] = {'id': 'turn', 'status': 'completed'};
    task.running = false;
    await render();
    expect(find.byType(ThinkingLabel), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
