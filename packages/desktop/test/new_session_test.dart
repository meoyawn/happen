import 'dart:async';
import 'dart:io';

import 'package:desktop/composer_attachments.dart';
import 'package:desktop/database.dart';
import 'package:desktop/new_session.dart';
import 'package:desktop/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  for (final projectCount in [1, 12]) {
    testWidgets('project dropdown opens, filters, and selects with $projectCount projects', (tester) async {
      final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('new-session-')))!;
      final session = DesktopSession(_Client(), (await tester.runAsync(() => openDesktopDatabase(root.path)))!);
      var closed = false;
      addTearDown(() => tester.runAsync(() async {
        if (!closed) await session.close();
        await root.delete(recursive: true);
      }));
      session.projects.addAll([
        for (var index = 0; index < projectCount; index++)
          Project('checkout-$index', 'project-$index', '/projects/project-$index'),
      ]);
      session.project = session.projects.first;
      Project? selected;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: NewSessionScreen(
        session: session, composer: const SizedBox(height: 100), picking: false,
        onSelect: (project) => selected = project, onAddProject: () {},
        onRemoveProject: (_) {}, onReturnFocus: () {},
      ))));
      if (projectCount == 1) {
        final checkbox = find.byType(Checkbox);
        expect(tester.widget<Checkbox>(checkbox).value, isFalse);
        await tester.tap(find.text('Trace this session'));
        await tester.pump();
        expect(tester.widget<Checkbox>(checkbox).value, isTrue);
        final tracedDraft = session.currentDraft;
        session.newSession();
        await tester.pump();
        expect(session.currentDraft, same(tracedDraft));
        expect(session.sessionDrafts, hasLength(1));
        expect(tester.widget<Checkbox>(checkbox).value, isTrue);
        session.drafts[tracedDraft.id] = 'Keep this draft';
        session.newSession();
        await tester.pump();
        expect(tester.widget<Checkbox>(checkbox).value, isFalse);
        final attachmentDraft = session.currentDraft;
        final attachment = ComposerAttachment(name: 'draft.txt', path: '/draft.txt', image: false);
        session.attachmentDrafts[attachmentDraft.id] = [attachment];
        session.newSession();
        expect(session.currentDraft, isNot(same(attachmentDraft)));
        expect(session.attachmentDrafts[attachmentDraft.id], [attachment]);
        expect(session.drafts[tracedDraft.id], 'Keep this draft');
        session.openDraft(tracedDraft);
        await tester.pump();
        expect(tester.widget<Checkbox>(checkbox).value, isTrue);
        session.submitting = true;
        session.notifyListeners();
        await tester.pump();
        expect(tester.widget<Checkbox>(checkbox).onChanged, isNull);
        session.submitting = false;
        session.notifyListeners();
        await tester.pump();
      }
      if (projectCount > 1) {
        final firstDraft = session.currentDraft;
        session.newSession(session.projects.last);
        expect(session.currentDraft, isNot(same(firstDraft)));
        session.newSession(session.projects.first);
        expect(session.currentDraft, same(firstDraft));
        expect(session.sessionDrafts, hasLength(2));
        await tester.pump();
      }

      final dropdown = find.byTooltip('Select project');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(dropdown));
      addTearDown(mouse.removePointer);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('project-search')), findsOneWidget);

      if (projectCount > 1) {
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byKey(const ValueKey('project-search')), 'not-a-project');
      await tester.pumpAndSettle();
      expect(find.text('No projects found.'), findsOneWidget);
      final target = session.projects.last;
      await tester.enterText(find.byKey(const ValueKey('project-search')), target.name);
      await tester.pumpAndSettle();
      final row = find.descendant(of: find.byType(ListView), matching: find.text(target.path));
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(selected, same(target));
      expect(find.byKey(const ValueKey('project-search')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('project-search')), findsOneWidget,
        reason: 'The dropdown remains usable after closing and reopening');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await session.close(); closed = true; });
      await tester.pump();
    });
  }
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
