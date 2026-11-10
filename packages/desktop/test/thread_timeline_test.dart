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

  testWidgets('the latest message renders in the first frame and transcript edits preserve the viewport', (tester) async {
    final task = DesktopTask('long-thread', 'Long conversation')..loaded = true;
    addTearDown(task.liveText.dispose);
    void add(int index) {
      task.messages['user-$index'] = {'id': 'user-$index', 'type': 'userMessage', 'order': index * 3,
        'content': [{'type': 'text', 'text': 'User $index'}]};
      task.messages['answer-$index'] = {'id': 'answer-$index', 'type': 'agentMessage', 'order': index * 3 + 2,
        if (index == 19) 'turnId': 'last',
        'text': 'Answer $index', 'phase': 'final_answer'};
    }
    for (var index = 0; index < 20; index++) { add(index); }
    task.turns['last'] = {'id': 'last', 'status': 'completed'};
    task.messages['read'] = {'id': 'read', 'type': 'dynamicToolCall', 'order': 58, 'turnId': 'last',
      'tool': 'read_file', 'arguments': {'path': '/input'}, 'status': 'completed'};
    Widget view() => MaterialApp(home: Scaffold(body: ConversationTranscript(
      task: task, directory: '/project', onRetry: () {})));
    await tester.pumpWidget(view());
    expect(find.text('Answer 19', findRichText: true), findsOneWidget);
    expect(tester.getBottomLeft(find.text('Answer 19', findRichText: true)).dy, lessThanOrEqualTo(600));
    final fold = find.text('Worked');
    final foldTop = tester.getTopLeft(fold).dy;
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(fold).dy, closeTo(foldTop, .5));

    await tester.dragUntilVisible(find.text('User 0', findRichText: true), find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    final anchor = tester.getTopLeft(find.text('User 0', findRichText: true));
    for (var index = -5; index < 0; index++) { add(index); }
    await tester.pumpWidget(view());
    expect(tester.getTopLeft(find.text('User 0', findRichText: true)).dy, closeTo(anchor.dy, .5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
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
    expect(find.byType(ThinkingLabel), findsOneWidget);

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

    item({'id': 'cell', 'type': 'dynamicToolCall', 'tool': 'exec',
      'arguments': 'await tools.read({path: "input.txt"})', 'status': 'inProgress'}, live: true);
    item({'id': 'read', 'type': 'dynamicToolCall', 'tool': 'read',
      'parentCallId': 'cell', 'arguments': {'path': 'input.txt'}, 'status': 'inProgress'}, live: true);
    item({'id': 'finished', 'type': 'dynamicToolCall', 'tool': 'read',
      'parentCallId': 'cell', 'arguments': {'path': 'other.txt'}, 'status': 'completed'});
    await render();
    expect(thinking('Thinking'), findsNothing);
    expect(thinking('Checking the follow-up'), findsNothing);
    expect(thinking('Reading input.txt'), findsOneWidget);
    expect(find.byType(ThinkingLabel), findsOneWidget);
    expect(find.byKey(const ValueKey('working')), findsNothing);

    item({'id': 'read', 'type': 'dynamicToolCall', 'tool': 'read',
      'parentCallId': 'cell', 'arguments': {'path': 'input.txt'}, 'status': 'completed'});
    await render();
    expect(thinking('Thinking'), findsOneWidget);
    expect(find.byKey(const ValueKey('working')), findsNothing);

    item({'id': 'after-tool', 'type': 'reasoning', 'summary': ['Checking the result']}, live: true);
    await render();
    expect(thinking('Checking the result'), findsOneWidget);
    expect(thinking('Thinking'), findsNothing);

    item({'id': 'commentary', 'type': 'agentMessage', 'text': 'Preparing the answer', 'phase': 'commentary'}, live: true);
    await render();
    expect(thinking('Thinking'), findsOneWidget);
    task.questions['question'] = {'async': false};
    await render();
    expect(find.byType(ThinkingLabel), findsNothing);
    task.questions['question'] = {'async': true};
    await render();
    expect(thinking('Thinking'), findsOneWidget);
    task.questions.clear();

    item({'id': 'answer', 'type': 'agentMessage', 'text': 'Answering the follow-up'}, live: true);
    await render();
    expect(thinking('Thinking'), findsNothing);

    item({'id': 'answer', 'type': 'agentMessage', 'text': 'Done', 'phase': 'final_answer'});
    await render();
    expect(find.byType(ThinkingLabel), findsNothing);
    task.turns['turn'] = {'id': 'turn', 'status': 'completed'};
    task.running = false;
    await render();
    expect(find.byType(ThinkingLabel), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
