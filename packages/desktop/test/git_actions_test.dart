import 'dart:async';
import 'dart:io';

import 'package:desktop/appearance.dart';
import 'package:desktop/app.dart';
import 'package:desktop/database.dart';
import 'package:desktop/git_actions_state.dart';
import 'package:desktop/project_actions_state.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('project details manages scripts, branches and commits through real services', (tester) async {
    tester.view.physicalSize = const Size(1440, 900); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root, repo;
    Future<String> git(List<String> args) async {
      final result = await Process.run('git', ['-c', 'core.hooksPath=/dev/null', ...args], workingDirectory: repo.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return (result.stdout as String).trim();
    }
    late AgentServer server;
    late AgentClient client;
    late GitActionsController controller;
    late DesktopSession session;
    late ProjectActionsController actions;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('git-controls-');
      repo = await Directory('${root.path}/repo').create();
      await git(['init', '--initial-branch=main']);
      await git(['config', 'user.name', 'Fixture']); await git(['config', 'user.email', 'fixture@example.invalid']);
      await File('${repo.path}/selected.txt').writeAsString('include this\n');
      await File('${repo.path}/excluded.txt').writeAsString('leave this\n');
      server = await AgentServer.startLocal(directory: '${root.path}/data',
        skillsHome: '${root.path}/data', configPath: '${root.path}/config.yaml', telemetry: false);
      client = AgentClient.local(server);
      session = DesktopSession(client, await openDesktopDatabase('${root.path}/desktop'));
      await session.addProject(repo.path);
      controller = session.gitForProject(session.project!);
      actions = session.actionsForProject(session.project!);
      await actions.load();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await session.close(); await server.close(); await root.delete(recursive: true);
      });
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('happen/desktop'), null));
    Future<void> until(bool Function(GitState) predicate) {
      if (predicate(controller.state)) return Future.value();
      final result = Completer<void>();
      void changed() {
        if (!predicate(controller.state)) return;
        controller.removeListener(changed);
        result.complete();
      }
      controller.addListener(changed);
      return result.future.timeout(const Duration(seconds: 10), onTimeout: () {
        controller.removeListener(changed);
        throw StateError('Git action did not settle: ${controller.state.runtimeType}');
      });
    }
    final phases = <Type>[];
    controller.addListener(() => phases.add(controller.state.runtimeType));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: DesktopView(session: session)));
      await until((state) => state is! GitLoading);
    });
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    final notice = find.byTooltip('Dismiss notification');
    if (notice.evaluate().isNotEmpty) {
      await tester.tap(notice);
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('project-details-card')), findsOneWidget);
    expect(find.text('main'), findsWidgets);
    expect(find.text('+2'), findsOneWidget);
    await tester.tap(find.text('Add project script'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Fixture script');
    await tester.enterText(find.byType(TextFormField).at(1), "printf 'script ran' > '../script.marker'");
    await tester.runAsync(() async {
      final saved = Completer<void>();
      void changed() {
        if (actions.state is ProjectActionsReady && actions.state.value.scripts.isNotEmpty && !saved.isCompleted) saved.complete();
      }
      actions.addListener(changed);
      try {
        await tester.tap(find.text('Save script'));
        await saved.future.timeout(const Duration(seconds: 10));
      } finally { actions.removeListener(changed); }
    });
    await tester.pumpAndSettle();
    expect(find.text('Fixture script'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Fixture script'));
      final shell = session.terminals.groups[(session.project!.checkoutKey, session.draftKey)]!.active!;
      final exited = Completer<void>();
      void changed() {
        if ((shell.exitCode != null || shell.error != null) && !exited.isCompleted) exited.complete();
      }
      shell.addListener(changed); changed();
      try { await exited.future.timeout(const Duration(seconds: 10)); }
      finally { shell.removeListener(changed); }
      expect(shell.error, isNull); expect(shell.exitCode, 0);
      expect(await File('${root.path}/script.marker').readAsString(), 'script ran');
      session.terminals.hide((session.project!.checkoutKey, session.draftKey));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final restored = ProjectActionsController(session.database, session.project!.checkoutKey, repo.path, local: true);
      try {
        await restored.load();
        expect(restored.state.value.scripts.single.command, "printf 'script ran' > '../script.marker'");
      } finally { await restored.close(); }
    });
    await tester.tap(find.byKey(const ValueKey('toggle-project-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-details-card')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toggle-project-details')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Changes'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Next file'));
      await tester.pump();
      // Wait for the real per-file read; later assertions check the rendered patch.
      await controller.diff('selected.txt', CancellationToken());
    });
    await tester.pumpAndSettle();
    expect(find.text('Working tree changes'), findsOneWidget);
    expect(find.text('include this'), findsWidgets);
    await tester.tap(find.byTooltip('Close changes'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await git(['add', 'selected.txt']);
      await tester.tap(find.text('Commit'));
      await until((state) => state is! GitLoading);
    });
    await tester.pumpAndSettle();
    expect(find.text('Include unstaged changes'), findsOneWidget);
    expect(find.text('Commit and push'), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), 'Save the staged file');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byType(Dialog), findsOneWidget, reason: 'Plain Enter in the message must not submit');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Commit'));
      await until((state) => state is! GitLoading);
    });
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Save the staged file');
    await tester.runAsync(() async {
      await tester.tap(find.text('Include unstaged changes'));
      await tester.pump();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (find.descendant(of: find.byType(Dialog), matching: find.byType(CircularProgressIndicator)).evaluate().isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) throw StateError('Staged changes did not load');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, false);
    await tester.runAsync(() async {
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.widgetWithText(TextButton, 'Commit')));
      await until((state) => state is GitCompleted || state is GitFailed);
    });
    await tester.pumpAndSettle();
    expect(controller.state, isA<GitCompleted>(),
      reason: controller.state is GitFailed ? (controller.state as GitFailed).message : null);
    expect(phases, containsAllInOrder([GitStarting, GitCommitting, GitRefreshing, GitCompleted]));
    await tester.runAsync(() async {
      expect(await git(['ls-tree', '--name-only', 'HEAD']), 'selected.txt');
      expect(await git(['log', '-1', '--format=%B']), 'Save the staged file');
      expect(controller.commitMessage, isEmpty);
    });
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Choose branch'));
      await tester.pump();
      await controller.branches(CancellationToken());
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'New branch name'), 'feature/details');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('Create branch'));
      await until((state) => state is GitCompleted && state.repository?.branch == 'feature/details' || state is GitFailed);
    });
    await tester.pumpAndSettle();
    expect(controller.state.repository!.branch, 'feature/details');
    expect(find.text('feature/details'), findsOneWidget);
    final remote = '${root.path}/remote.git';
    late File reject;
    await tester.runAsync(() async {
      await git(['init', '--bare', remote]); await git(['remote', 'add', 'origin', remote]);
      reject = await File('$remote/hooks/pre-receive').writeAsString('#!/bin/sh\nexit 1\n');
      final chmod = await Process.run('chmod', ['+x', reject.path]);
      expect(chmod.exitCode, 0);
      await controller.refresh(force: true);
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Commit & push'));
      await until((state) => state is! GitLoading);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Include unstaged changes'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), 'Publish remaining file');
    phases.clear();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Commit and push'));
      await until((state) => state is GitCompleted || state is GitFailed);
    });
    await tester.pumpAndSettle();
    expect(controller.state, isA<GitFailed>());
    final failed = controller.state as GitFailed;
    expect(phases, containsAllInOrder([GitStarting, GitCommitting, GitPushing, GitRefreshing, GitFailed]));
    await tester.runAsync(() async {
      expect(failed.commit!.sha, await git(['rev-parse', 'HEAD']));
      expect(await git(['log', '-1', '--format=%B']), 'Publish remaining file');
      await controller.refresh(force: true);
      expect(controller.state, isA<GitFailed>(), reason: 'Status polling must retain the failed push until acknowledgement or retry');
      expect((controller.state as GitFailed).commit, failed.commit);
      await reject.delete();
    });
    expect(find.text('Git action failed · View details'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Push'));
      await until((state) => state is GitCompleted || state is GitFailed);
    });
    await tester.pumpAndSettle();
    expect(controller.state, isA<GitCompleted>());
    expect(controller.state.repository!.upstream, 'origin/feature/details');
    await tester.runAsync(() async {
      final pushed = await Process.run('git', ['rev-parse', 'refs/heads/feature/details'], workingDirectory: remote);
      expect(pushed.exitCode, 0); expect('${pushed.stdout}'.trim(), failed.commit!.sha);
      expect(await git(['rev-parse', 'HEAD']), failed.commit!.sha, reason: 'Retrying push must reuse the committed changes');
    });
    expect(tester.takeException(), isNull);
  });
}
