import 'dart:io';

import 'package:desktop/app.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('tool details remain readable through updates and expansion', (tester) async {
    late Directory root;
    late AgentServer server;
    late DesktopSession session;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-view-');
      addTearDown(() => root.delete(recursive: true));
      final config = File('${root.path}/config.yaml');
      await config.writeAsString('{}');
      server = await AgentServer.startEmbedded(
        directory: root.path,
        configPath: config.path,
      );
      addTearDown(server.close);
      session = DesktopSession(
        await HttpOverrides.runWithHttpOverrides(
          () => AgentClient.connect(server.uri),
          _LocalHttpOverrides(),
        ),
        await openDesktopDatabase(root.path),
      );
      addTearDown(session.close);
    });
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final task = DesktopTask('task', 'Inspect runtime tools')..running = true;
    session.projects.add(Project('checkout', 'project', root.path, [task]));
    session.project = session.projects.single;
    session.task = task;
    var sequence = 0;
    Future<void> emit(String type, Json data) async {
      session.client.events.add({
        'task_id': task.id,
        'seq': ++sequence,
        'type': type,
        'data': data,
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.macOS),
      home: DesktopView(session: session),
    ));
    await emit('tool.started', {
      'call_id': 'cell',
      'namespace': 'functions',
      'name': 'exec',
      'input': 'text(await tools.runtime_status({}));',
    });
    expect(find.text('Code & output'), findsNothing);
    await tester.tap(find.text('functions.exec'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Code & output'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('text(await tools.runtime_status({}));'), findsOneWidget);
    final source = tester.widget<SelectableText>(find.byType(SelectableText).first);
    expect(source.textSpan, isNotNull);
    final tokens = <TextSpan>[];
    source.textSpan!.visitChildren((span) {
      if (span is TextSpan) tokens.add(span);
      return true;
    });
    expect(tokens.where((span) => span.text == 'await').single.style?.color, isNotNull);
    expect(tokens.where((span) => span.text == 'text').single.style?.color, isNotNull);

    await emit('host_tool.started', {
      'id': 'host',
      'parent_call_id': 'cell',
      'name': 'runtime_status',
      'arguments': <String, Object?>{},
    });
    await emit('host_tool.completed', {'id': 'host', 'output': 'One active app'});
    await emit('tool.completed', {
      'item': {
        'content': [
          {'call_id': 'cell', 'output': 'One active app'},
        ],
      },
    });
    await emit('turn.completed', {});
    await tester.pumpAndSettle();
    const details = 'text(await tools.runtime_status({}));\n\nOne active app';
    expect(find.text(details), findsOneWidget);
    final completed = tester.widget<SelectableText>(find.byType(SelectableText).first);
    expect(completed.textSpan!.toPlainText(), details);
    final output = <TextSpan>[];
    completed.textSpan!.visitChildren((span) {
      if (span is TextSpan && span.text == '\n\nOne active app') output.add(span);
      return true;
    });
    expect(output.single.style?.color, isNull);

    await tester.tap(find.text('Code & output'));
    await tester.pumpAndSettle();
    expect(find.text(details), findsNothing);
    await tester.tap(find.text('functions.exec'));
    await tester.pumpAndSettle();
    expect(find.text('Code & output'), findsNothing);
    await tester.tap(find.text('functions.exec'));
    await tester.pumpAndSettle();
    expect(find.text('Code & output'), findsOneWidget);
    expect(find.text(details), findsNothing);
    await tester.tap(find.text('Code & output'));
    await tester.pumpAndSettle();
    expect(find.text(details), findsOneWidget);
    await tester.tap(find.text('runtime_status'));
    await tester.pumpAndSettle();
    expect(find.text('{}\n\nOne active app'), findsOneWidget);

    await emit('turn.started', {});
    session.client.events.add({'task_id': task.id, 'type': 'text.delta', 'delta': 'Abandoned partial answer'});
    await tester.pump();
    session.client.events.add({'task_id': task.id, 'type': 'model.retrying', 'attempt': 1, 'max_retries': 5});
    await tester.pump();
    expect(find.textContaining('Reconnecting… 1/5'), findsOneWidget);
    expect(find.text('Abandoned partial answer', findRichText: true), findsNothing);
    session.client.events.add({'task_id': task.id, 'type': 'text.delta', 'delta': 'Recovered answer'});
    await tester.pump();
    expect(find.textContaining('Reconnecting…'), findsNothing);
    expect(find.text('Recovered answer', findRichText: true), findsOneWidget);
    await emit('compaction.started', {'reason': 'overflow'});
    expect(session.task!.streamingText, isEmpty);
    expect(find.textContaining('Compacting context'), findsOneWidget);
    expect(find.textContaining('Working'), findsNothing);
    // Older servers can still send compaction deltas. Keep them out of prose.
    session.client.events.add({'task_id': task.id, 'type': 'text.delta', 'delta': 'Internal summary'});
    session.client.events.add({'task_id': task.id, 'type': 'model.retrying', 'attempt': 1, 'max_retries': 5});
    await tester.pump();
    expect(find.textContaining('Compacting context · Reconnecting… 1/5'), findsOneWidget);
    expect(find.text('Internal summary', findRichText: true), findsNothing);
    await emit('context.compacted', {'summary': ''});
    expect(session.task!.streamingText, isEmpty);
    expect(session.task!.retryStatus, isNull);
    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.textContaining('Working'), findsOneWidget);
    await emit('turn.completed', {});
    await tester.pumpAndSettle();

    // Failures before a durable sequence is available must remain in the
    // conversation, including after rebuilding the transcript.
    session.client.events.add({
      'task_id': task.id,
      'type': 'turn.failed',
      'data': {'error': 'Worker exited before replying'},
    });
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Worker exited before replying'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong'), findsOneWidget);
    await emit('turn.started', {});
    await emit('turn.completed', {});
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _LocalHttpOverrides extends HttpOverrides {}
