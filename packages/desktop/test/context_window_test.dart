import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:desktop/context_usage.dart';
import 'package:desktop/context_window.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

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
    session = DesktopSession(client, await openDesktopDatabase(root.path),
      attachmentDirectory: '${root.path}/attachments');
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
    await tester.runAsync(() async {
      Future<Json>? reading;
      do {
        reading = client.reading;
        await reading?.timeout(const Duration(seconds: 10));
        await client.traceReading?.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(Duration.zero);
      } while (!identical(reading, client.reading));
    });
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

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: contextScroll());
    await tester.pumpAndSettle();
  }

  Future<void> until(FutureOr<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('Export did not complete');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<String> export(WidgetTester tester) async {
    final button = tester.widget<IconButton>(find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Download LLM context JSON'));
    final contents = (await tester.runAsync(() async {
      button.onPressed!();
      final downloads = Directory('${root.path}/Downloads');
      await until(() async => await downloads.exists() &&
        (await downloads.list().toList()).any((file) => file.path.endsWith('.json')));
      final file = (await downloads.list().toList()).single as File;
      expect(file.path, endsWith('.json'));
      expect(file.path, contains('inspect-context-'));
      return file.readAsString();
    }))!;
    await tester.pumpAndSettle();
    return contents;
  }

  testWidgets('trace download copies its path and both JSON exports attach to a new composer', (tester) async {
    await tester.runAsync(() async {
      await session.tracing;
      task.tracing = true;
      client.traceSession(task.id);
    });
    String? copiedPath;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copiedPath = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await showContext(tester);
    final download = tester.widget<TextButton>(find.ancestor(of: find.text('Export & copy path'),
      matching: find.byWidgetPredicate((widget) => widget is TextButton)).first);
    await tester.runAsync(() async {
      download.onPressed!();
      await until(() => copiedPath != null);
    });
    await tester.pumpAndSettle();
    expect(copiedPath, startsWith('${root.path}/Downloads/'));
    final trace = jsonDecode((await tester.runAsync(() => File(copiedPath!).readAsString()))!) as Map;
    expect(trace['metadata']['sessionID'], task.id);
    expect(trace['traceEvents'], isNotEmpty);
    for (final label in ['LLM context', 'End-to-end trace']) {
      final previousDraft = session.currentDraft.id;
      final button = tester.widget<IconButton>(find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Attach $label to new session'));
      await tester.runAsync(() async {
        button.onPressed!();
        await until(() => session.currentDraft.id != previousDraft &&
          session.attachmentDrafts[session.currentDraft.id]?.isNotEmpty == true);
      });
      await tester.pumpAndSettle();
      expect(session.task, isNull);
      expect(session.currentDraft.id, isNot(previousDraft));
      expect(session.project!.tasks, contains(task));
      final attachment = session.attachmentDrafts[session.currentDraft.id]!.single;
      expect(attachment.image, isFalse);
      expect(attachment.ownedDirectory, startsWith('${root.path}/attachments/'));
      final data = jsonDecode((await tester.runAsync(() => File(attachment.path).readAsString()))!) as Map;
      expect(data.containsKey(label == 'LLM context' ? 'input' : 'traceEvents'), isTrue);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('context message headers remain interactive after scrolling and reassembly', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SessionContextWindow(session: session, task: task))));
    await settleRead(tester);
    final position = tester.state<ScrollableState>(contextScroll()).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final header = find.text('user • msg_item_user', findRichText: true);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(header));
    await tester.pump();
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.textContaining('Raw request', findRichText: true), findsOneWidget);

    final reassembled = tester.binding.reassembleApplication();
    await tester.pumpAndSettle();
    await reassembled;
    await mouse.moveBy(const Offset(1, 0));
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.textContaining('Raw request', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('real context shows the saved prompt and usage, expands input, and exports the session', (tester) async {
    await showContext(tester, indicator: true);
    expect(find.text('Tracing was not enabled for this session.'), findsOneWidget);
    final traceDownload = tester.widget<TextButton>(find.ancestor(of: find.text('Export & copy path'),
      matching: find.byWidgetPredicate((widget) => widget is TextButton)).first);
    expect(traceDownload.onPressed, isNull);
    for (final label in ['Refresh session trace counts', 'Attach End-to-end trace to new session']) {
      expect(tester.widget<IconButton>(find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == label)).onPressed, isNull);
    }
    expect(client.traceReading, isNull);
    await tester.runAsync(() async {
      for (final file in ['telemetry.sqlite', 'telemetry-desktop.sqlite']) {
        expect(await File('${root.path}/$file').exists(), isFalse);
      }
    });
    expect(find.text('Total Tokens'), findsOneWidget);
    expect(find.text('120'), findsNWidgets(2));
    await reveal(tester, find.text('System Prompt'));
    expect(find.text('You are the saved system prompt.', findRichText: true), findsNothing);
    expect(find.byTooltip('Copy system prompt'), findsOneWidget);
    await tester.tap(find.text('System Prompt'));
    await tester.pumpAndSettle();
    expect(find.text('You are the saved system prompt.', findRichText: true), findsOneWidget);
    await tester.tap(find.text('System Prompt'));
    await tester.pumpAndSettle();
    expect(find.text('You are the saved system prompt.', findRichText: true), findsNothing);
    for (final (title, marker) in [('Tools', '"type": "custom"'),
        ('Model settings', '"parallel_tool_calls": true')]) {
      final contents = find.textContaining(marker, findRichText: true);
      await reveal(tester, find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(contents, findsOneWidget);
      final reassembled = tester.binding.reassembleApplication();
      await tester.pumpAndSettle();
      await reassembled;
      expect(contents, findsOneWidget);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(contents, findsNothing);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(contents, findsOneWidget);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    final prompt = find.textContaining('developer • System Prompt •', findRichText: true);
    await reveal(tester, prompt);
    await tester.tap(prompt);
    await tester.pumpAndSettle();
    final promptJson = find.textContaining('"text": "You are the saved system prompt."', findRichText: true);
    await reveal(tester, promptJson);
    expect(promptJson, findsOneWidget);
    await tester.tap(prompt);
    await tester.pumpAndSettle();
    expect(promptJson, findsNothing);
    await reveal(tester, find.text('user • msg_item_user'));
    await tester.tap(find.text('user • msg_item_user'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Raw request', findRichText: true), findsOneWidget);
    final contents = await export(tester);
    final exported = jsonDecode(contents) as Map;
    expect(exported['model'], 'fixture');
    expect(exported.containsKey('context'), false);
    expect(contents, contains('Raw request'));
    final input = exported['input'] as List;
    expect(input.first['role'], 'developer');
    expect(input.first['content'], [{'type': 'input_text', 'text': 'You are the saved system prompt.'}]);
    expect(input.skip(1).map((item) => item['id']), ['msg_item_user', 'msg_item_answer']);
    expect(input.last['content'], [{'type': 'output_text', 'text': 'Answer'}]);
    expect(exported['reasoning'], {'effort': 'high', 'summary': 'auto'});
    for (final key in ['instructions', 'info', 'settings', 'snapshotID', 'cursor']) {
      expect(exported.containsKey(key), false);
    }
    for (final item in input) {
      for (final key in ['version', 'kind', 'native', 'synthetic']) {
        expect(item.containsKey(key), false);
      }
    }
    expect(RegExp('You are the saved system prompt.').allMatches(contents).length, 1);
    expect(client.methods.where((method) => method == 'session.message.list'), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('all context pages display in model order and export the displayed snapshot', (tester) async {
    client.pageLimit = 2;
    client.store.append('input.committed', {'message_id': 'later',
      'item': ConversationItem.text('user', 'Later request', id: 'item_later').toJson()});
    await showContext(tester);
    client.store.append('input.committed', {'message_id': 'new',
      'item': ConversationItem.text('user', 'After snapshot', id: 'item_new').toJson()});
    await reveal(tester, find.text('user • msg_item_later'));
    expect(find.text('user • msg_item_later'), findsOneWidget);
    expect(find.text('user • msg_item_new'), findsNothing);
    final first = tester.getTopLeft(find.text('user • msg_item_user')).dy;
    final second = tester.getTopLeft(find.text('assistant • msg_item_answer')).dy;
    final third = tester.getTopLeft(find.text('user • msg_item_later')).dy;
    expect(first, lessThan(second));
    expect(second, lessThan(third));
    final exported = jsonDecode(await export(tester)) as Map;
    expect((exported['input'] as List).skip(1).map((item) => item['id']),
      ['msg_item_user', 'msg_item_answer', 'msg_item_later']);
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
    await reveal(tester, find.text('assistant • msg_item_after'));
    expect(find.text('developer • msg_item_summary'), findsOneWidget);
    expect(find.text('user • msg_item_user'), findsNothing);
    expect(find.text('assistant • msg_item_answer'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a context change during paging refreshes the complete snapshot', (tester) async {
    client.pageLimit = 1;
    final gate = (await tester.runAsync(() async => (arrived: Completer<void>(), release: Completer<void>())))!;
    client.pageGate = gate;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SessionContextWindow(session: session, task: task))));
    await tester.runAsync(() => gate.arrived.future.timeout(const Duration(seconds: 10)));
    final compacted = client.store.append('context.compacted', {'summary': 'Replacement', 'input': [
      ConversationItem.text('developer', 'New snapshot', id: 'item_replacement').toJson(),
    ]});
    for (final event in compacted['session_events']) { client.events.add(jsonObject(event)); }
    await tester.pump();
    await tester.runAsync(() async { gate.release.complete(); });
    await settleRead(tester);
    await reveal(tester, find.text('developer • msg_item_replacement'));
    expect(find.text('assistant • msg_item_answer'), findsNothing);
    expect(find.text('user • msg_item_user'), findsNothing);
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
    await reveal(tester, find.text('System Prompt'));
    await tester.tap(find.text('System Prompt'));
    await tester.pumpAndSettle();
    expect(find.text('Prompt from the request envelope', findRichText: true), findsOneWidget);
    await reveal(tester, find.text('Raw messages'));
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
    await reveal(tester, find.text('assistant • msg_item_after'));
    expect(find.text('user • msg_item_user'), findsNothing);
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
  Future<Json>? traceReading;
  int? pageLimit;
  ({Completer<void> arrived, Completer<void> release})? pageGate;

  @override Future<TraceStore> startTracing(String directory) =>
    _ioZone.run(() => remote.startTracing(directory));
  @override void traceSession(String sessionID) => remote.traceSession(sessionID);
  @override Future<Json> traceStatus(String sessionID, {required CancellationToken cancellation}) =>
    traceReading = _ioZone.run<Future<Json>>(() => remote.traceStatus(sessionID, cancellation: cancellation));
  @override Future<Json> tracePage(String sessionID, {int after = 0, int? through,
    required CancellationToken cancellation}) => _ioZone.run(() => remote.tracePage(
      sessionID, after: after, through: through, cancellation: cancellation));

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
