import 'dart:async';

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
      final session = DesktopSession(_Client(), _Database());
      addTearDown(session.close);
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
    });
  }
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}

class _Database implements IsolateOwner {
  @override Future<void> close() async {}
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected database operation');
}
