import 'dart:async';
import 'dart:io';

import 'package:config/config.dart';
import 'package:desktop/appearance.dart';
import 'package:desktop/local_project_icons.dart';
import 'package:desktop/project_avatar.dart';
import 'package:desktop/project_icon.dart';
import 'package:desktop/project_icon_picker.dart';
import 'package:desktop/project_icon_state.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

typedef _Fixture = ({Directory root, DesktopSession local, DesktopSession remote,
  Project project, Project peer, Project unrelated, Project subdirectory, CancellationToken token});

Future<_Fixture> _open() async {
  final temporary = await Directory.systemTemp.createTemp('project-icons-');
  final root = Directory(await temporary.resolveSymbolicLinks());
  await Directory('${root.path}/.happen').create();
  await File('${root.path}/brand.svg').writeAsString(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24" fill="#ff6600"/></svg>');
  await File(projectConfigPath(root.path)).writeAsString('# Keep MCP settings\nmcp_servers: {}\nicon: brand.svg\n');
  final local = DesktopSession(_Client(true), _Database(), attachmentDirectory: '${root.path}/attachments');
  final remote = DesktopSession(_Client(false), local.database, sidebarOwner: local, machineAlias: 'remote',
    attachmentDirectory: '${root.path}/remote-attachments');
  const repository = 'https://github.com/example/work';
  final project = Project('local', repository, root.path)
    ..workspace = {'repository': repository, 'subdirectory': ''};
  final peer = Project('remote', repository, '/remote/work')
    ..workspace = {'repository': repository, 'subdirectory': ''};
  final unrelated = Project('unrelated', 'https://github.com/other/work', '/other/work')
    ..workspace = {'repository': 'https://github.com/other/work', 'subdirectory': ''};
  final subdirectory = Project('subdirectory', repository, '/remote/work/packages/app')
    ..workspace = {'repository': repository, 'subdirectory': 'packages/app'};
  local.projects.add(project); local.project = project;
  remote.projects.addAll([peer, unrelated, subdirectory]); remote.project = peer;
  void resolve() => local.resolveProjectIcons([local, remote]);
  local.sidebarChanges.addListener(resolve);
  resolve();
  local.watchProjectIcons();
  return (root: root, local: local, remote: remote, project: project, peer: peer,
    unrelated: unrelated, subdirectory: subdirectory, token: CancellationToken());
}

Future<void> _close(_Fixture fixture) async {
  fixture.token.cancel();
  await fixture.remote.close();
  await fixture.local.close();
  await fixture.root.delete(recursive: true);
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; !condition() && attempt < 150; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
  expect(tester.takeException(), isNull);
}

void main() {
  test('icon watching survives eleven minutes idle and stops on caller cancellation', () async {
    final root = await Directory.systemTemp.createTemp('icon-watch-lifetime-');
    await Directory('${root.path}/.happen').create();
    final file = File(projectConfigPath(root.path));
    await file.writeAsString('icon: {kind: emoji, emoji: "💻"}\n');
    final cancellation = CancellationToken(), clock = FakeAsync();
    final changes = StreamController<Json>(), updates = StreamIterator<Json>(changes.stream);
    // Only long caller-side deadlines use the fake clock; worker I/O and its
    // cancellation/cleanup continue on the real event loop.
    final zone = Zone.current.fork(specification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
      duration < const Duration(minutes: 10) ? parent.createTimer(zone, duration, callback)
        : clock.run((_) => Timer(duration, () => zone.run(callback)))));
    final watching = zone.run(() => watchLocalProjectIcons([root.path], cancellation: cancellation,
      onChange: (_, appearance) => changes.add(appearance))).catchError((Object error, StackTrace stack) {
        if (error is! CancelledException) changes.addError(error, stack);
      });
    Future<Json> next() async {
      expect(await updates.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      return updates.current;
    }
    try {
      expect((await next())['icon'], {'kind': 'emoji', 'emoji': '💻'});
      clock.elapse(const Duration(minutes: 11));
      await file.writeAsString('icon: {kind: emoji, emoji: "🚀"}\n');
      expect((await next())['icon'], {'kind': 'emoji', 'emoji': '🚀'});
    } finally {
      cancellation.cancel();
      await watching;
      await updates.cancel();
      await changes.close();
      await root.delete(recursive: true);
    }
  });

  testWidgets('local config changes update icons for the same project on every machine', (tester) async {
    final fixture = (await tester.runAsync(_open))!;
    addTearDown(() => tester.runAsync(() => _close(fixture)));
    await tester.pumpWidget(MaterialApp(home: Row(children: [
      for (final project in [fixture.project, fixture.peer, fixture.unrelated, fixture.subdirectory])
        ProjectAvatar(key: ValueKey(project.checkoutKey), project: project, size: 32),
    ])));
    await _until(tester, () => fixture.peer.icon is ProjectFileIcon);
    expect(find.byType(SvgPicture), findsNWidgets(2));
    expect(fixture.unrelated.icon, isNull);
    expect(fixture.subdirectory.icon, isNull);

    // This file is outside the project, exercising an arbitrary absolute PNG path.
    final png = File('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png').absolute.path;
    await tester.runAsync(() => saveProjectIcon(fixture.root.path, ProjectFileIcon(png), cancellation: fixture.token));
    await _until(tester, () => fixture.peer.icon is ProjectFileIcon && (fixture.peer.icon as ProjectFileIcon).path == png);
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.byType(Image), findsNWidgets(2));

    await tester.runAsync(() => saveProjectIcon(fixture.root.path, const ProjectFileIcon('missing.svg'), cancellation: fixture.token));
    await _until(tester, () => fixture.peer.iconState is ProjectIconFailed);
    expect(find.byType(Image), findsNWidgets(2), reason: 'A bad config edit retains the last usable icon on both machines');

    await tester.runAsync(() => saveProjectIcon(fixture.root.path, null, cancellation: fixture.token));
    await _until(tester, () => fixture.peer.icon == null && fixture.peer.iconState is ProjectIconReady);
    expect(fixture.project.icon, isNull);
    expect(find.byType(ProjectIconMark), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('picker saves icons, emoji, monograms and file paths to the local project YAML', (tester) async {
    final fixture = (await tester.runAsync(_open))!;
    addTearDown(() => tester.runAsync(() => _close(fixture)));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: Scaffold(body: Builder(builder: (context) =>
      TextButton(onPressed: () => unawaited(showDialog<void>(context: context,
        builder: (_) => ProjectIconPicker(session: fixture.remote, project: fixture.peer))), child: const Text('Choose icon'))))));
    await _until(tester, () => fixture.peer.icon is ProjectFileIcon);

    Future<void> open() async { await tester.tap(find.text('Choose icon')); await tester.pumpAndSettle(); }
    Future<Object?> save() async {
      await tester.runAsync(() => tester.tap(find.text('Save icon')));
      await _until(tester, () => find.byType(ProjectIconPicker).evaluate().isEmpty);
      return tester.runAsync<Object>(() async => parseConfig(
        await File(projectConfigPath(fixture.root.path)).readAsString(), partialMcp: true)['icon'] as Object);
    }
    await open();
    await tester.tap(find.text('Icons')); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'rocket'); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('rocket')); await tester.pump();
    expect(await save(), {'kind': 'lucide', 'name': 'rocket', 'color': 'blue'});

    await open();
    await tester.tap(find.text('Emoji')); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '👩🏽‍💻'); await tester.pump();
    expect(await save(), {'kind': 'emoji', 'emoji': '👩🏽‍💻'});

    await open();
    await tester.tap(find.text('Monogram')); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hp'); await tester.pump();
    await tester.tap(find.byTooltip('purple')); await tester.pump();
    expect(await save(), {'kind': 'monogram', 'text': 'HP', 'color': 'purple'});

    await open();
    tester.view.physicalSize = const Size(390, 800); await tester.pumpAndSettle();
    await tester.tap(find.text('File')); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('project-icon-path')), 'brand.svg');
    await tester.pump(const Duration(milliseconds: 300));
    await _until(tester, () => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save icon')).onPressed != null);
    expect(await save(), 'brand.svg');
    await tester.runAsync(() async {
      final source = await File(projectConfigPath(fixture.root.path)).readAsString();
      expect(source, contains('# Keep MCP settings'));
      expect(parseConfig(source, partialMcp: true)['mcp_servers'], isEmpty);
      expect(await File('${fixture.root.path}/brand.svg').exists(), isTrue);
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Client implements AgentClient {
  _Client(this.sharedFilesystem);
  @override final bool sharedFilesystem;
  @override final events = StreamController<Json>.broadcast();
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Icons must not use the server');
}
class _Database implements IsolateOwner {
  @override Future<void> close() async {}
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Icons must not use desktop preferences');
}
