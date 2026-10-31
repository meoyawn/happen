import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('composer skill search uses current server roots, metadata, ranking and bounds without a task', () async {
    final root = await Directory.systemTemp.createTemp('skill-search-');
    final work = await Directory('${root.path}/repo/sub').create(recursive: true);
    await File('${work.parent.path}/.git').writeAsString('gitdir: elsewhere');
    Future<File> skill(String relative, String name, {String description = 'Useful workflow', String? short}) async {
      final file = File('${root.path}/$relative/SKILL.md');
      await file.parent.create(recursive: true);
      await file.writeAsString('---\nname: $name\ndescription: $description\n'
        '${short == null ? '' : 'metadata:\n  short-description: $short\n'}---\nBODY_ONLY\n');
      return file;
    }
    final local = await skill('repo/.agents/skills/dart', 'dart', short: 'Flutter and Dart');
    final nested = await skill('repo/sub/.agents/skills/dart', 'dart');
    final global = await skill('home/.agents/skills/dart', 'dart');
    await skill('home/.agents/skills/dart-tools', 'dart-tools');
    await skill('repo/.agents/skills/dark', 'dark');
    final explicit = await skill('repo/.agents/skills/deploy', 'deploy');
    await Directory('${explicit.parent.path}/agents').create();
    await File('${explicit.parent.path}/agents/openai.yaml').writeAsString('policy:\n  allow_implicit_invocation: false\n');
    await skill('repo/.codex/skills/excluded', 'excluded');
    await skill('home/.claude/skills/excluded', 'excluded');
    final invalid = File('${work.parent.path}/.agents/skills/invalid/SKILL.md');
    await invalid.parent.create(recursive: true);
    await invalid.writeAsString('not a skill');
    final server = await AgentServer.start(directory: '${root.path}/data', configPath: '${root.path}/config.yaml',
      skillsHome: '${root.path}/home', port: 0);
    final client = await AgentClient.connect(server.uri);
    try {
      final matches = await client.searchSkills(work.path, 'DART', cancellation: CancellationToken());
      final rows = (matches['skills'] as List).map(jsonObject).toList();
      expect(rows.map((row) => row['name']), ['dart', 'dart', 'dart', 'dart-tools']);
      expect(rows.take(3).map((row) => row['path']), [
        await local.resolveSymbolicLinks(), await nested.resolveSymbolicLinks(), await global.resolveSymbolicLinks(),
      ]);
      expect(rows.first, containsPair('description', 'Flutter and Dart'));
      expect(rows.map((row) => row['scope']), ['repo', 'repo', 'user', 'user']);
      expect(jsonEncode(matches), isNot(contains('BODY_ONLY')));
      expect(jsonEncode(matches), isNot(contains('implicit')));
      expect(matches['truncated'], true, reason: 'Invalid siblings report incomplete discovery');
      await invalid.delete();
      expect((await client.searchSkills(work.path, 'dply', cancellation: CancellationToken()))['skills'],
        [containsPair('name', 'deploy')]);
      final all = await client.searchSkills(work.path, '', cancellation: CancellationToken());
      expect(all['truncated'], false);
      expect((all['skills'] as List), hasLength(6));
      expect(jsonEncode(all), isNot(contains('excluded')));
      // Discovery is fresh after filesystem edits, even without a model turn.
      await local.delete();
      expect(((await client.searchSkills(work.path, 'dart', cancellation: CancellationToken()))['skills'] as List), hasLength(3));
      for (final params in [
        {'cwd': '.', 'query': ''}, {'cwd': '${work.path}/missing', 'query': ''},
        {'cwd': work.path, 'query': 'a' * 257}, {'cwd': work.path, 'query': '\n'},
        {'cwd': work.path, 'query': '', 'limit': 0}, {'cwd': work.path, 'query': '', 'limit': 51},
      ]) {
        await expectLater(client.request('skills.search', params), throwsStateError);
      }
      for (var i = 0; i < 55; i++) {
        await skill('repo/.agents/skills/bulk-$i', 'bulk-$i', description: '界' * 1500);
      }
      final bounded = jsonObject(await client.request('skills.search', {'cwd': work.path, 'query': 'bulk', 'limit': 50}));
      expect(bounded['truncated'], true);
      expect((bounded['skills'] as List).length, inInclusiveRange(1, 49));
      expect(utf8.encode(jsonEncode(bounded)).length, lessThan(33 * 1024));
      expect(((bounded['skills'] as List).first['description'] as String).runes.length, 1024);
      final obsolete = client.request('skills.search', {'cwd': work.path, 'query': 'old'});
      final cancelled = expectLater(obsolete, throwsStateError);
      final latest = client.searchSkills(work.path, 'dart', cancellation: CancellationToken());
      expect((await latest)['skills'], hasLength(3));
      expect(jsonObject(await client.request('ping'))['version'], '0.1.0');
      await cancelled;
    } finally {
      await client.close();
      await server.close();
      await root.delete(recursive: true);
    }
  });

  test('skill cancellation is scoped on UDS and late replies leave files and other RPCs intact', () async {
    final root = await Directory.systemTemp.createTemp('skill-rpc-');
    final http = await HttpServer.bind(InternetAddress('${root.path}/s', type: InternetAddressType.unix), 0);
    final received = StreamController<Json>();
    final peer = Completer<WebSocket>();
    http.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      peer.complete(socket);
      socket.listen((raw) { if (!received.isClosed) received.add(jsonObject(jsonDecode(raw as String))); });
    });
    final requests = StreamIterator(received.stream);
    final client = await AgentClient.connect(Uri(scheme: 'unix', path: '${root.path}/s'));
    final token = CancellationToken(), other = CancellationToken();
    try {
      final socket = await peer.future;
      final files = client.searchFiles('/server/project', 'dart', cancellation: other);
      await requests.moveNext();
      final fileId = requests.current['id'];
      final old = client.searchSkills('/server/project', 'old', cancellation: token);
      final cancelled = expectLater(old, throwsA(isA<CancelledException>()));
      await requests.moveNext();
      final oldId = requests.current['id'];
      expect(requests.current['method'], 'skills.search');
      token.cancel();
      await cancelled;
      await requests.moveNext();
      expect(requests.current, {'method': 'skills.cancel', 'params': {'request_id': oldId}});
      final next = client.searchSkills('/server/project', 'new', cancellation: other);
      await requests.moveNext();
      final nextId = requests.current['id'];
      socket.add(jsonEncode({'id': nextId, 'result': {'skills': [], 'truncated': false}}));
      expect((await next)['skills'], isEmpty);
      socket.add(jsonEncode({'id': oldId, 'result': {'skills': [{'name': 'obsolete'}]}}));
      socket.add(jsonEncode({'id': fileId, 'result': {'paths': ['main.dart'], 'truncated': false}}));
      expect((await files)['paths'], ['main.dart']);
      expect(other.isCancelled, false);
      await socket.close();
    } finally {
      token.cancel();
      other.cancel();
      await client.close();
      await requests.cancel();
      await received.close();
      await http.close(force: true);
      await root.delete(recursive: true);
    }
  });
}
