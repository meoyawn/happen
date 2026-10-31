import 'dart:async';
import 'dart:io';

import 'package:desktop/composer_attachments.dart';
import 'package:desktop/composer_text_controller.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  late Directory root, work;
  late IsolateOwner database;
  late _Client client;
  DesktopSession? session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('desktop-projects-');
    root = Directory(await root.resolveSymbolicLinks());
    work = await Directory('${root.path}/work').create();
    database = await openDesktopDatabase(root.path);
    client = _Client();
  });
  tearDown(() async {
    if (session != null) {
      await session!.close();
    } else {
      await database.close();
      await client.close();
    }
    session = null;
    await root.delete(recursive: true);
  });

  Future<void> saveProject(String key, String path, [List<String> tasks = const []]) async {
    await callIsolate(database.port, 'project.add', {
      'checkout_key': key, 'identity': 'https://example.com/$key', 'path': path,
    });
    for (final id in tasks) {
      await callIsolate(database.port, 'task.add', {'id': id, 'checkout_key': key, 'title': id});
    }
  }

  Future<DesktopSession> open() async {
    final desktop = session = DesktopSession(client, database);
    await desktop.load();
    return desktop;
  }

  test('model and reasoning choices stay with each project across switches and relaunch', () async {
    var desktop = await open();
    await desktop.addProject(work.path);
    final first = desktop.project!;
    desktop.chooseModel('other-model');
    desktop.chooseReasoning('high');
    final other = await Directory('${root.path}/other').create();
    await desktop.addProject(other.path);
    expect((desktop.providerId, desktop.modelId, desktop.reasoning), ('openai', 'fixture', 'low'));
    desktop.chooseModel('free-model');
    desktop.chooseReasoning('max');
    await desktop.select(first);
    expect((desktop.providerId, desktop.modelId, desktop.reasoning), ('openai', 'other-model', 'high'));
    await desktop.select(desktop.projects.last);
    expect((desktop.providerId, desktop.modelId, desktop.reasoning), ('opencode', 'free-model', 'max'));
    expect(await desktop.send('Use project defaults'), true, reason: desktop.error);
    expect(client.started.single['provider'], 'opencode');
    expect(client.started.single['model'], 'free-model');
    expect(client.started.single['reasoning'], 'max');

    await desktop.close();
    session = null;
    database = await openDesktopDatabase(root.path);
    client = _Client();
    desktop = await open();
    expect((desktop.providerId, desktop.modelId, desktop.reasoning), ('openai', 'other-model', 'high'));
    await desktop.addProject(other.path);
    expect(desktop.projects, hasLength(2));
    expect((desktop.providerId, desktop.modelId, desktop.reasoning), ('opencode', 'free-model', 'max'));
    await desktop.removeProject(desktop.project!);
    expect((desktop.providerId, desktop.modelId, desktop.reasoning), ('openai', 'other-model', 'high'));
    await desktop.addProject(other.path);
    expect((desktop.providerId, desktop.modelId, desktop.reasoning), ('openai', 'fixture', 'low'));
  });

  test('only explicit task reasoning choices replace the project defaults', () async {
    var desktop = await open();
    await desktop.addProject(work.path);
    final project = desktop.project!;
    desktop.chooseModel('other-model');
    desktop.chooseReasoning('high');
    final existing = DesktopTask('existing', 'Existing task')
      ..loaded = true..provider = 'openai'..model = 'fixture'..reasoning = 'low'..reasoningUpdates = true;
    project.tasks.add(existing);
    await desktop.select(project, existing);
    desktop.chooseModel('free-model');
    expect((desktop.modelId, desktop.reasoning), ('fixture', 'low'));
    await desktop.select(project);
    expect((desktop.modelId, desktop.reasoning), ('other-model', 'high'));
    await desktop.select(project, existing);
    desktop.chooseReasoning('high');
    expect(existing.reasoning, 'low', reason: 'An unsent choice does not change committed task settings');
    expect(existing.nextReasoning, 'high');
    await desktop.select(project);
    expect((desktop.modelId, desktop.reasoning), ('fixture', 'high'));
    final fixed = DesktopTask('fixed', 'Fixed effort')
      ..loaded = true..provider = 'opencode'..model = 'free-model'..reasoning = 'max';
    project.tasks.add(fixed);
    await desktop.select(project, fixed);
    desktop.chooseReasoning('low');
    expect(desktop.reasoning, 'max');
    await desktop.select(project);
    expect((desktop.modelId, desktop.reasoning), ('fixture', 'high'));

    await desktop.close();
    session = null;
    database = await openDesktopDatabase(root.path);
    client = _Client();
    desktop = await open();
    expect((desktop.modelId, desktop.reasoning), ('fixture', 'high'));
  });

  test('catalog refresh falls back from unavailable choices without losing the saved selection', () async {
    final desktop = await open();
    await desktop.addProject(work.path);
    desktop.chooseModel('other-model');
    desktop.chooseReasoning('high');
    final models = client.providers.first['models'] as List;
    final selected = models.removeLast();
    await desktop.refreshProviders();
    expect((desktop.modelId, desktop.reasoning), ('fixture', 'low'));
    models.add(selected);
    await desktop.refreshProviders();
    expect((desktop.modelId, desktop.reasoning), ('other-model', 'high'));
    selected['reasoning_levels'] = ['medium'];
    await desktop.refreshProviders();
    expect((desktop.modelId, desktop.reasoning), ('other-model', 'medium'));
    selected['reasoning_levels'] = ['medium', 'high'];
    await desktop.refreshProviders();
    expect((desktop.modelId, desktop.reasoning), ('other-model', 'high'));
  });

  test('launch marks missing folders unavailable and retains their identity and tasks', () async {
    final missing = '${root.path}/missing';
    await saveProject('missing', missing, ['saved-task']);
    await saveProject('present', work.path);
    var desktop = await open();
    final project = desktop.projects.first;
    expect(project.available, false);
    expect(desktop.projects.last.available, true);
    expect(project.id, 'https://example.com/missing');
    expect(project.tasks.single.id, 'saved-task');
    expect(await desktop.send('New task'), false);
    desktop.task = project.tasks.single;
    expect(await desktop.send('Continue task'), false);

    await Directory(missing).create();
    await desktop.refreshProjects();
    expect(project.available, false, reason: 'App resume does not recheck availability');
    await desktop.close();
    session = null;
    database = await openDesktopDatabase(root.path);
    client = _Client();
    desktop = await open();
    expect(desktop.projects.first.available, true);
    expect(desktop.projects.first.tasks.single.id, 'saved-task');
  });

  test('opening a restored folder makes its existing project available', () async {
    final missing = '${root.path}/missing';
    await saveProject('missing', missing, ['saved-task']);
    final desktop = await open();
    expect(desktop.project!.available, false);
    await Directory(missing).create();
    await desktop.addProject(missing);
    expect(desktop.projects, hasLength(1));
    expect(desktop.project!.available, true);
    expect(desktop.project!.tasks.single.id, 'saved-task');
  });

  test('removal stops running tasks, clears references and drafts, and survives relaunch', () async {
    await saveProject('remove', work.path, ['running', 'archived']);
    await callIsolate(database.port, 'task.archive', {'task_id': 'archived', 'archived': true});
    await saveProject('missing', '${root.path}/missing');
    final other = await Directory('${root.path}/other').create();
    await saveProject('keep', other.path, ['other-task']);
    var desktop = await open();
    final project = desktop.project!;
    final running = project.tasks.singleWhere((task) => task.id == 'running')..running = true;
    desktop.task = running;
    final original = await File('${work.path}/keep.txt').writeAsString('Project files');
    final owned = await Directory('${root.path}/clipboard').create();
    final image = await File('${owned.path}/image.png').writeAsString('Draft image');
    for (final key in ['remove', 'running', 'archived', 'other-task']) {
      desktop.drafts[key] = 'Draft';
      desktop.fileDrafts[key] = [ComposerFileReference(0, original.path)];
    }
    desktop.attachmentDrafts['running'] = [ComposerAttachment(
      name: 'image.png', path: image.path, image: true, ownedDirectory: owned.path,
    )];
    client.stopping = Completer<void>();
    final removing = desktop.removeProject(project);
    expect(project.removing, true);
    expect(await desktop.send('No new work during removal'), false);
    await desktop.removeProject(project);
    expect(desktop.projects, contains(project));
    client.stopping!.complete();
    await removing;
    expect(client.cancelled, ['running']);
    expect(desktop.project!.checkoutKey, 'keep');
    expect(desktop.task, isNull);
    expect(desktop.drafts.keys, ['other-task']);
    expect(desktop.fileDrafts.keys, ['other-task']);
    expect(desktop.attachmentDrafts, isEmpty);
    expect(await owned.exists(), false);
    expect(await original.readAsString(), 'Project files');
    var saved = jsonObject(await callIsolate(database.port, 'load', {}));
    expect((saved['projects'] as List).map((p) => p['checkout_key']), ['missing', 'keep']);
    expect((saved['tasks'] as List).map((t) => t['id']), ['other-task']);

    await desktop.close();
    session = null;
    database = await openDesktopDatabase(root.path);
    client = _Client();
    desktop = await open();
    expect(desktop.projects.map((p) => p.checkoutKey), ['missing', 'keep']);
    final selected = desktop.projects.last;
    await desktop.select(selected);
    await desktop.removeProject(desktop.projects.first);
    expect(desktop.project, same(selected), reason: 'Removing another project preserves selection');
    await desktop.removeProject(selected);
    expect(desktop.project, isNull);
    expect(desktop.task, isNull);
    await desktop.addProject(work.path);
    expect(desktop.projects.single.tasks, isEmpty);
    expect(desktop.project!.checkoutKey, isNot('remove'));
    saved = jsonObject(await callIsolate(database.port, 'load', {}));
    expect(saved['projects'], hasLength(1));
    expect(saved['tasks'], isEmpty);
    expect(await original.exists(), true);
  });

  test('failed task cancellation leaves the project and its saved references intact', () async {
    await saveProject('remove', work.path, ['running']);
    final desktop = await open();
    final project = desktop.project!;
    desktop.task = project.tasks.single..running = true;
    client.rejectCancellation = true;
    await expectLater(desktop.removeProject(project), throwsStateError);
    expect(project.removing, false);
    expect(desktop.projects.single, same(project));
    expect(desktop.task, same(project.tasks.single));
    final saved = jsonObject(await callIsolate(database.port, 'load', {}));
    expect(saved['projects'], hasLength(1));
    expect(saved['tasks'], hasLength(1));
  });
}

