import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:desktop/context_usage.dart';
import 'package:desktop/context_window.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';

void main() {
  late Directory root;
  late _Client client;
  late DesktopSession session;
  late DesktopTask task;

  setUp(() async {
    // Exercise the real server -> agent snapshot path, not a storage projection.
    root = await Directory.systemTemp.createTemp('context-window-');
    client = _Client(root.path, newId());
    await client.connect();
    session = DesktopSession(client, await openDesktopDatabase(root.path));
    task = DesktopTask(client.id, 'Inspect context');
    final page = await client.sessionRead('session.message.list', {'sessionID': client.id},
      cancellation: CancellationToken());
    task.messages.addAll({for (final raw in page['data']) raw['id'] as String: jsonObject(raw)});
    task.through = page['through'] as int;
    session.projects.add(Project('checkout', 'project', root.path, [task]));
  });
  tearDown(() async {
    await session.close();
    client.store.close();
    await root.delete(recursive: true);
  });

  Future<void> settleRead(WidgetTester tester) async {
    await tester.runAsync(() async { await client.reading?.timeout(const Duration(seconds: 10)); });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> showContext(WidgetTester tester, {bool indicator = false}) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 420,
      child: Column(children: [
        if (indicator) ContextUsageIndicator(messages: task.messages.values, limit: 1000, onPressed: () {}),
        Expanded(child: SessionContextWindow(session: session, task: task,
          downloadsDirectory: Directory('${root.path}/Downloads'))),
      ]))))));
    await settleRead(tester);
  }

  Finder contextScroll() => find.descendant(of: find.byType(SessionContextWindow), matching: find.byType(Scrollable)).first;

  Future<String> export(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Export session JSON'));
    final button = tester.widget<TextButton>(find.ancestor(of: find.text('Export session JSON'),
      matching: find.byWidgetPredicate((widget) => widget is TextButton)).first);
    await tester.runAsync(button.onPressed! as Future<void> Function());
    await tester.pumpAndSettle();
    return (await tester.runAsync(() async {
      final file = (await Directory('${root.path}/Downloads').list().toList()).single as File;
      expect(file.path, endsWith('.json'));
      expect(file.path, contains('inspect-context-'));
      return file.readAsString();
    }))!;
  }

  testWidgets('real context shows the saved prompt and usage, expands input, and exports the session', (tester) async {
    await showContext(tester, indicator: true);
    expect(find.text('Total Tokens'), findsOneWidget);
    expect(find.text('120'), findsNWidgets(2));
    await tester.scrollUntilVisible(find.text('System Prompt'), 200, scrollable: contextScroll());
    expect(find.text('You are the saved system prompt.', findRichText: true), findsNothing);
    expect(find.byTooltip('Copy system prompt'), findsOneWidget);
    await tester.tap(find.text('System Prompt'));
    await tester.pumpAndSettle();
    expect(find.text('You are the saved system prompt.', findRichText: true), findsOneWidget);
    await tester.tap(find.text('System Prompt'));
    await tester.pumpAndSettle();
    expect(find.text('You are the saved system prompt.', findRichText: true), findsNothing);
    await tester.scrollUntilVisible(find.text('user • item_user'), 200, scrollable: contextScroll());
    await tester.tap(find.text('user • item_user'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Raw request', findRichText: true), findsOneWidget);
    final contents = await export(tester);
    final exported = jsonDecode(contents) as Map;
    expect(exported.containsKey('messages'), false);
    expect(contents, contains('Raw request'));
    expect((exported['context'] as Map).containsKey('baseInstructionID'), false);
    expect((exported['context']['input'] as List).map((item) => item['id']), ['item_user', 'item_answer']);
    expect(exported['context']['instructions'], 'You are the saved system prompt.');
    for (final key in ['data', 'system', 'systemMessage', 'cursor']) {
      expect((exported['context'] as Map).containsKey(key), false);
    }
    expect(RegExp('You are the saved system prompt.').allMatches(contents).length, 1);
    expect(client.methods.where((method) => method == 'session.context'), hasLength(2));
    expect(client.methods.where((method) => method == 'session.message.list'), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('context pages append in model order and retain the snapshot fence', (tester) async {
    client.pageLimit = 2;
    client.store.append('input.committed', {'message_id': 'later',
      'item': ConversationItem.text('user', 'Later request', id: 'item_later').toJson()});
    await showContext(tester);
    client.store.append('input.committed', {'message_id': 'new',
      'item': ConversationItem.text('user', 'After snapshot', id: 'item_new').toJson()});
    await tester.scrollUntilVisible(find.text('Load more context items'), 200, scrollable: contextScroll());
    await tester.tap(find.text('Load more context items'));
    await settleRead(tester);
    expect(find.text('Load more context items'), findsNothing);
    expect(find.text('user • item_later'), findsOneWidget);
    expect(find.text('user • item_new'), findsNothing);
    final titles = tester.widgetList<ExpansionTile>(find.byType(ExpansionTile))
      .map((tile) => tile.title).whereType<Text>().map((title) => title.data).toList();
    expect(titles, containsAllInOrder(['user • item_user', 'assistant • item_answer', 'user • item_later']));
    final exported = jsonDecode(await export(tester)) as Map;
    expect((exported['context']['input'] as List).map((item) => item['id']),
      ['item_user', 'item_answer', 'item_later', 'item_new']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compacted context excludes transcript history and uses snapshot usage', (tester) async {
    client.store.append('context.compacted', {'summary': 'Checkpoint', 'input': [
      ConversationItem.text('developer', 'Compacted summary', id: 'item_summary').toJson(),
    ]});
    client.store.append('model.completed', {'assistantMessageID': 'msg_after', 'output': [
      ConversationItem.text('assistant', 'After compaction', id: 'item_after').toJson(),
    ], 'usage': {'input_tokens': 10, 'output_tokens': 2}});
    await showContext(tester);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('120'), findsNothing);
    await tester.scrollUntilVisible(find.text('assistant • item_after'), 200, scrollable: contextScroll());
    expect(find.text('developer • item_summary'), findsOneWidget);
    expect(find.text('user • item_user'), findsNothing);
    expect(find.text('assistant • item_answer'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a delayed old page cannot overwrite a refreshed agent snapshot', (tester) async {
    client.pageLimit = 1;
    await showContext(tester);
    final gate = (await tester.runAsync(() async => (arrived: Completer<void>(), release: Completer<void>())))!;
    client.pageGate = gate;
    await tester.scrollUntilVisible(find.text('Load more context items'), 200, scrollable: contextScroll());
    await tester.tap(find.text('Load more context items'));
    final delayed = client.reading!;
    await tester.runAsync(() => gate.arrived.future.timeout(const Duration(seconds: 10)));
    client.store.append('context.compacted', {'summary': 'Replacement', 'input': [
      ConversationItem.text('developer', 'New snapshot', id: 'item_replacement').toJson(),
    ]});
    await tester.scrollUntilVisible(find.byTooltip('Refresh context'), -200, scrollable: contextScroll());
    await tester.tap(find.byTooltip('Refresh context'));
    await settleRead(tester);
    await tester.runAsync(() async { gate.release.complete(); await delayed; });
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('developer • item_replacement'), 200, scrollable: contextScroll());
    expect(find.text('assistant • item_answer'), findsNothing);
    expect(find.text('user • item_user'), findsNothing);
    expect(find.text('Load more context items'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty context renders envelope instructions without stale token usage', (tester) async {
    client.store.append('context.compacted', {'summary': 'Checkpoint', 'input': []});
    final config = {...client.config, 'provider': 'opencode', 'tool_interface': 'opencode',
      'instructions': 'Prompt from the request envelope'};
    client.store.append('task.created', config, metadata: {'config': config});
    await showContext(tester);
    expect(find.text('Total Tokens'), findsOneWidget);
    expect(find.text('120'), findsNothing);
    await tester.scrollUntilVisible(find.text('System Prompt'), 200, scrollable: contextScroll());
    await tester.tap(find.text('System Prompt'));
    await tester.pumpAndSettle();
    expect(find.text('Prompt from the request envelope', findRichText: true), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Raw context'), 200, scrollable: contextScroll());
    expect(find.text('user • item_user'), findsNothing);
    expect(find.text('Load more context items'), findsNothing);
    final contents = await export(tester);
    expect(RegExp('Prompt from the request envelope').allMatches(contents).length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('usage and raw input refresh together from agent snapshots during execution', (tester) async {
    Future<void> emit(String type, Json data) async {
      final record = client.store.append(type, data);
      for (final event in record['session_events']) { client.events.add(jsonObject(event)); }
      await tester.pump();
      await settleRead(tester);
    }
    // Open while this step is already running; its creation precedes the
    // snapshot fence, but its eventual usage must still update the pane.
    await emit('model.started', {'assistantMessageID': 'msg_live', 'instructions': '', 'tools': []});
    await showContext(tester);
    final reads = client.methods.where((method) => method == 'session.context').length;
    await emit('model.completed', {'assistantMessageID': 'msg_live', 'output': [
      ConversationItem.text('assistant', 'Live response', id: 'item_live').toJson(),
    ], 'usage': {'input_tokens': 30, 'output_tokens': 3}});
    expect(find.text('33'), findsOneWidget);
    expect(find.text('120'), findsNothing);
    await emit('context.compacted', {'summary': 'Checkpoint', 'input': []});
    expect(find.text('33'), findsNothing);
    expect(find.text('120'), findsNothing);
    await emit('model.started', {'assistantMessageID': 'msg_after', 'instructions': '', 'tools': []});
    await emit('model.completed', {'assistantMessageID': 'msg_after', 'output': [
      ConversationItem.text('assistant', 'New window response', id: 'item_after').toJson(),
    ], 'usage': {'input_tokens': 10, 'output_tokens': 2}});
    expect(find.text('12'), findsOneWidget);
    expect(client.methods.where((method) => method == 'session.context').length, greaterThan(reads));
    // Idle triggers the canonical snapshot refresh through the session listener.
    final completed = client.store.append('turn.completed', {});
    for (final event in completed['session_events']) { client.events.add(jsonObject(event)); }
    await tester.pump();
    await settleRead(tester);
    expect(client.methods.where((method) => method == 'session.context').length, greaterThan(reads + 1));
    expect(find.text('12'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('assistant • item_after'), 200, scrollable: contextScroll());
    expect(find.text('user • item_user'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Client implements AgentClient {
  _Client(this.directory, this.id) : store = TaskStore(directory, id) {
    store.append('task.created', config, metadata: {'config': config});
    store.append('input.committed', {'message_id': 'user',
      'item': ConversationItem.text('user', 'Raw request', id: 'item_user').toJson()});
    store.append('model.started', {'assistantMessageID': 'msg_answer', 'instructions': config['instructions'], 'tools': []});
    store.append('model.completed', {'assistantMessageID': 'msg_answer', 'output': [
      ConversationItem.text('assistant', 'Answer', id: 'item_answer').toJson(),
    ], 'usage': {'input_tokens': 95, 'cached_input_tokens': 25, 'output_tokens': 25, 'reasoning_tokens': 5}});
  }

  final String directory, id;
  final Json config = {'provider': 'openai', 'tool_interface': 'openai', 'model': 'fixture', 'instructions': 'You are the saved system prompt.',
    'provider_settings': {'context_limit': 1000, 'reasoning': 'high'}};
  final TaskStore store;
  late final AgentServer server;
  late final AgentClient remote;
  Future<void> connect() => HttpOverrides.runWithHttpOverrides(() async {
    server = await AgentServer.startEmbedded(directory: directory, skillsHome: directory,
      configPath: '$directory/config.yaml');
    remote = await AgentClient.connect(server.uri);
  }, _LocalHttp());
  final _ioZone = Zone.current;
  @override final events = StreamController<Json>.broadcast();
  final methods = <String>[];
  Future<Json>? reading;
  int? pageLimit;
  ({Completer<void> arrived, Completer<void> release})? pageGate;

  @override Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) {
    methods.add(method);
    // Server reads use real sockets and isolates, outside the widget fake clock.
    final response = _ioZone.run<Future<Json>>(() => remote.sessionRead(method, {
      ...params, if (method == 'session.context' && pageLimit != null) 'limit': pageLimit,
    }, cancellation: cancellation));
    if (pageGate case final gate? when params['cursor'] != null) {
      pageGate = null;
      return reading = _ioZone.run<Future<Json>>(() async {
        final Json page;
        try { page = await response; }
        catch (error, stack) {
          gate.arrived.completeError(error, stack);
          rethrow;
        }
        gate.arrived.complete();
        await gate.release.future.asCancellable(cancellation);
        return page;
      });
    }
    return reading = response;
  }
  @override Future<void> close() async {
    await remote.close();
    await server.close();
    if (!events.isClosed) await events.close();
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Widget tests normally replace every HttpClient with a 400-response stub.
// These tests deliberately exercise an isolated local WebSocket server.
class _LocalHttp extends HttpOverrides {}
