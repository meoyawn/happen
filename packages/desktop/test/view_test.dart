import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:desktop/app.dart';
import 'package:desktop/composer_text_controller.dart';
import 'package:desktop/conversation.dart';
import 'package:desktop/database.dart';
import 'package:desktop/inline_reference.dart';
import 'package:desktop/session.dart';
import 'package:desktop_drop/src/native_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  late _Client client;
  late DesktopSession session;
  Directory? directory;
  setUp(() {
    client = _Client();
    session = DesktopSession(client, _Database());
    session.providers = [
      {'id': 'openai', 'name': 'ChatGPT', 'auth': 'chatgpt', 'status': 'signed_in', 'default_model': 'gpt-6.1-sol', 'models': [
        {'id': 'gpt-6.1-sol', 'default_reasoning': 'low', 'reasoning_levels': ['low'], 'reasoning_updates': true},
      ]},
      {'id': 'opencode', 'name': 'OpenCode', 'auth': 'opencode', 'status': 'signed_out', 'models': []},
    ];
    client.providers = session.providers;
    final task = DesktopTask('task', 'Example')
      ..loaded = true
      ..provider = 'openai'
      ..model = 'gpt-6.1-sol'
      ..reasoning = 'low';
    session.projects.add(Project('checkout', '/project', '/project', [task]));
    session.project = session.projects.single;
    session.task = task;
  });
  tearDown(() async {
    await session.close();
    await directory?.delete(recursive: true);
    directory = null;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
    // Settle the conversation's initial connection inventory before exercising
    // a composer command. Auth rendering has its own browser/lifecycle tests.
    for (final inventory in client.inventories) {
      if (!inventory.reply.isCompleted) inventory.reply.complete({'servers': []});
    }
    client.inventories.clear();
    await tester.pumpAndSettle();
  }

  testWidgets('sidebar sections collapse independently and pin menus move tasks and projects', (tester) async {
    final first = session.task!..lastActivity = 100;
    final other = DesktopTask('other', 'Other task')..loaded = true..lastActivity = 200;
    final secondProject = Project('other-checkout', '/other', '/other', [other]);
    session.projects.add(secondProject);
    late IsolateOwner database;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('desktop-sidebar-view-');
      database = await openDesktopDatabase(directory!.path);
      for (final project in session.projects) {
        await callIsolate(database.port, 'project.add', {
          'checkout_key': project.checkoutKey, 'identity': project.id, 'path': project.path,
        });
        for (final task in project.tasks) {
          await callIsolate(database.port, 'task.add', {
            'id': task.id, 'checkout_key': project.checkoutKey, 'title': task.title, 'last_activity': task.lastActivity,
          });
        }
      }
      final previous = session;
      await previous.close();
      client = _Client()..providers = previous.providers;
      session = DesktopSession(client, database)
        ..providers = previous.providers
        ..projects.addAll(previous.projects)
        ..project = previous.project
        ..task = previous.task;
    });
    await open(tester);
    final pinned = find.byKey(const ValueKey('section:pinned'));
    final projects = find.byKey(const ValueKey('section:projects'));
    final recents = find.byKey(const ValueKey('section:recents'));
    expect(tester.getTopLeft(pinned).dy, lessThan(tester.getTopLeft(projects).dy));
    expect(tester.getTopLeft(projects).dy, lessThan(tester.getTopLeft(recents).dy));
    expect(tester.getTopLeft(find.byKey(const ValueKey('recents:other'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('recents:task'))).dy));
    await tester.tap(find.byKey(const ValueKey('recents:task')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this draft');

    Future<void> menu(Finder row, String action, bool Function() applied) async {
      await tester.ensureVisible(row);
      await tester.tap(find.descendant(of: row, matching: find.byType(PopupMenuButton<String>)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      for (var attempt = 0; !applied() && session.error == null && attempt < 100; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(applied(), true, reason: session.error);
    }
    Future<void> toggle(String section) async {
      final header = find.byKey(ValueKey('section-header:$section'));
      await tester.ensureVisible(header);
      await tester.runAsync(() async {
        await tester.tap(header);
        await callIsolate(database.port, 'load', {});
      });
      await tester.pumpAndSettle();
    }

    await menu(find.byKey(const ValueKey('projects:task')), 'Pin task', () => session.pinnedTaskIds.contains(first.id));
    expect(session.pinnedTaskIds, [first.id], reason: session.error);
    expect(find.byKey(const ValueKey('pinned:task')), findsOneWidget);
    expect(find.byKey(const ValueKey('projects:task')), findsNothing);
    expect(find.byKey(const ValueKey('recents:task')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(session.task, same(first), reason: 'Pinning the selected recent task moves navigation into Pinned');
    await menu(find.byKey(const ValueKey('project:other-checkout')), 'Pin project', () => session.pinnedProjectKeys.contains(secondProject.checkoutKey));
    expect(tester.getTopLeft(find.byKey(const ValueKey('project:other-checkout'))).dy,
      lessThan(tester.getTopLeft(projects).dy));
    await toggle('pinned');
    expect(find.byKey(const ValueKey('pinned:task')), findsNothing);
    expect(find.byKey(const ValueKey('project:other-checkout')), findsNothing);
    expect(find.byKey(const ValueKey('project:checkout')), findsOneWidget);
    expect(find.byKey(const ValueKey('recents:other')), findsOneWidget);
    await toggle('projects');
    expect(find.byKey(const ValueKey('project:checkout')), findsNothing);
    expect(find.byKey(const ValueKey('recents:other')), findsOneWidget);
    expect(session.task, same(first));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep this draft');

    await tester.tap(find.byKey(const ValueKey('recents:other')));
    await tester.pumpAndSettle();
    expect(session.task, same(other));
    expect(session.project, same(secondProject));
    expect(session.drafts[first.id], 'Keep this draft');
    await toggle('recents');
    expect(find.byKey(const ValueKey('recents:other')), findsNothing);
    expect(find.byType(ConversationTranscript), findsOneWidget);
    await toggle('pinned');
    await menu(find.byKey(const ValueKey('pinned:task')), 'Unpin task', () => !session.pinnedTaskIds.contains(first.id));
    await menu(find.byKey(const ValueKey('project:other-checkout')), 'Unpin project', () => !session.pinnedProjectKeys.contains(secondProject.checkoutKey));
    expect(find.text('No pinned items'), findsOneWidget);
    await toggle('projects');
    await toggle('recents');
    expect(find.byKey(const ValueKey('projects:task')), findsOneWidget);
    expect(find.byKey(const ValueKey('recents:task')), findsOneWidget);
    expect(client.sent, isEmpty);
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('project headings collapse independently without changing the conversation or draft', (tester) async {
    final project = session.project!, task = session.task!;
    final other = DesktopTask('other', 'Other task')..loaded = true;
    session.projects.add(Project('other-checkout', '/other', '/other', [other]));
    await open(tester);
    final row = find.byKey(const ValueKey('project:checkout'));
    final taskRow = find.byKey(ValueKey('projects:${task.id}'));
    final otherRow = find.byKey(ValueKey('projects:${other.id}'));
    await tester.enterText(find.byType(TextField), 'Keep this draft');

    await tester.tap(find.descendant(of: row, matching: find.text(project.name)));
    await tester.pumpAndSettle();
    expect(taskRow, findsNothing);
    expect(otherRow, findsOneWidget);
    expect(session.task, same(task));
    expect(session.project, same(project));
    expect(find.byType(ConversationTranscript), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep this draft');

    await tester.runAsync(() => session.select(project, task));
    await tester.pumpAndSettle();
    expect(taskRow, findsNothing);
    await tester.tap(find.byTooltip('Collapse other'));
    await tester.pumpAndSettle();
    expect(otherRow, findsNothing);
    await tester.tap(find.byTooltip('Expand project'));
    await tester.pumpAndSettle();
    expect(taskRow, findsOneWidget);
    expect(otherRow, findsNothing);

    await tester.tap(find.byTooltip('Collapse project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New task in project'));
    await tester.pumpAndSettle();
    expect(session.task, isNull);
    expect(taskRow, findsOneWidget);
    expect(otherRow, findsNothing);
    expect(session.drafts[task.id], 'Keep this draft');
    expect(client.sent, isEmpty);
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Option arrows follow Recents and Pinned locations without jumping between duplicate tasks', (tester) async {
    final alpha = session.task!..lastActivity = 20;
    DesktopTask task(String id, int activity) => DesktopTask(id, id)
      ..loaded = true..provider = 'openai'..model = 'gpt-6.1-sol'..lastActivity = activity;
    final beta = task('beta', 40), pinAlpha = task('pin-alpha', 50);
    final gamma = task('gamma', 30), delta = task('delta', 10), pinBeta = task('pin-beta', 60);
    session.project!.tasks.addAll([beta, pinAlpha]);
    session.projects.add(Project('other-checkout', '/other', '/other', [gamma, delta, pinBeta]));
    session.pinnedTaskIds.addAll([pinBeta.id, pinAlpha.id]);
    await open(tester);

    Future<void> arrow(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
    }
    Future<void> click(String section, DesktopTask task) async {
      final row = find.byKey(ValueKey('$section:${task.id}'));
      await tester.ensureVisible(row);
      await tester.tap(row, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
    }

    await click('recents', beta);
    await tester.enterText(find.byType(TextField), 'Recent task draft');
    for (final expected in [gamma, alpha, delta, delta]) {
      await arrow(LogicalKeyboardKey.arrowDown);
      expect(session.task, same(expected));
    }
    // History hydration or live activity can change the displayed sort while
    // traversing. Reversing must retrace the same tasks until another row click.
    alpha.lastActivity = 100;
    session.notifyListeners();
    await tester.pumpAndSettle();
    for (final expected in [alpha, gamma, beta, beta]) {
      await arrow(LogicalKeyboardKey.arrowUp);
      expect(session.task, same(expected));
    }
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Recent task draft');
    await click('pinned', pinBeta);
    for (final expected in [pinAlpha, pinAlpha]) {
      await arrow(LogicalKeyboardKey.arrowDown);
      expect(session.task, same(expected));
    }
    await arrow(LogicalKeyboardKey.arrowUp);
    expect(session.task, same(pinBeta));
    await arrow(LogicalKeyboardKey.arrowUp);
    expect(session.task, same(pinBeta));
    await click('projects', alpha);
    await arrow(LogicalKeyboardKey.arrowDown);
    expect(session.task, same(beta), reason: 'Clicking a project row switches back to project order');
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, true);
    session.pinnedProjectKeys.add('other-checkout');
    session.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Collapse other'));
    await tester.pumpAndSettle();
    await click('recents', gamma);
    await arrow(LogicalKeyboardKey.arrowDown);
    expect(session.task, same(delta));
    expect(find.byTooltip('Expand other'), findsOneWidget,
      reason: 'Recent navigation preserves a pinned project\'s disclosure');
    final older = [for (var index = 0; index < 12; index++) task('older-$index', 0)];
    session.projects.first.tasks.addAll(older);
    session.collapsedSidebarSections.add('projects');
    session.notifyListeners();
    await tester.pumpAndSettle();
    await click('recents', delta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(session.task, same(older.first));
    for (final expected in older.skip(1)) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(session.task, same(expected));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    expect(find.byKey(const ValueKey('recents:older-11')).hitTestable(), findsOneWidget);
    expect(client.sent, isEmpty);
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('missing projects are greyed out with readable history and an active removal menu', (tester) async {
    final project = session.project!..available = false;
    await open(tester);
    final row = find.byKey(const ValueKey('project:checkout'));
    expect(tester.widget<ListTile>(row).enabled, false);
    expect(find.descendant(of: row, matching: find.text('Folder unavailable')), findsOneWidget);
    expect(tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'New task in project')).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'New task')).onPressed, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ConversationTranscript), findsOneWidget);
    expect(find.text('Project folder is unavailable'), findsOneWidget);
    expect(find.text('Check again'), findsNothing);
    final taskRow = find.byKey(ValueKey('projects:${session.task!.id}'));
    await tester.tap(find.byTooltip('Collapse project'));
    await tester.pumpAndSettle();
    expect(taskRow, findsNothing);
    expect(find.byType(ConversationTranscript), findsOneWidget);
    await tester.tap(find.byTooltip('Expand project'));
    await tester.pumpAndSettle();
    expect(taskRow, findsOneWidget);
    expect(tester.widget<PopupMenuButton<String>>(find.byWidgetPredicate((widget) => widget is PopupMenuButton<String> && widget.tooltip == 'Project actions')).enabled, true);
    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Remove project'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(session.projects.single, same(project));
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('project removal confirms, persists, and returns the last project to the empty workspace', (tester) async {
    late IsolateOwner database;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('desktop-remove-');
      database = await openDesktopDatabase(directory!.path);
      await callIsolate(database.port, 'project.add', {'checkout_key': 'checkout', 'identity': '/project', 'path': '/project'});
      await callIsolate(database.port, 'task.add', {'id': 'task', 'checkout_key': 'checkout', 'title': 'Example'});
      final previous = session;
      await previous.close();
      client = _Client();
      session = DesktopSession(client, database)
        ..providers = previous.providers
        ..projects.addAll(previous.projects)
        ..project = previous.project
        ..task = previous.task;
    });
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Draft to discard');
    Future<void> confirmRemoval() async {
      await tester.tap(find.byTooltip('Project actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Remove project'));
      await tester.pumpAndSettle();
    }
    await confirmRemoval();
    expect(find.textContaining('The folder and saved task history will be kept.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(session.projects, hasLength(1));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Draft to discard');
    await confirmRemoval();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove project'));
    await tester.pumpAndSettle();
    for (var attempt = 0; session.projects.isNotEmpty && session.error == null && attempt < 100; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(session.error, isNull);
    expect(session.project, isNull);
    expect(session.task, isNull);
    expect(session.drafts, isEmpty);
    expect(find.byKey(const ValueKey('project:checkout')), findsNothing);
    expect(find.text('Start with a project'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}));
      expect(saved['projects'], isEmpty);
      expect(saved['tasks'], isEmpty);
    });
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Option arrows follow sidebar tasks across projects while editing', (tester) async {
    final firstProject = session.project!, first = session.task!;
    final second = DesktopTask('second', 'Second task')..loaded = true;
    firstProject.tasks.addAll([
      DesktopTask('archived', 'Archived task')..archived = true,
      second,
    ]);
    final third = DesktopTask('third', 'Third task')..loaded = true;
    final fourth = DesktopTask('fourth', 'Fourth task')..loaded = true;
    final nextProject = Project('next', '/next', '/next', [third, fourth]);
    session.projects.addAll([
      Project('empty', '/empty', '/empty'),
      Project('archived-only', '/archived-only', '/archived-only', [
        DesktopTask('hidden', 'Hidden task')..archived = true,
      ]),
      nextProject,
    ]);
    session.drafts[third.id] = 'Third task draft';
    await open(tester);
    await tester.enterText(find.byType(TextField), 'First task draft\nAnother line');
    await tester.pump();
    await tester.tap(find.byTooltip('Collapse project'));
    await tester.tap(find.byTooltip('Collapse next'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(session.task, same(first));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(session.task, same(second));
    expect(session.project, same(firstProject));
    expect(find.byTooltip('Collapse project'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(session.task, same(third));
    expect(session.project, same(nextProject));
    expect(find.byTooltip('Collapse next'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Third task draft');
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(session.task, same(fourth));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(session.task, same(fourth));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    for (final task in [third, second, first, first]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(session.task, same(task));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    final editor = tester.widget<TextField>(find.byType(TextField));
    expect(session.project, same(firstProject));
    expect(editor.controller!.text, 'First task draft\nAnother line');
    expect(editor.focusNode!.hasFocus, true);
    expect(client.sent, isEmpty);
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Option arrows work after focusing the sidebar and without a composer', (tester) async {
    final project = session.project!, first = session.task!;
    final second = DesktopTask('second', 'Second task')..loaded = true;
    project.tasks.add(second);
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.tap(find.byKey(ValueKey('projects:${first.id}')), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    final sidebar = tester.getRect(find.byKey(const ValueKey('sidebar')));
    await tester.tapAt(Offset(sidebar.center.dx, sidebar.top + 500), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(session.task, same(second));
    expect(session.drafts[first.id], 'Keep this draft');
    project.available = false;
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    await tester.pumpAndSettle();
    expect(session.task, same(first));
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Option arrows handle new drafts and an empty sidebar', (tester) async {
    final project = session.project!, first = session.task!;
    final last = DesktopTask('last', 'Last task')..loaded = true;
    session.projects.add(Project('next', '/next', '/next', [last]));
    session.task = null;
    await open(tester);
    await tester.enterText(find.byType(TextField), 'New task draft');
    Future<void> navigate(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      await tester.pumpAndSettle();
    }
    await navigate(LogicalKeyboardKey.arrowDown);
    expect(session.task, same(first));
    await tester.runAsync(() => session.select(project));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'New task draft');
    await navigate(LogicalKeyboardKey.arrowUp);
    expect(session.task, same(last));
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    await navigate(LogicalKeyboardKey.arrowUp);
    expect(session.task, same(last));
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => session.select(project));
    project.tasks.clear();
    session.projects.removeLast();
    await tester.pumpAndSettle();
    await navigate(LogicalKeyboardKey.arrowUp);
    await navigate(LogicalKeyboardKey.arrowDown);
    expect(session.task, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'New task draft');
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('context circle uses the latest response and retains cache hits across replay and live events', (tester) async {
    final task = session.task!;
    task.events.addAll({
      3: {'seq': 3, 'type': 'model.completed', 'data': {'usage': {'input_tokens': 39000, 'output_tokens': 1000, 'cached_input_tokens': 30000}}},
      1: {'seq': 1, 'type': 'task.created', 'data': {'provider_settings': {'context_limit': 100000}}},
      2: {'seq': 2, 'type': 'model.completed', 'data': {'usage': {'input_tokens': 10000, 'output_tokens': 1000, 'cached_input_tokens': 0}}},
    });
    await open(tester);
    final circle = find.bySemanticsLabel(RegExp(r'^Context usage:'));
    final contextTooltip = find.byWidgetPredicate((widget) => widget is Tooltip && widget.richMessage?.toPlainText().startsWith('Context window:') == true);
    expect(find.bySemanticsLabel('Context usage: 40%'), findsOneWidget);
    expect(tester.getSize(contextTooltip), const Size.square(28));
    final modelPicker = find.byTooltip('Model and reasoning effort');
    expect(tester.getCenter(circle).dx, greaterThan(tester.getCenter(find.byType(TextField)).dx));
    expect(tester.getCenter(circle).dx, lessThan(tester.getRect(modelPicker).left));
    expect(tester.getRect(modelPicker).right, lessThan(tester.getCenter(find.byTooltip('Dictate')).dx));
    expect(find.text('Enter to send · Shift+Enter for a new line'), findsNothing);
    expect(find.text('40%'), findsNothing, reason: 'Usage text belongs in the tooltip');
    await tester.enterText(find.byType(TextField), 'Keep my draft');
    final editor = tester.widget<TextField>(find.byType(TextField));
    final selection = editor.controller!.selection;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    Future<void> hover() async {
      final target = tester.getRect(contextTooltip);
      await mouse.moveTo(Offset(target.left + 2, target.center.dy));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }
    Future<void> leave() async {
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }
    await hover();
    expect(find.textContaining('40% used (60% left)', findRichText: true), findsOneWidget);
    expect(find.textContaining('40k / 100k tokens used', findRichText: true), findsOneWidget);
    expect(find.textContaining('Cache hits\nConversation: 61.2% (30000 / 49000 input tokens)\nLatest response: 76.9% (30000 / 39000 input tokens)', findRichText: true), findsOneWidget);
    await leave();
    client.events.add({'task_id': 'task', ...task.events[3]!});
    client.events.add({'task_id': 'task', 'seq': 4, 'type': 'model.completed', 'data': {'usage': {'input_tokens': 59000, 'output_tokens': 1000, 'cached_input_tokens': 50000}}});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: 60%'), findsOneWidget);
    await hover();
    expect(find.textContaining('60% full', findRichText: true), findsOneWidget);
    expect(find.textContaining('Conversation: 74.1% (80000 / 108000 input tokens)', findRichText: true), findsOneWidget);
    expect(find.textContaining('Latest response: 84.7% (50000 / 59000 input tokens)', findRichText: true), findsOneWidget);
    await leave();
    client.events.add({'task_id': 'task', 'seq': 5, 'type': 'context.compacted', 'data': {'usage': {'input_tokens': 10000, 'output_tokens': 1000, 'cached_input_tokens': 0}}});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: unavailable'), findsOneWidget, reason: 'Compaction request usage describes the old context');
    await hover();
    expect(find.textContaining('Usage unavailable', findRichText: true), findsOneWidget);
    expect(find.textContaining('60k / 100k tokens used', findRichText: true), findsNothing);
    expect(find.textContaining('Conversation: 67.8% (80000 / 118000 input tokens)', findRichText: true), findsOneWidget);
    await leave();
    client.events.add({'task_id': 'task', 'seq': 6, 'type': 'model.completed', 'data': {'usage': {'input_tokens': 2000, 'output_tokens': 1000, 'cached_input_tokens': 0}}});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: 3%'), findsOneWidget);
    await hover();
    expect(find.textContaining('Conversation: 66.7% (80000 / 120000 input tokens)', findRichText: true), findsOneWidget);
    expect(find.textContaining('Latest response: 0.0% (0 / 2000 input tokens)', findRichText: true), findsOneWidget);
    await leave();
    for (final (seq, input, output, percent) in [(7, 100000, 5000, 100), (8, 0, 0, 0)]) {
      client.events.add({'task_id': 'task', 'seq': seq, 'type': 'model.completed', 'data': {'usage': {'input_tokens': input, 'output_tokens': output}}});
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Context usage: $percent%'), findsOneWidget);
    }
    expect(editor.controller!.text, 'Keep my draft');
    expect(editor.controller!.selection, selection);
    expect(editor.focusNode!.hasFocus, true);
    expect(client.sent, isEmpty);
    final fresh = DesktopTask('fresh', 'Fresh')..loaded = true..provider = 'openai'..model = 'gpt-6.1-sol'..reasoning = 'low';
    session.project!.tasks.add(fresh);
    await tester.runAsync(() => session.select(session.project!, fresh));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: unavailable'), findsOneWidget, reason: 'Missing measurements must leave a discoverable control');
    await hover();
    expect(find.textContaining('Usage unavailable', findRichText: true), findsOneWidget);
    expect(find.textContaining('Cache hits', findRichText: true), findsNothing, reason: 'Missing data must not become a zero cache hit rate');
    await leave();
    await tester.runAsync(() => session.select(session.project!, task));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: 0%'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep my draft');
    client.events.add({'task_id': 'task', 'seq': 9, 'type': 'model.completed', 'data': {'usage': {'input_tokens': -1, 'output_tokens': 1000}}});
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Context usage: unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('one composer action switches between sending, stopping and follow-ups', (tester) async {
    await open(tester);
    Future<void> frame() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    IconButton action(String tooltip) => tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == tooltip));
    expect(action('Send message').onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'First message');
    await tester.pumpAndSettle();
    expect(action('Send message').onPressed, isNotNull);
    await tester.tap(find.byTooltip('Send message'));
    await frame();
    expect(client.sent.single['prompt'], 'First message');
    expect(find.byTooltip('Send message'), findsNothing);
    expect(find.byTooltip('Steer task'), findsNothing);
    expect(action('Stop task and clear pending messages').onPressed, isNotNull);
    for (final (mode, label) in [('steer', 'Steer task'), ('queue', 'Queue message')]) {
      session.deliveryMode = mode;
      await tester.enterText(find.byType(TextField), 'Follow up $mode');
      await frame();
      expect(find.byTooltip('Stop task and clear pending messages'), findsNothing);
      expect(action(label).onPressed, isNotNull);
      await tester.tap(find.byTooltip(label));
      await frame();
      expect(client.sent.last['prompt'], 'Follow up $mode');
      expect(client.sent.last['delivery'], mode);
      expect(find.byTooltip(label), findsNothing);
      expect(action('Stop task and clear pending messages').onPressed, isNotNull);
    }
    await tester.enterText(find.byType(TextField), '   ');
    await frame();
    session.providers.first['status'] = 'signed_out';
    client.events.add({'task_id': 'task', 'type': 'text.delta', 'delta': ''});
    await frame();
    expect(action('Stop task and clear pending messages').onPressed, isNotNull, reason: 'Stopping must remain possible after sign-out');
    await tester.tap(find.byTooltip('Stop task and clear pending messages'));
    await tester.pump();
    expect(client.cancelled, ['task']);
    client.events.add({'task_id': 'task', 'type': 'turn.cancelled', 'data': {}});
    await tester.pumpAndSettle();
    expect(find.byTooltip('Stop task and clear pending messages'), findsNothing);
    expect(action('Send message').onPressed, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '   ');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('MCP submenu preserves the draft and file chips and never submits the command', (tester) async {
    await open(tester);
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    await tester.enterText(find.byType(TextField), 'Keep /mcp tail ');
    controller.insertFile(TextRange.collapsed(controller.text.length), '/project/lib/main.dart');
    controller.selection = const TextSelection.collapsed(offset: 9);
    final before = tester.getRect(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(client.inventories, isEmpty, reason: 'The command suggestion alone does no discovery');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.inventories.single.verbose, false);
    expect(find.text('Loading MCP status…'), findsOneWidget);
    expect(controller.text, 'Keep  tail ${ComposerTextController.marker} ');
    expect(controller.files.single.path, '/project/lib/main.dart');
    expect(session.drafts['task'], controller.text);
    expect(client.sent, isEmpty);
    client.inventories.single.reply.complete({'servers': [
      {'name': 'dart', 'enabled': true, 'state': 'ready', 'tool_count': 12, 'auth_status': 'unsupported'},
      {'name': 'paused', 'enabled': false, 'state': 'disabled', 'tool_count': 0, 'auth_status': 'unsupported'},
    ]});
    await tester.pumpAndSettle();
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Auth unsupported'), findsNWidgets(2));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('dart')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.tap(find.text('dart'));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, true);
    expect(client.sent, isEmpty);
    expect(tester.getRect(find.byType(TextField)), before);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('dart'), findsNothing);
    expect(controller.files.single.path, '/project/lib/main.dart');
    await tester.enterText(find.byType(TextField), '/mcp');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    client.inventories.last.reply.complete({'servers': [{'name': 'dart', 'enabled': true, 'state': 'ready', 'tool_count': 1, 'auth_status': 'unsupported'}]});
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'dar');
    await tester.pumpAndSettle();
    expect(find.text('dart'), findsOneWidget);
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    client.events.add({'task_id': 'task', 'type': 'turn.completed', 'data': {}});
    await tester.pumpAndSettle();
    expect(client.sent.single['prompt'], 'dar');
    expect(find.text('dart'), findsNothing);
    expect(controller.text, isEmpty);
    await tester.enterText(find.byType(TextField), '@ma');
    await tester.pump(const Duration(milliseconds: 210));
    expect(client.searches.single.query, 'ma');
    client.searches.single.reply.complete({'paths': ['lib/main.dart'], 'truncated': false});
    await tester.pumpAndSettle();
    expect(find.text('lib/main.dart'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('MCP verbose shows tool and resource details during an unauthenticated running task', (tester) async {
    session.providers.first['status'] = 'signed_out';
    await open(tester);
    client.events.add({'task_id': 'task', 'type': 'turn.started', 'data': {}});
    Future<void> frame() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.enterText(find.byType(TextField), '/mcp verbose');
    final commandText = tester.widget<TextField>(find.byType(TextField)).controller!;
    commandText.selection = TextSelection(baseOffset: 0, extentOffset: commandText.text.length);
    await frame();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await frame();
    expect(client.inventories.single.verbose, true);
    client.inventories.single.reply.complete({'servers': [{
      'name': 'dart', 'enabled': true, 'state': 'ready', 'tool_count': 2, 'auth_status': 'configured_headers',
      'tools': ['analyze_files', 'hot_reload'],
      'resources': [{'name': 'docs', 'title': 'Documentation', 'uri': 'docs://index'}],
      'resource_templates': [], 'resource_templates_error': 'Unable to load resource templates',
    }]});
    await frame();
    expect(find.text('Configured HTTP headers'), findsOneWidget);
    expect(find.text('Connected · 2 tools'), findsOneWidget);
    expect(find.text('Tools: analyze_files, hot_reload'), findsOneWidget);
    expect(find.text('Resources: Documentation (docs://index)'), findsOneWidget);
    expect(find.text('Resource templates: Unable to load resource templates'), findsOneWidget);
    expect(client.sent, isEmpty);
    expect(session.task!.running, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frame();
    await tester.enterText(find.byType(TextField), '/mcp full');
    await frame();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await frame();
    expect(find.text('Usage: /mcp [verbose]'), findsOneWidget);
    expect(client.inventories, hasLength(1));
    expect(client.sent, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('MCP discovery retires late replies, refreshes config and cancels on navigation', (tester) async {
    await open(tester);
    Future<void> show() async {
      await tester.enterText(find.byType(TextField), '/mcp');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }
    await show();
    final obsolete = client.inventories.single;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(obsolete.cancellation.isCancelled, true);
    await show();
    obsolete.reply.complete({'servers': [{'name': 'obsolete'}]});
    client.inventories.last.reply.completeError(StateError('unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('obsolete'), findsNothing);
    expect(find.text('Unable to load MCP status. Retry'), findsOneWidget);
    await tester.tap(find.text('Unable to load MCP status. Retry'));
    await tester.pumpAndSettle();
    client.inventories.last.reply.complete({'servers': []});
    await tester.pumpAndSettle();
    expect(find.text('No MCP servers configured'), findsOneWidget);
    client.events.add({'type': 'mcp.config.reloaded', 'data': {}});
    await tester.pumpAndSettle();
    final refresh = client.inventories.last;
    refresh.reply.complete({'servers': [{'name': 'external', 'enabled': false, 'state': 'disabled', 'tool_count': 0, 'auth_status': 'unsupported'}]});
    await tester.pumpAndSettle();
    expect(find.text('external'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '@ma');
    await tester.pump(const Duration(milliseconds: 210));
    expect(find.text('external'), findsNothing);
    client.searches.single.reply.complete({'paths': ['lib/main.dart'], 'truncated': false});
    await tester.pumpAndSettle();
    expect(find.text('lib/main.dart'), findsOneWidget);
    await show();
    client.inventories.last.reply.complete({'servers': [{'name': 'external', 'enabled': false, 'state': 'disabled', 'tool_count': 0, 'auth_status': 'unsupported'}]});
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ordinary message with no matching server');
    await tester.pumpAndSettle();
    expect(find.text('external'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'ordinary message with no matching server');
    await show();
    final departing = client.inventories.last;
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    expect(departing.cancellation.isCancelled, true);
    departing.reply.complete({'servers': [{'name': 'departed'}]});
    await tester.pumpAndSettle();
    expect(find.text('departed'), findsNothing);
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('expanded tool details survive switching away from the task and back', (tester) async {
    session.task!.events.addAll({
      1: {'seq': 1, 'type': 'tool.started', 'data': {'call_id': 'cell', 'namespace': 'functions', 'name': 'exec', 'input': 'text(await tools.exec_command({cmd: "pwd"}));'}},
      2: {'seq': 2, 'type': 'host_tool.started', 'data': {'id': 'shell', 'parent_call_id': 'cell', 'name': 'exec_command', 'arguments': {'cmd': 'pwd'}}},
      3: {'seq': 3, 'type': 'host_tool.completed', 'data': {'id': 'shell', 'output': {'output': '/project'}}},
    });
    await open(tester);
    await tester.tap(find.text('functions.exec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code & output'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('text(await tools.exec_command({cmd: "pwd"}));'), findsOneWidget);
    await tester.tap(find.text('exec_command'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('/project'), findsOneWidget);
    final task = session.task!;
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    await tester.runAsync(() => session.select(session.project!, task));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Enter sends and Shift Enter inserts a newline', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'First line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'First line\n');
    expect(client.sent, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['prompt'], 'First line\n');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a pending paste cannot enter another task after switching drafts', (tester) async {
    final first = session.task!, project = session.project!;
    final second = DesktopTask('second', 'Second task')..loaded = true;
    project.tasks.add(second);
    final clipboard = Completer<Object?>();
    const channel = MethodChannel('happen/clipboard');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) => clipboard.future);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Same draft');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.runAsync(() => session.select(project, second));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Same draft');
    clipboard.complete({'text': 'Late paste', 'images': [], 'files': []});
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Same draft');
    expect(session.drafts[first.id], 'Same draft');
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('image paste retains the draft after rejection and sends with file attachments on retry', (tester) async {
    late File image, report;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('happen-paste-');
      final owned = await Directory('${directory!.path}/clipboard-image').create();
      image = await File('${owned.path}/Pasted image.png').writeAsBytes(base64Decode(_png));
      report = await File('${directory!.path}/report.txt').writeAsString('File contents');
    });
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('happen/clipboard');
    String? text;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => call.method == 'Clipboard.getData' && text != null ? {'text': text} : null);
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'read' ? {
      'text': text,
      'images': text == null ? [{'name': 'Pasted image.png', 'path': image.path}] : [],
      'files': text == null ? [report.path] : [],
    } : null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Inspect these');
    Future<void> paste() async {
      await tester.tap(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
    await paste();
    expect(find.byTooltip('Remove Pasted image.png'), findsOneWidget);
    expect(find.byTooltip('Remove report.txt'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Inspect these');
    client.rejectSend = true;
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fixture rejection'), findsOneWidget);
    expect(find.byTooltip('Remove Pasted image.png'), findsOneWidget);
    expect(session.drafts['task'], 'Inspect these');
    client.rejectSend = false;
    await tester.tap(find.byTooltip('Send message'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    client.events.add({'task_id': 'task', 'type': 'turn.completed', 'data': {}});
    await tester.pumpAndSettle();
    expect(client.sent.last['attachments'], [
      {'type': 'image', 'name': 'Pasted image.png', 'path': image.path},
      {'type': 'file', 'name': 'report.txt', 'path': report.path},
    ]);
    expect(find.byTooltip('Remove Pasted image.png'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.runAsync(() async {
      expect(await image.exists(), isFalse);
      expect(await report.readAsString(), 'File contents');
    });
    text = 'Ordinary paste';
    await paste();
    expect(session.error, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Ordinary paste');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('native drag and drop stages images and files before the source is released', (tester) async {
    late File image, report;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('happen-drop-');
      image = await File('${directory!.path}/drop.png').writeAsBytes(base64Decode(_png));
      report = await File('${directory!.path}/drop.txt').writeAsString('Dropped contents');
    });
    await open(tester);
    final point = tester.getCenter(find.byType(TextField));
    final event = <String, Object?>{
      'view': tester.view.viewId, 'generation': 0, 'session': 7, 'request': 1, 'phase': 1,
      'operation': 1, 'x': point.dx, 'y': point.dy,
      'offer': {'allowedOperations': ['copy'], 'isComplete': true, 'strings': [], 'files': [
        {'name': 'drop.png', 'path': image.path}, {'name': 'drop.txt', 'path': report.path},
      ]},
    };
    final native = NativeTransport.instance;
    final target = await native.onEvent!(MethodCall('query', event)) as Map;
    expect(target['target'], greaterThan(0));
    await tester.runAsync(() => native.onEvent!(MethodCall('drop', {...event, 'target': target['target']})));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove drop.png'), findsOneWidget);
    expect(find.byTooltip('Remove drop.txt'), findsOneWidget);
    await tester.runAsync(() => directory!.delete(recursive: true));
    directory = null;
    final attachments = session.attachmentDrafts['task']!;
    await tester.runAsync(() async {
      expect(await File(attachments.first.path).readAsBytes(), base64Decode(_png));
      expect(await File(attachments.last.path).readAsString(), 'Dropped contents');
    });
    await tester.tap(find.byTooltip('Remove drop.png'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove drop.png'), findsNothing);
    expect(find.byTooltip('Remove drop.txt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('one model and reasoning menu combines both providers and preserves existing-task restrictions', (tester) async {
    (session.providers.first['models'] as List).first['reasoning_levels'] = ['low', 'high'];
    (session.providers.first['models'] as List).add({'id': 'gpt-6-astra', 'default_reasoning': 'low', 'reasoning_levels': ['low', 'high']});
    session.providers.last['models'] = [
      {'id': 'deepseek-v4.1-flash-free', 'default_reasoning': 'high', 'reasoning_levels': ['off', 'low', 'high', 'max']},
    ];
    client.providers = [...session.providers,
      {'id': 'deepseek', 'name': 'DeepSeek API', 'auth': 'api_key', 'status': 'api_key',
        'models': [{'id': 'deepseek-flash'}]},
    ];
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('desktop-model-picker-');
      final database = await openDesktopDatabase(directory!.path);
      final project = session.project!;
      await callIsolate(database.port, 'project.add', {
        'checkout_key': project.checkoutKey, 'identity': project.id, 'path': project.path,
      });
      final previous = session, providers = client.providers;
      await previous.close();
      client = _Client()..providers = providers;
      session = DesktopSession(client, database)
        ..providers = previous.providers
        ..projects.addAll(previous.projects)
        ..project = project
        ..task = previous.task;
    });
    session.task!.reasoningUpdates = true;
    final existing = session.task!;
    session.task = null;
    await session.refreshProviders();
    expect(session.providers.map((p) => p['id']), ['openai', 'opencode']);
    expect(session.models.map((m) => m['id']), isNot(contains('deepseek-flash')));
    await open(tester);
    final menu = find.byTooltip('Model and reasoning effort');
    Finder item(String label) => find.ancestor(of: find.text(label), matching: find.byType(PopupMenuItem<String>));
    Future<void> frame() async { await tester.pump(); await tester.pump(const Duration(milliseconds: 300)); }
    expect(menu, findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.enterText(find.byType(TextField), 'Keep new draft');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('MODEL'), findsOneWidget);
    expect(find.text('REASONING EFFORT'), findsOneWidget);
    expect(find.text('gpt-6.1-sol'), findsOneWidget);
    expect(find.text('deepseek-v4.1-flash-free'), findsOneWidget);
    await tester.tap(item('deepseek-v4.1-flash-free'));
    await tester.pumpAndSettle();
    expect(session.providerId, 'opencode');
    expect(session.modelId, 'deepseek-v4.1-flash-free');
    expect(session.reasoning, 'high');
    expect(session.authenticated, false);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Max'), findsOneWidget);
    expect(find.text('gpt-6.1-sol'), findsOneWidget);
    expect(tester.widget<PopupMenuItem<String>>(item('gpt-6-astra')).enabled, true);
    await tester.tap(item('Max'));
    await tester.pumpAndSettle();
    expect(session.reasoning, 'max');
    await session.refreshProviders();
    expect(session.providerId, 'opencode');
    expect(session.reasoning, 'max');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(item('gpt-6-astra'));
    await tester.pumpAndSettle();
    expect(session.providerId, 'openai');
    expect(session.modelId, 'gpt-6-astra');
    expect(session.reasoning, 'low');
    expect(session.authenticated, true);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep new draft');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(item('High'));
    await tester.pumpAndSettle();
    expect(session.reasoning, 'high');
    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    expect(session.modelId, 'gpt-6.1-sol');
    client.events.add({'task_id': 'task', 'type': 'turn.started', 'data': {}});
    await frame();
    await tester.tap(menu);
    await frame();
    expect(tester.widget<PopupMenuItem<String>>(item('gpt-6-astra')).enabled, false);
    expect(tester.widget<PopupMenuItem<String>>(item('deepseek-v4.1-flash-free')).enabled, false);
    expect(find.text('Start a new task to change models.'), findsOneWidget);
    expect(tester.widget<PopupMenuItem<String>>(item('High')).enabled, true);
    await tester.tap(item('High'));
    await frame();
    expect(session.reasoning, 'high');
    await tester.enterText(find.byType(TextField), 'Use more reasoning');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['reasoning'], 'high');
    expect(client.sent.single['delivery'], 'steer');

    session.task!.reasoningUpdates = false;
    client.events.add({'task_id': 'task', 'type': 'model.completed', 'data': {}});
    await tester.pump();
    await tester.tap(menu);
    await frame();
    expect(tester.widget<PopupMenuItem<String>>(item('Light')).enabled, false);
    expect(find.text('Reasoning effort is fixed for this task.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frame();
    session.chooseReasoning('low');
    expect(session.reasoning, 'high');
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(session.database.port, 'load', {}));
      final project = jsonDecode(saved['settings']['project_models'] as String)['checkout'];
      expect((project['provider'], project['model'], project['reasoning']), ('openai', 'gpt-6.1-sol', 'high'));
    });
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('skills complete dollar, slash and at queries with inline atoms and survive draft navigation and send', (tester) async {
    final existing = session.task!;
    session.task = null;
    client.deferSkills = true;
    await open(tester);
    final originalRect = tester.getRect(find.byType(TextField));
    await tester.enterText(find.byType(TextField), r'Use $da');
    await tester.pump(const Duration(milliseconds: 199));
    expect(client.skillSearches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(client.skillSearches.single.cwd, '/project');
    expect(client.skillSearches.single.query, 'da');
    expect(client.searches, isEmpty);
    client.skillSearches.single.reply.complete({'skills': [
      {'name': 'dart', 'path': '/skills/dart/SKILL.md', 'description': 'Dart and Flutter', 'scope': 'user'},
      {'name': 'data-tools', 'path': '/project/.agents/skills/data/SKILL.md', 'description': 'Work with data', 'scope': 'repo'},
    ], 'truncated': false});
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(TextField)), originalRect);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final draft = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(draft.text, 'Use \uFFFC ');
    expect(draft.serializePrompt(), r'Use [$data-tools](/project/.agents/skills/data/SKILL.md) ');
    expect(draft.files.single.skillName, 'data-tools');
    expect(find.byType(SkillIcon), findsOneWidget);
    expect(find.text('data-tools'), findsOneWidget);
    expect(session.fileDrafts['checkout']!.single.skillName, 'data-tools');
    expect(client.sent, isEmpty);

    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/dar');
    await tester.pump(const Duration(milliseconds: 200));
    client.skillSearches.last.reply.complete({'skills': [
      {'name': 'dart', 'path': '/skills/dart/SKILL.md', 'description': 'Dart and Flutter', 'scope': 'user'},
    ], 'truncated': false});
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(controller.serializePrompt(), r'[$dart](/skills/dart/SKILL.md) ');
    expect(client.sent, isEmpty, reason: 'Choosing a slash skill inserts it without sending');
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    expect((tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController).serializePrompt(),
      r'Use [$data-tools](/project/.agents/skills/data/SKILL.md) ');
    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Use @da');
    await tester.pump(const Duration(milliseconds: 200));
    client.searches.last.reply.complete({'paths': ['lib/data.dart'], 'truncated': false});
    client.skillSearches.last.reply.complete({'skills': [
      {'name': 'dart', 'path': '/skills/dart/SKILL.md', 'description': 'Dart and Flutter', 'scope': 'user'},
    ], 'truncated': false});
    await tester.pumpAndSettle();
    expect(find.text('lib/data.dart'), findsOneWidget);
    await tester.tap(find.text('dart'));
    await tester.pumpAndSettle();
    expect((tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController).serializePrompt(),
      r'Use [$dart](/skills/dart/SKILL.md) ');
    expect(client.sent, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['prompt'], r'Use [$dart](/skills/dart/SKILL.md) ');
    expect(session.fileDrafts[existing.id], isNull);
    expect(client.sent, hasLength(1));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('skill queries ignore code, currency and IME and cancel obsolete replies, blur and navigation', (tester) async {
    client.deferSkills = true;
    await open(tester);
    for (final text in [r'Price $123.45', r'`$dart`', '```\n/dart', r'word$dart']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(client.skillSearches, isEmpty);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: r'$da',
      selection: TextSelection.collapsed(offset: 3), composing: TextRange(start: 0, end: 3)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.skillSearches, isEmpty);
    await tester.enterText(find.byType(TextField), r'$da');
    await tester.pump(const Duration(milliseconds: 200));
    final old = client.skillSearches.single;
    await tester.enterText(find.byType(TextField), r'$dart');
    await tester.pump(const Duration(milliseconds: 200));
    expect(old.cancellation.isCancelled, true);
    final pending = client.skillSearches.last;
    old.reply.complete({'skills': [
      {'name': 'obsolete', 'path': '/old/SKILL.md', 'description': 'Old', 'scope': 'user'},
    ], 'truncated': false});
    await tester.pump();
    expect(find.text('obsolete'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(pending.cancellation.isCancelled, true);
    pending.reply.complete({'skills': [], 'truncated': false});
    await tester.enterText(find.byType(TextField), '/da');
    await tester.pump(const Duration(milliseconds: 200));
    final command = client.skillSearches.last;
    await tester.enterText(find.byType(TextField), 'plain text');
    await tester.pump();
    expect(command.cancellation.isCancelled, true);
    command.reply.complete({'skills': [], 'truncated': false});
    await tester.enterText(find.byType(TextField), r'$blur');
    await tester.pump(const Duration(milliseconds: 200));
    final blurred = client.skillSearches.last;
    tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
    await tester.pumpAndSettle();
    expect(blurred.cancellation.isCancelled, true);
    blurred.reply.complete({'skills': [], 'truncated': false});
    await tester.enterText(find.byType(TextField), r'$deploy');
    await tester.pump(const Duration(milliseconds: 200));
    final navigating = client.skillSearches.last;
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    expect(navigating.cancellation.isCancelled, true);
    navigating.reply.complete({'skills': [], 'truncated': false});
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('file mentions complete new and existing drafts without sending or damaging surrounding text', (tester) async {
    final existing = session.task!;
    session.task = null;
    await open(tester);
    final newDraftRect = tester.getRect(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Please @m');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'Please @ma');
    await tester.pump(const Duration(milliseconds: 199));
    expect(client.searches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(client.searches.single.cwd, '/project');
    expect(client.searches.single.query, 'ma');
    client.searches.single.reply.complete({'paths': ['lib/main.dart', 'notes/my file.md'], 'truncated': false});
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(TextField)), newDraftRect);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, isEmpty);
    final newDraft = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(newDraft.text, 'Please \uFFFC ');
    expect(newDraft.serializePrompt(), 'Please [my file.md](notes/my file.md) ');
    expect(find.text('my file.md'), findsOneWidget);
    expect(session.drafts['checkout'], newDraft.text);
    expect(session.fileDrafts['checkout']!.single.path, 'notes/my file.md');

    await tester.enterText(find.byType(TextField), 'Use @desktop');
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.searches.last.query, 'desktop');
    client.searches.last.reply.complete({'paths': ['packages/desktop/'], 'truncated': false});
    await tester.pumpAndSettle();
    expect(find.text('packages/desktop/'), findsOneWidget);
    expect(find.descendant(
      of: find.ancestor(of: find.text('packages/desktop/'), matching: find.byType(InkWell)),
      matching: find.byIcon(Icons.folder_outlined),
    ), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(newDraft.text, 'Use \uFFFC ');
    expect(newDraft.serializePrompt(), 'Use [desktop](packages/desktop/) ');
    expect(find.text('desktop'), findsOneWidget);
    expect(session.drafts['checkout'], newDraft.text);
    expect(client.sent, isEmpty);

    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Inspect @mainZZ afterwards');
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    controller.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.searches.last.query, 'main');
    client.searches.last.reply.complete({'paths': ['lib/main.dart'], 'truncated': false});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(controller.text, 'Inspect \uFFFC afterwards');
    expect(controller.serializePrompt(), 'Inspect [main.dart](lib/main.dart) afterwards');
    expect(controller.selection.baseOffset, 'Inspect \uFFFC '.length);
    expect(session.drafts[existing.id], controller.text);
    expect(client.sent, isEmpty);
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    final restoredNew = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(restoredNew.serializePrompt(), 'Use [desktop](packages/desktop/) ');
    expect(find.text('desktop'), findsOneWidget);
    await tester.runAsync(() => session.select(session.project!, existing));
    await tester.pumpAndSettle();
    final restored = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(restored.serializePrompt(), 'Inspect [main.dart](lib/main.dart) afterwards');
    client.rejectSend = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent.single['task_id'], existing.id);
    expect(client.sent.single['prompt'], 'Inspect [main.dart](lib/main.dart) afterwards');
    expect(restored.files.single.path, 'lib/main.dart');
    expect(session.fileDrafts[existing.id]!.single.path, 'lib/main.dart');
    client.rejectSend = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, hasLength(2));
    expect(restored.text, isEmpty);
    expect(session.fileDrafts[existing.id], isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('autocomplete never moves the composer, transcript viewport or reading position', (tester) async {
    for (var i = 1; i <= 30; i++) {
      session.task!.events[i] = {'seq': i, 'type': 'input.committed', 'data': {
        'item': {'role': 'user', 'content': [{'type': 'text', 'text': List.filled(8, 'Conversation message $i.').join('\n')}]},
      }};
    }
    await open(tester);
    final transcript = find.byType(ConversationTranscript);
    await tester.drag(transcript, const Offset(0, 240));
    await tester.pumpAndSettle();
    final scrolling = tester.state<ScrollableState>(find.descendant(
      of: transcript, matching: find.byType(Scrollable),
    ).first);
    final editorRect = tester.getRect(find.byType(TextField));
    final transcriptRect = tester.getRect(transcript);
    final readingPosition = scrolling.position.pixels;
    expect(readingPosition, greaterThan(0));
    void expectStable() {
      expect(tester.getRect(find.byType(TextField)), editorRect);
      expect(tester.getRect(transcript), transcriptRect);
      expect(scrolling.position.pixels, readingPosition);
      expect(tester.takeException(), isNull);
    }

    for (final count in [1, 20, 0]) {
      await tester.enterText(find.byType(TextField), '@query$count');
      await tester.pump(const Duration(milliseconds: 100));
      expectStable();
      await tester.pump(const Duration(milliseconds: 100));
      expectStable();
      client.searches.last.reply.complete({
        'paths': List.generate(count, (i) => i == 0 ? 'packages/desktop/' : 'lib/result$i.dart'),
        'truncated': count == 20,
      });
      await tester.pumpAndSettle();
      expectStable();
      if (count > 0) {
        expect(tester.getBottomLeft(find.text('packages/desktop/')).dy, lessThan(editorRect.top));
      }
    }
    await tester.enterText(find.byType(TextField), '@failure');
    await tester.pump(const Duration(milliseconds: 200));
    client.searches.last.reply.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('File search unavailable. Retry'), findsOneWidget);
    expectStable();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('File search unavailable. Retry'), findsNothing);
    expectStable();
    expect(client.sent, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('file chips copy and cut as paths and keep identities through undo', (tester) async {
    String? clipboard;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Compare @first');
    await tester.pump(const Duration(milliseconds: 200));
    client.searches.last.reply.complete({'paths': ['lib/first.dart'], 'truncated': false});
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 600));
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    final original = controller.serializePrompt();
    controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(clipboard, original);
    controller.selection = const TextSelection(baseOffset: 8, extentOffset: 9);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(const Duration(milliseconds: 600));
    expect(clipboard, '[first.dart](lib/first.dart)');
    expect(controller.files, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.serializePrompt(), original);
    expect(controller.files.single.path, 'lib/first.dart');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.files, isEmpty);
    expect(controller.serializePrompt(), 'Compare  ');
    expect(client.sent, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('file suggestions reject late replies, dismiss, and leave email and IME input alone', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '@a');
    await tester.pump(const Duration(milliseconds: 200));
    final old = client.searches.single;
    await tester.enterText(find.byType(TextField), '@ab');
    await tester.pump(const Duration(milliseconds: 200));
    expect(old.cancellation.isCancelled, true);
    client.searches.last.reply.complete({'paths': ['current.dart'], 'truncated': false});
    await tester.pump();
    old.reply.complete({'paths': ['obsolete.dart'], 'truncated': false});
    await tester.pump();
    expect(find.text('current.dart'), findsOneWidget);
    expect(find.text('obsolete.dart'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('current.dart'), findsNothing);
    await tester.enterText(find.byType(TextField), 'email@example.com');
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.searches, hasLength(2));
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '@im', selection: TextSelection.collapsed(offset: 3), composing: TextRange(start: 0, end: 3),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.searches, hasLength(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, isEmpty);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '@im', selection: TextSelection.collapsed(offset: 3)));
    await tester.pump(const Duration(milliseconds: 200));
    final pending = client.searches.last;
    expect(pending.query, 'im');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.sent, isEmpty, reason: 'Enter must not send while a suggestion is still loading');
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    expect(pending.cancellation.isCancelled, true);
    pending.reply.complete({'paths': ['old-task.dart'], 'truncated': false});
    await tester.pump();
    expect(find.text('old-task.dart'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('file search recovers from failure, accepts taps and cancels on disconnect', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '@"my f');
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.searches.single.query, 'my f');
    client.searches.single.reply.completeError(StateError('connection lost'));
    await tester.pump();
    await tester.tap(find.text('File search unavailable. Retry'));
    await tester.pump();
    client.searches.last.reply.complete({'paths': ['notes/my file.md'], 'truncated': false});
    await tester.pump();
    await tester.tap(find.text('notes/my file.md'));
    await tester.pump();
    final controller = tester.widget<TextField>(find.byType(TextField)).controller! as ComposerTextController;
    expect(controller.text, '\uFFFC ');
    expect(controller.serializePrompt(), '[my file.md](notes/my file.md) ');
    expect(client.sent, isEmpty);
    await tester.enterText(find.byType(TextField), '@pending');
    await tester.pump(const Duration(milliseconds: 200));
    final pending = client.searches.last;
    await tester.runAsync(() => client.events.close());
    await tester.pump();
    expect(pending.cancellation.isCancelled, true);
    pending.reply.complete({'paths': ['disconnected.dart'], 'truncated': false});
    await tester.pump();
    expect(find.text('disconnected.dart'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Settings lists archived tasks, opens their history, and restores them', (tester) async {
    final archived = DesktopTask('archived', 'Old conversation')..archived = true..loaded = true;
    session.project!.tasks.add(archived);
    late Directory root;
    late IsolateOwner database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('desktop-settings-');
      directory = root;
      database = await openDesktopDatabase(root.path);
      await callIsolate(database.port, 'project.add', {'checkout_key': 'checkout', 'identity': '/project', 'path': '/project'});
      await callIsolate(database.port, 'task.add', {'id': archived.id, 'checkout_key': 'checkout', 'title': archived.title});
      await callIsolate(database.port, 'task.archive', {'task_id': archived.id, 'archived': true});
      final previous = session;
      await previous.close();
      client = _Client();
      session = DesktopSession(client, database)
        ..providers = previous.providers
        ..projects.addAll(previous.projects)
        ..project = previous.project
        ..task = previous.task;
    });
    await open(tester);
    expect(find.text('Old conversation'), findsNothing);
    expect(find.text('Archived'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Keep my draft');
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Default provider'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.text('DeepSeek API'), findsNothing);
    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('account:opencode')), matching: find.text('OpenCode')), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('On stop'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('On stop'));
      await callIsolate(database.port, 'load', {});
    });
    await tester.pumpAndSettle();
    expect(session.dictationMode, 'on_stop');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep my draft');
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Sign in to OpenCode'), findsOneWidget);
    expect(find.text('Steer'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    final row = find.byKey(const ValueKey('archived:archived'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(find.text('Archived tasks (1)'), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Old conversation')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('project')), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(session.task, same(archived));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Restore task to continue'), findsOneWidget);
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.descendant(of: row, matching: find.text('Restore')));
      await Future<void>.delayed(Duration.zero);
      await callIsolate(database.port, 'load', {});
    });
    await tester.pumpAndSettle();
    expect(client.restored, [archived.id]);
    expect(find.text('Archived tasks (0)'), findsOneWidget);
    expect(find.text('No archived tasks.'), findsOneWidget);
    expect(archived.archived, isFalse);
    await tester.runAsync(() async {
      final saved = jsonObject(await callIsolate(database.port, 'load', {}));
      expect((saved['tasks'] as List).single['archived'], 0);
    });
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('projects:archived')),
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive task'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await callIsolate(database.port, 'load', {});
    });
    for (var attempt = 0; archived.archiving && attempt < 100; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Task archived'), findsOneWidget, reason: 'archived=${archived.archived}, archiving=${archived.archiving}, error=${session.error}');
    expect(find.text('Old conversation'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Task archived'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

class _Client implements AgentClient {
  @override bool get sharedFilesystem => true;
  @override final events = StreamController<Json>.broadcast();
  final sent = <Json>[];
  final restored = <String>[];
  final cancelled = <String>[];
  List<Json> providers = [];
  final searches = <({String cwd, String query, CancellationToken cancellation, Completer<Json> reply})>[];
  final skillSearches = <({String cwd, String query, CancellationToken cancellation, Completer<Json> reply})>[];
  bool deferSkills = false;
  @override Future<Json> searchSkills(String cwd, String query, {required CancellationToken cancellation}) {
    if (!deferSkills) return Future.value({'skills': [], 'truncated': false});
    final reply = Completer<Json>();
    skillSearches.add((cwd: cwd, query: query, cancellation: cancellation, reply: reply));
    return reply.future;
  }
  final inventories = <({bool verbose, CancellationToken cancellation, Completer<Json> reply})>[];
  @override Future<Json> mcpInventory({bool verbose = false, String? server, required CancellationToken cancellation}) {
    final reply = Completer<Json>();
    inventories.add((verbose: verbose, cancellation: cancellation, reply: reply));
    return reply.future;
  }
  bool rejectSend = false;
  @override Future<Json> searchFiles(String cwd, String query, {required CancellationToken cancellation}) {
    final reply = Completer<Json>();
    searches.add((cwd: cwd, query: query, cancellation: cancellation, reply: reply));
    return reply.future;
  }
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'providers.list') return {'providers': providers, 'default_provider': 'openai'};
    if (method == 'task.cancel') {
      cancelled.add(params['task_id'] as String);
      return {};
    }
    if (method == 'task.unarchive' || method == 'task.archive') {
      if (method == 'task.unarchive') restored.add(params['task_id'] as String);
      return {'task_id': params['task_id'], 'archived': method == 'task.archive'};
    }
    if (method != 'task.send') throw StateError('Unexpected request: $method');
    sent.add(params);
    if (rejectSend) throw StateError('fixture rejection');
    return {'task_id': params['task_id']};
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

class _Database implements IsolateOwner {
  @override Future<void> close() async {}
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected database operation');
}