class _Client implements AgentClient {
  @override final events = StreamController<Json>.broadcast();
  @override bool get sharedFilesystem => true;
  final cancelled = <String>[];
  Completer<void>? stopping;
  bool rejectCancellation = false;
  final started = <Json>[];
  final providers = <Json>[
    {'id': 'openai', 'status': 'signed_in', 'default_model': 'fixture', 'models': [
      {'id': 'fixture', 'default_reasoning': 'low', 'reasoning_levels': ['low', 'high']},
      {'id': 'other-model', 'default_reasoning': 'medium', 'reasoning_levels': ['medium', 'high']},
    ]},
    {'id': 'opencode', 'status': 'signed_in', 'default_model': 'free-model', 'models': [
      {'id': 'free-model', 'default_reasoning': 'high', 'reasoning_levels': ['off', 'low', 'high', 'max']},
    ]},
  ];

  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'providers.list') {
      return {'providers': providers};
    }
    if (method == 'task.start') {
      started.add(params);
      return {'task_id': 'task-${started.length}'};
    }
    if (method == 'task.cancel') {
      if (rejectCancellation) throw StateError('Could not stop task');
      cancelled.add(params['task_id'] as String);
      await stopping?.future;
      return null;
    }
    throw StateError('Unexpected request: $method');
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}
