import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, repo;
  late AgentServer server;
  late AgentClient client;
  late HttpServer provider;
  late CancellationToken lifetime;
  late Completer<void> arrived, release;
  final requests = <Json>[], progress = <String>[];
  late StreamSubscription<Json> events;
  var hold = false;
  Future<String> git(List<String> args, {String? cwd}) async {
    final result = await Process.run('git', ['-c', 'core.hooksPath=/dev/null', ...args], workingDirectory: cwd ?? repo.path);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trim();
  }
  Future<Json> status([String? cwd]) => client.gitRequest('git/status', {'cwd': cwd ?? repo.path}, cancellation: lifetime);
  Future<Json> run(String action, {String message = '', List<String>? files, CancellationToken? cancellation,
    bool includeUnstaged = true, String? newBranch, String? cwd}) =>
    client.gitRequest('git/run', {'cwd': cwd ?? repo.path, 'actionId': newId(), 'action': action,
      'commitMessage': message, 'filePaths': ?files, 'provider': 'openai', 'model': 'gpt-6.1-sol',
      'includeUnstaged': includeUnstaged, 'newBranch': ?newBranch},
      cancellation: cancellation ?? lifetime);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('git-actions-');
    addTearDown(() => root.delete(recursive: true));
    repo = await Directory('${root.path}/checkout').create();
    lifetime = CancellationToken(); requests.clear(); progress.clear(); hold = false;
    addTearDown(lifetime.cancel);
    arrived = Completer<void>(); release = Completer<void>();
    await git(['init', '--initial-branch=main']);
    await git(['config', 'user.name', 'Fixture']);
    await git(['config', 'user.email', 'fixture@example.invalid']);
    await File('${repo.path}/tracked.txt').writeAsString('before\n');
    await git(['add', '.']); await git(['commit', '-m', 'Initial fixture']);
    final data = await Directory('${root.path}/data').create();
    await File('${data.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture',
      'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => provider.close(force: true));
    provider.listen((request) async {
      requests.add(jsonObject(jsonDecode(await utf8.decoder.bind(request).join())));
      if (!arrived.isCompleted) arrived.complete();
      if (hold) await release.future;
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed',
        'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text',
          'text': '{"subject":"Update selected files","body":"Keep the change focused."}'}]}]}})}\n\n');
      try { await request.response.close(); } on IOException { /* Client cancellation closes the fixture response. */ }
    });
    server = await AgentServer.start(directory: data.path, port: 0, skillsHome: data.path, telemetry: false,
      configPath: '${data.path}/config.yaml', endpoint: 'http://127.0.0.1:${provider.port}/responses');
    addTearDown(server.close);
    client = await AgentClient.connect(server.uri);
    addTearDown(client.close);
    events = client.events.stream.listen((event) {
      if (event['method'] == 'git/progress') progress.add(event['params']['phase'] as String);
    });
    addTearDown(events.cancel);
    addTearDown(() { if (!release.isCompleted) release.complete(); });
  });

  test('status resolves subdirectories and linked worktrees, including spaced names and detached HEAD', () async {
    await Directory('${repo.path}/nested').create();
    await File('${repo.path}/name with spaces λ.txt').writeAsString('new\n');
    final value = await status('${repo.path}/nested');
    expect(value['root'], await repo.resolveSymbolicLinks());
    expect(value['branch'], 'main');
    expect((value['files'] as List).single['path'], 'name with spaces λ.txt');
    final linked = '${root.path}/linked';
    await git(['worktree', 'add', '--detach', linked, 'HEAD']);
    final worktree = await status(linked);
    expect(worktree['root'], await Directory(linked).resolveSymbolicLinks());
    expect(worktree['branch'], isNull); expect(worktree['head'], isNotNull);
    expect((await status(root.path))['isRepo'], false);
  });

  test('checkout counts and per-file diffs include staged, working and untracked changes without touching the index', () async {
    await File('${repo.path}/tracked.txt').writeAsString('staged\n');
    await git(['add', 'tracked.txt']);
    await File('${repo.path}/tracked.txt').writeAsString('working\nextra\n');
    await File('${repo.path}/literal[λ].txt').writeAsString('first\nlast');
    await File('${repo.path}/binary.dat').writeAsBytes([0, 1, 2]);
    final index = await git(['write-tree']), head = await git(['rev-parse', 'HEAD']);
    final value = await status();
    expect((value['additions'], value['deletions']), (4, 1));
    final files = (value['files'] as List).map(jsonObject).toList();
    expect(files.singleWhere((file) => file['path'] == 'binary.dat')['binary'], true);
    Future<Json> diff(String path) => client.gitRequest('git/diff', {'cwd': repo.path, 'path': path}, cancellation: lifetime);
    final tracked = await diff('tracked.txt');
    expect(tracked['diff'], contains('-before\n+working\n+extra'));
    expect(tracked['diff'], isNot(contains('+staged')));
    expect((await diff('literal[λ].txt'))['diff'], contains('+first\n+last'));
    expect((await diff('binary.dat'))['diff'], contains('Binary files'));
    await expectLater(diff('../outside'), throwsA(anything));
    expect(await git(['write-tree']), index); expect(await git(['rev-parse', 'HEAD']), head);

    await git(['reset', '--hard', 'HEAD']);
    await git(['mv', 'tracked.txt', 'renamed λ.txt']);
    final renamed = (await status())['files'] as List;
    final file = renamed.singleWhere((raw) => raw['path'] == 'renamed λ.txt');
    expect((file['additions'], file['deletions']), (0, 0), reason: 'A pure rename does not change lines');
    expect((await diff('renamed λ.txt'))['previousPath'], 'tracked.txt');
  });

  test('branch actions create, switch and track remotes while protecting conflicting working changes', () async {
    final remote = '${root.path}/remote.git';
    await git(['init', '--bare', remote]); await git(['remote', 'add', 'origin', remote]);
    await git(['push', 'origin', 'HEAD:review']);
    await git(['fetch', 'origin']);
    final branches = await client.gitRequest('git/branches', {'cwd': repo.path}, cancellation: lifetime);
    expect((branches['branches'] as List).map((raw) => raw['ref']), containsAll(['refs/heads/main', 'refs/remotes/origin/review']));
    Future<Json> branch(String action, String name) => client.gitRequest('git/run',
      {'cwd': repo.path, 'actionId': newId(), 'action': action, 'branch': name}, cancellation: lifetime);
    expect((await branch('switch', 'refs/remotes/origin/review'))['status'], 'completed');
    expect((await status())['upstream'], 'origin/review');
    expect((await branch('create_branch', 'feature/details'))['status'], 'completed');
    expect((await status())['branch'], 'feature/details');
    await File('${repo.path}/tracked.txt').writeAsString('feature version\n');
    await git(['add', '.']); await git(['commit', '-m', 'Feature version']);
    expect((await branch('switch', 'refs/heads/main'))['status'], 'completed');
    await File('${repo.path}/tracked.txt').writeAsString('keep my local work\n');
    expect((await branch('switch', 'refs/heads/feature/details'))['status'], 'failed');
    expect((await status())['branch'], 'main');
    expect(await File('${repo.path}/tracked.txt').readAsString(), 'keep my local work\n');
    expect((await branch('create_branch', '--discard-changes'))['status'], 'failed');
    expect((await status())['branch'], 'main');
  });

  test('generated commit and push on a new branch preserve excluded staged changes', () async {
    final remote = '${root.path}/remote.git';
    await git(['init', '--bare', remote]);
    await git(['remote', 'add', 'origin', remote]);
    await File('${repo.path}/tracked.txt').writeAsString('selected change\n');
    await Directory('${repo.path}/features').create();
    await File('${repo.path}/features/[new].txt').writeAsString('selected addition\n');
    await File('${repo.path}/features/n.txt').writeAsString('EXCLUDED_CONTENT\n');
    await git(['add', 'features/n.txt']);
    final original = await git(['rev-parse', 'HEAD']);
    final result = await run('commit_push', files: ['tracked.txt', 'features/[new].txt'], newBranch: 'feature/publish');
    expect(result['status'], 'completed', reason: '${result['message']}');
    final sha = await git(['rev-parse', 'HEAD']);
    expect(result['commit']['sha'], sha);
    expect(await git(['rev-parse', 'refs/heads/main']), original);
    expect(await git(['rev-parse', 'refs/heads/feature/publish'], cwd: remote), sha);
    expect(await git(['show', '--format=', '--name-only', 'HEAD']), 'features/[new].txt\ntracked.txt');
    expect(await git(['diff', '--cached', '--name-only']), 'features/n.txt');
    expect(await git(['log', '-1', '--format=%B']), 'Update selected files\n\nKeep the change focused.');
    expect(requests, hasLength(1));
    expect(requests.single['tool_choice'], 'none');
    expect(requests.single['tools'] as List? ?? const <Object?>[], isEmpty);
    final input = jsonEncode(requests.single['input']);
    expect(input, contains('selected change')); expect(input, isNot(contains('EXCLUDED_CONTENT')));
    expect(progress, containsAllInOrder(['generating', 'creating_branch', 'committing', 'pushing']));
    expect(jsonObject(await client.request('thread/list', {'cwd': repo.path}))['data'], isEmpty);
  });

  test('commit all preserves ignored files removed from the index through generation and push', () async {
    final generated = File('${repo.path}/web/api/client.dart');
    await generated.parent.create(recursive: true);
    await generated.writeAsString('GENERATED_CONTENT\n');
    await git(['add', 'web/api']); await git(['commit', '-m', 'Track generated client']);
    final remote = '${root.path}/remote.git';
    await git(['init', '--bare', remote]); await git(['remote', 'add', 'origin', remote]);
    await git(['rm', '-r', '--cached', 'web/api']);
    await File('${repo.path}/.gitignore').writeAsString('web/api/\n');
    await File('${repo.path}/web/api/ignored.dart').writeAsString('IGNORED_CONTENT\n');
    await File('${repo.path}/tracked.txt').writeAsString('working change\n');
    await File('${repo.path}/new.txt').writeAsString('new addition\n');
    final result = await run('commit_push');
    expect(result['status'], 'completed', reason: '${result['message']}');
    final sha = await git(['rev-parse', 'HEAD']);
    expect(result['commit']['sha'], sha);
    expect(await git(['rev-parse', 'refs/heads/main'], cwd: remote), sha);
    expect(await git(['ls-tree', '-r', '--name-only', 'HEAD']), '.gitignore\nnew.txt\ntracked.txt');
    expect(await git(['show', 'HEAD:tracked.txt']), 'working change');
    expect(await generated.readAsString(), 'GENERATED_CONTENT\n');
    expect((await status())['files'], isEmpty);
    final input = jsonEncode(requests.single['input']);
    expect(input, contains('-GENERATED_CONTENT'));
    expect(input, isNot(contains('+GENERATED_CONTENT')));
    expect(input, isNot(contains('IGNORED_CONTENT')));
  });

  for (final base in ['main', 'master']) {
    test('pull fast-forwards a worktree from remote $base and preserves local work on failure', () async {
      final remote = '${root.path}/upstream.git', writer = '${root.path}/writer', linked = '${root.path}/thread checkout';
      await git(['init', '--bare', '--initial-branch=$base', remote]);
      await git(['remote', 'add', 'upstream', remote]);
      await git(['remote', 'add', 'origin', '${root.path}/unavailable-fork.git']);
      await git(['push', 'upstream', 'HEAD:refs/heads/$base']);
      await git(['clone', remote, writer]);
      await git(['config', 'user.name', 'Fixture'], cwd: writer);
      await git(['config', 'user.email', 'fixture@example.invalid'], cwd: writer);
      await git(['worktree', 'add', '-b', 'new-thread', linked]);
      final original = await git(['rev-parse', 'HEAD']);
      await File('$linked/keep.txt').writeAsString('Unrelated local work\n');
      Future<String> publish(String contents) async {
        await File('$writer/tracked.txt').writeAsString(contents);
        await git(['commit', '-am', 'Update $base'], cwd: writer);
        await git(['push'], cwd: writer);
        return git(['rev-parse', 'HEAD'], cwd: writer);
      }
      final latest = await publish('Latest $base\n');
      final result = await run('pull', cwd: linked);
      expect(result['status'], 'completed', reason: '${result['message']}');
      expect(result['message'], 'Pulled');
      expect(await git(['rev-parse', 'HEAD'], cwd: linked), latest);
      expect(await git(['rev-parse', 'HEAD']), original, reason: 'Other worktrees keep their branch');
      expect(await File('$linked/keep.txt').readAsString(), 'Unrelated local work\n');
      expect((await status(linked))['branch'], 'new-thread');
      expect((await status(linked))['pullRemote'], 'upstream');
      expect((await status(linked))['pullBranch'], base);
      expect((await run('pull', cwd: linked))['message'], 'Already up to date');
      expect(progress, contains('pulling'));
      expect(requests, isEmpty, reason: 'Pull never starts a model or thread');

      await File('$linked/tracked.txt').writeAsString('Staged work\n');
      await git(['add', 'tracked.txt'], cwd: linked);
      await File('$linked/tracked.txt').writeAsString('Unstaged work\n');
      await git(['config', 'merge.autostash', 'true']);
      await git(['config', 'pull.autostash', 'true']);
      final index = await git(['write-tree'], cwd: linked);
      await publish('Another upstream update\n');
      expect((await run('pull', cwd: linked))['status'], 'failed');
      expect(await git(['rev-parse', 'HEAD'], cwd: linked), latest);
      expect(await git(['write-tree'], cwd: linked), index);
      expect(await File('$linked/tracked.txt').readAsString(), 'Unstaged work\n');
      expect(await File('$linked/keep.txt').readAsString(), 'Unrelated local work\n');
      expect(await git(['stash', 'list'], cwd: linked), isEmpty);

      await git(['reset', '--hard', 'HEAD'], cwd: linked);
      await File('$linked/feature.txt').writeAsString('Committed feature\n');
      await git(['add', 'feature.txt'], cwd: linked);
      await git(['commit', '-m', 'Feature work'], cwd: linked);
      final diverged = await git(['rev-parse', 'HEAD'], cwd: linked);
      expect((await run('pull', cwd: linked))['status'], 'failed');
      expect(await git(['rev-parse', 'HEAD'], cwd: linked), diverged);
      expect(await git(['status', '--porcelain'], cwd: linked), '?? keep.txt');
      await git(['checkout', '--detach'], cwd: linked);
      expect((await run('pull', cwd: linked))['message'], contains('Check out a branch'));
      expect(await git(['rev-parse', 'HEAD'], cwd: linked), diverged);
    });
  }

  test('cancelling a remote pull releases the repository lock across worktrees', () async {
    final linked = '${root.path}/linked';
    await git(['worktree', 'add', '-b', 'new-thread', linked]);
    final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => remote.close(force: true));
    final arrived = Completer<void>();
    remote.listen((request) { if (!arrived.isCompleted) arrived.complete(); });
    await git(['remote', 'add', 'origin', 'http://127.0.0.1:${remote.port}/repository.git']);
    final head = await git(['rev-parse', 'HEAD']);
    final token = CancellationToken();
    final operation = run('pull', cwd: linked, cancellation: token);
    final stopped = expectLater(operation, throwsA(isA<CancelledException>()));
    Future<Json> createBranch() => client.gitRequest('git/run', {'cwd': repo.path, 'actionId': newId(),
      'action': 'create_branch', 'branch': 'after-pull'}, cancellation: lifetime);
    await arrived.future.timeout(const Duration(seconds: 10));
    await expectLater(createBranch(), throwsA(isA<StateError>().having((error) => error.message,
      'message', contains('already running'))));
    token.cancel(); await stopped;
    // Cancellation reaches the worker asynchronously; wait for its owned Git
    // process to exit and release the shared worktree lock.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    Json? result;
    while (result == null) {
      try { result = await createBranch(); }
      on StateError catch (error) {
        if (!error.message.contains('already running') || DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    expect(result['status'], 'completed', reason: '${result['message']}');
    expect(await git(['rev-parse', 'HEAD'], cwd: linked), head);
  });

  test('staged-only totals, generation and commit preserve unstaged edits in the same file', () async {
    await File('${repo.path}/tracked.txt').writeAsString('STAGED_CONTENT\n');
    await git(['add', 'tracked.txt']);
    final stagedTree = await git(['write-tree']);
    await File('${repo.path}/tracked.txt').writeAsString('UNSTAGED_CONTENT\nextra\n');
    await File('${repo.path}/untracked.txt').writeAsString('UNTRACKED_CONTENT\n');
    final selected = await client.gitRequest('git/status', {'cwd': repo.path, 'includeUnstaged': false}, cancellation: lifetime);
    expect((selected['additions'], selected['deletions']), (1, 1));
    expect((selected['files'] as List).map((file) => file['path']), ['tracked.txt']);
    final result = await run('commit', includeUnstaged: false);
    expect(result['status'], 'completed', reason: '${result['message']}');
    expect(await git(['rev-parse', 'HEAD^{tree}']), stagedTree);
    expect(await git(['diff', '--cached', '--name-only']), isEmpty);
    expect(await File('${repo.path}/tracked.txt').readAsString(), 'UNSTAGED_CONTENT\nextra\n');
    expect(await File('${repo.path}/untracked.txt').readAsString(), 'UNTRACKED_CONTENT\n');
    final input = jsonEncode(requests.single['input']);
    expect(input, contains('STAGED_CONTENT'));
    expect(input, isNot(contains('UNSTAGED_CONTENT')));
    expect(input, isNot(contains('UNTRACKED_CONTENT')));
  });

  test('manual messages bypass generation and selected renames include both paths', () async {
    await git(['mv', 'tracked.txt', 'renamed.txt']);
    await File('${repo.path}/renamed.txt').writeAsString('renamed and edited\n');
    final value = await status();
    expect((value['files'] as List).single['previousPath'], 'tracked.txt');
    final result = await run('commit', message: 'Rename the fixture\n\nExplain the change.', files: ['renamed.txt']);
    expect(result['status'], 'completed', reason: '${result['message']}');
    expect(await git(['ls-tree', '--name-only', 'HEAD']), 'renamed.txt');
    expect(await git(['log', '-1', '--format=%B']), 'Rename the fixture\n\nExplain the change.');
    expect(requests, isEmpty);
  });

  test('push failure reports the completed commit and can retry push without another commit', () async {
    await git(['remote', 'add', 'origin', '${root.path}/missing.git']);
    await File('${repo.path}/tracked.txt').writeAsString('committed locally\n');
    final result = await run('commit_push', message: 'Save local changes');
    expect(result['status'], 'failed'); expect(result['commit'], isNotNull);
    final sha = await git(['rev-parse', 'HEAD']);
    expect(result['commit']['sha'], sha);
    final remote = '${root.path}/remote.git';
    await git(['init', '--bare', remote]); await git(['remote', 'set-url', 'origin', remote]);
    expect((await run('push'))['status'], 'completed');
    expect(await git(['rev-parse', 'HEAD']), sha);
    expect(await git(['rev-parse', 'refs/heads/main'], cwd: remote), sha);
    expect(requests, isEmpty);
  });

  test('real commit hooks run and failures leave the branch unchanged', () async {
    final head = await git(['rev-parse', 'HEAD']);
    final hook = File('${repo.path}/.git/hooks/pre-commit');
    await hook.writeAsString('#!/bin/sh\necho fixture-hook-refused >&2\nexit 1\n');
    expect((await Process.run('chmod', ['700', hook.path])).exitCode, 0);
    await File('${repo.path}/tracked.txt').writeAsString('pending hook approval\n');
    final result = await run('commit', message: 'Honor hooks');
    expect(result['status'], 'failed');
    expect(result['message'], contains('fixture-hook-refused'));
    expect(await git(['rev-parse', 'HEAD']), head);
    expect((await status())['files'], isNotEmpty);
  });

  test('cancelling generation and rejecting concurrent actions preserve workspace and index', () async {
    hold = true;
    final head = await git(['rev-parse', 'HEAD']);
    await File('${repo.path}/tracked.txt').writeAsString('still uncommitted\n');
    final token = CancellationToken();
    final operation = run('commit', cancellation: token);
    final cancelled = expectLater(operation, throwsA(isA<CancelledException>()));
    await arrived.future.timeout(const Duration(seconds: 10));
    await expectLater(run('commit', message: 'Concurrent action'), throwsA(isA<StateError>()));
    token.cancel(); await cancelled;
    release.complete();
    await client.close(); await server.close();
    expect(await git(['rev-parse', 'HEAD']), head);
    expect(await git(['diff', '--cached', '--name-only']), isEmpty);
    expect(await File('${repo.path}/tracked.txt').readAsString(), 'still uncommitted\n');
  });

  test('edits made during message generation require another review before committing', () async {
    hold = true;
    final head = await git(['rev-parse', 'HEAD']);
    await File('${repo.path}/tracked.txt').writeAsString('first change\n');
    final operation = run('commit');
    await arrived.future.timeout(const Duration(seconds: 10));
    await File('${repo.path}/tracked.txt').writeAsString('a later change\n');
    release.complete();
    final result = await operation;
    expect(result['status'], 'failed'); expect(result['message'], contains('changed'));
    expect(await git(['rev-parse', 'HEAD']), head);
    expect(await git(['diff', '--cached', '--name-only']), isEmpty);
  });
}
