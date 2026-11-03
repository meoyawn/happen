import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/appearance.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:desktop/session_question.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

final _questions = <Json>[
  {'header': 'Confirm', 'question': 'Should we proceed?', 'options': [
    {'label': 'Yes', 'description': 'Continue with the plan'},
    {'label': 'No', 'description': 'Choose another approach'},
  ]},
  {'header': 'Features', 'question': 'Which features do you want?', 'multiple': true, 'options': [
    {'label': 'A', 'description': 'First feature'},
    {'label': 'B', 'description': 'Second feature'},
  ]},
  {'header': 'Details', 'question': 'Anything else?', 'options': <Json>[]},
];

void main() {
  testWidgets('question dock retains edits across navigation and retries the same answers', (tester) async {
    final draft = QuestionDraft(3);
    final sends = <List<List<String>>?>[];
    final first = Completer<void>();
    Future<void> answer(List<List<String>>? answers, CancellationToken cancellation) async {
      sends.add(answers);
      if (sends.length == 1) await first.future;
    }
    Widget dock() => MaterialApp(theme: desktopTheme(), home: Scaffold(body: Center(
      child: SizedBox(width: 744, height: 480, child: SessionQuestionDock(
        request: {'id': 'request', 'questions': _questions}, draft: draft, onAnswer: answer,
      )),
    )));
    await tester.pumpWidget(dock());
    await tester.tap(find.text('Yes'));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.tap(find.text('Type your own answer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'More');
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No'));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('More'), findsOneWidget);
    await tester.tap(find.byTooltip('Minimize questions'));
    await tester.pumpAndSettle();
    expect(find.text('First feature'), findsNothing);
    await tester.tap(find.byTooltip('Expand questions'));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Type your own answer'));
    await tester.tap(find.text('Type your own answer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Detailed custom answer');

    // Leaving the tab unmounts the dock; its session still owns the draft.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(dock());
    await tester.pumpAndSettle();
    expect(find.text('Detailed custom answer'), findsOneWidget);
    await tester.tap(find.text('Submit'));
    await tester.pump();
    await tester.tap(find.text('Submit'));
    expect(sends, hasLength(1), reason: 'A pending answer cannot be submitted twice');
    first.completeError(StateError('Network unavailable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Network unavailable'), findsOneWidget);
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(sends, [
      [['No'], ['A', 'B', 'More'], ['Detailed custom answer']],
      [['No'], ['A', 'B', 'More'], ['Detailed custom answer']],
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Escape dismisses a question and a small dock scrolls without overflowing', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: Scaffold(body: Center(
      child: SizedBox(width: 320, height: 150, child: SessionQuestionDock(
        request: {'id': 'small', 'questions': _questions}, draft: QuestionDraft(3),
        onAnswer: (answers, cancellation) async { dismissed = answers == null; },
      )),
    ))));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Type your own answer'));
    await tester.tap(find.text('Type your own answer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A compact answer');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(dismissed, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('desktop questions resume headless sessions, reconnect, deliver answers, and cancel with their turn',
    () => HttpOverrides.runWithHttpOverrides(() async {
    final root = await Directory.systemTemp.createTemp('desktop-questions-');
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final lifetime = CancellationToken();
    AgentServer? server;
    DesktopSession? desktop;
    addTearDown(() async {
      lifetime.cancel();
      await desktop?.close();
      await server?.close();
      await provider.close(force: true);
      await root.delete(recursive: true);
    });
    final expires = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    await File('${root.path}/config.yaml').writeAsString(jsonEncode({
      'providers': {'opencode': {'endpoint': 'http://127.0.0.1:${provider.port}/v1'}},
    }));
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture',
      'account_id': 'fixture', 'expires_at': expires,
    }));
    await File('${root.path}/opencode-auth.json').writeAsString(jsonEncode({
      'version': 1, 'type': 'opencode', 'server': 'https://opencode.ai/console',
      'access_token': 'fixture', 'refresh_token': 'fixture', 'org_id': 'fixture', 'expires_at': expires,
    }));
    final requests = <Json>[];
    var asking = true;
    var asyncStage = -1;
    final asyncReceipt = Completer<Json>();
    final questionRequest = Completer<Json>();
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requests.add(body);
      final openai = request.uri.path == '/responses';
      if (openai && asking && !questionRequest.isCompleted) questionRequest.complete(body);
      final prompts = openai ? [
        for (var i = 0; i < _questions.length; i++) {
          'id': 'q$i', 'header': _questions[i]['header'], 'question': _questions[i]['question'],
          'options': (_questions[i]['options'] as List).isEmpty
            ? [{'label': 'None', 'description': 'No additional details'}] : _questions[i]['options'],
        },
      ] : _questions;
      var output = asking ? <Json>[{
        'type': 'function_call', 'name': openai ? 'request_user_input' : 'question', 'call_id': 'question_${requests.length}',
        'arguments': jsonEncode({'questions': prompts}),
      }] : <Json>[{
        'type': 'message', 'role': 'assistant',
        'content': [{'type': 'output_text', 'text': 'Saved your answers'}],
      }];
      if (openai && asyncStage == 0) {
        asyncStage = 1;
        output = [{
          'type': 'function_call', 'name': 'request_user_input_async', 'call_id': 'async_question',
          'arguments': jsonEncode({'questions': [
            {'title': 'Which approach should we use?', 'options': ['Safe', 'Fast']},
            {'title': 'Any constraints?'},
          ]}),
        }];
      } else if (openai && asyncStage == 1) {
        asyncStage = 2;
        asyncReceipt.complete(body);
        output = [{
          'type': 'function_call', 'namespace': 'clock', 'name': 'sleep', 'call_id': 'while_waiting',
          'arguments': '{"duration_ms":60000}',
        }];
      }
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode(openai
        ? {'type': 'response.completed', 'response': {'status': 'completed', 'output': output}}
        : {'choices': [{
            'delta': asking ? {'tool_calls': [{
              'index': 0, 'id': output.first['call_id'], 'type': 'function',
              'function': {'name': 'question', 'arguments': output.first['arguments']},
            }]} : {'content': 'Saved your answers'},
            'finish_reason': asking ? 'tool_calls' : 'stop',
          }]})}\n\n');
      if (!openai) request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    server = await AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml',
      port: 0, endpoint: 'http://127.0.0.1:${provider.port}/responses');
    final headless = await AgentClient.connect(server.uri);
    addTearDown(headless.close);
    asking = false;
    final completed = headless.events.stream.firstWhere(
      (event) => event['type'] == 'session.execution.succeeded');
    final created = jsonObject(await headless.request('session.create', {
      'cwd': await root.resolveSymbolicLinks(), 'provider': 'openai', 'model': 'gpt-6-astra',
      'prompt': 'Save a session without interactive tools',
      'settings': {'request_user_input': false},
    }));
    await completed.timeout(const Duration(seconds: 20));
    final savedID = created['sessionID'] as String;
    expect((requests.last['tools'] as List).map((tool) => tool['name']),
      isNot(contains('request_user_input_async')));
    await headless.request('session.hibernate', {'sessionID': savedID});
    await headless.close();
    var session = desktop = DesktopSession(await AgentClient.connect(server.uri), await openDesktopDatabase(root.path));
    await session.load();
    await session.addProject(root.path);

    for (final model in ['gpt-6-astra', 'deepseek-v4.1-flash-free']) {
      await session.select(session.project!, model == 'gpt-6-astra'
        ? session.project!.tasks.singleWhere((task) => task.id == savedID) : null);
      if (model != 'gpt-6-astra') session.chooseModel(model);
      asking = true;
      expect(await session.send('Ask me about the plan'), true, reason: session.error);
      if (model == 'gpt-6-astra') {
        final request = await questionRequest.future.timeout(const Duration(seconds: 10));
        expect((request['tools'] as List).map((tool) => tool['name']),
          containsAll(['request_user_input', 'request_user_input_async']),
          reason: 'The desktop can answer questions in a session created without interactive tools');
      }
      await _until(session, () => session.task!.questions.isNotEmpty);
      var target = session.task!;
      final id = target.id, requestID = target.questions.keys.single;
      await expectLater(session.client.answerQuestion(id, requestID, [['Yes']], cancellation: lifetime), throwsStateError);
      expect(target.questions, hasLength(1), reason: 'Invalid answers leave the question available to retry');
      await session.close();
      final local = await Directory('${root.path}/reconnect-$model').create();
      session = desktop = DesktopSession(await AgentClient.connect(server.uri), await openDesktopDatabase(local.path));
      await session.load();
      await session.addProject(root.path);
      target = session.project!.tasks.singleWhere((task) => task.id == id);
      await session.select(session.project!, target);
      expect(target.questions.keys.single, requestID);
      asking = false;
      final expected = [['No'], if (model == 'gpt-6-astra') ['More'] else ['A', 'More'], ['Detailed custom answer']];
      await session.answerQuestion(target, requestID, expected, cancellation: lifetime);
      await _until(session, () => !target.running);
      expect(target.questions, isEmpty);
      expect(jsonEncode(requests.last[model == 'gpt-6-astra' ? 'input' : 'messages']),
        allOf(contains('Detailed custom answer'), contains('More')));
      final question = conversation(target).where((entry) =>
        {'question', 'request_user_input'}.contains(entry.tool?.name.split('.').last)).first.tool!;
      var part = question.rawOutput;
      if (part is Map && part[r'$part'] is String) {
        part = await session.client.conversationPart(part[r'$part'] as String, cancellation: lifetime);
      }
      expect(jsonEncode(part), contains('Detailed custom answer'));
      await session.loadHistory(target);
      expect(conversation(target).where((entry) => entry.role == 'Happen').last.text, 'Saved your answers');

      for (final dismiss in [true, false]) {
        asking = true;
        expect(await session.send('Ask another question'), true, reason: session.error);
        await _until(session, () => target.questions.isNotEmpty);
        final before = requests.length;
        if (dismiss) {
          await session.answerQuestion(target, target.questions.keys.single, null, cancellation: lifetime);
        } else {
          await session.stop();
        }
        await _until(session, () => !target.running);
        expect(target.questions, isEmpty);
        expect(requests, hasLength(before), reason: 'Dismiss and Stop end the waiting turn');
      }
    }

    await session.select(session.project!);
    session.chooseModel('gpt-6-astra');
    asking = false;
    asyncStage = 0;
    expect(await session.send('Ask a question and continue working'), true, reason: session.error);
    await _until(session, () => session.task!.questions.isNotEmpty);
    final target = session.task!, request = target.questions.values.single;
    final receipt = await asyncReceipt.future.timeout(const Duration(seconds: 10));
    expect(jsonEncode(receipt['input']), contains(r'\"accepted\":true'),
      reason: 'Async questions must return to inference before the user answers');
    expect(target.running, true);
    expect(request['async'], true);
    await session.answerQuestion(target, request['id'] as String, [['Fast'], ['Only local files']],
      cancellation: lifetime);
    await _until(session, () => !target.running);
    expect(target.questions, isEmpty);
    final user = (requests.last['input'] as List).lastWhere((item) => item['role'] == 'user');
    expect(jsonEncode(user['content']), allOf(
      contains('send_user_message_question_reply'), contains('Which approach should we use?'),
      contains('Fast'), contains('Only local files')));

    await session.close();
    desktop = null;
    final resumed = await AgentClient.connect(server.uri);
    addTearDown(resumed.close);
    final finished = resumed.events.stream.firstWhere(
      (event) => event['type'] == 'session.execution.succeeded');
    asyncStage = -1;
    await resumed.request('session.prompt', {
      'sessionID': savedID, 'prompt': 'Continue without a desktop connected',
    });
    await finished.timeout(const Duration(seconds: 20));
    expect((requests.last['tools'] as List).map((tool) => tool['name']),
      isNot(anyOf(contains('request_user_input'), contains('request_user_input_async'))),
      reason: 'Closing the desktop must not leave blocking question tools enabled for a headless client');
  }, _RealHttp()));
}

// Flutter's widget binding replaces HTTP globally. This test exercises the
// actual local WebSocket and provider connections.
class _RealHttp extends HttpOverrides {}

Future<void> _until(DesktopSession session, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void changed() {
    if (done.isCompleted) return;
    final failure = session.task?.messages.values.where(
      (message) => message['type'] == 'idle' && message['outcome'] == 'failed').lastOrNull;
    if (failure != null) { done.completeError(StateError('${failure['error']}')); }
    else if (condition()) { done.complete(); }
  }
  session.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 20));
  } finally {
    session.removeListener(changed);
  }
}
