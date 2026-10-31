import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  test('file search uses server paths, Git ignores, fuzzy ranking and bounded replies', () async {
    final root = await Directory.systemTemp.createTemp('file-search-');
    final work = await Directory('${root.path}/work').create();
    final plain = await Directory('${root.path}/plain').create();
    Future<void> write(String path, [String text = 'contents stay on the server']) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    }
    Future<void> git(List<String> args) async {
      final result = await Process.run('git', ['-C', work.path, ...args]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
    }
    await git(['init', '--quiet']);
    await write('${work.path}/.gitignore', 'ignored/\n*.secret\n');
    for (final path in ['lib/main.dart', 'lib/main_test.dart', 'notes/my file.md', '.github/check.yml', 'ignored/private.txt', 'hidden.secret', 'readme.md', 'packages/desktop/lib/app.dart', 'docs/desktop-guide.md']) {
      await write('${work.path}/$path');
    }
    await git(['add', '.']);
    await write('${work.path}/lib/new.dart');
    await write('${plain.path}/docs/日本語.md');
    await Directory('${plain.path}/empty').create();
    await write('${plain.path}/node_modules/generated.js');
    await Link('${plain.path}/outside').create(work.path);
    final server = await AgentServer.start(directory: '${root.path}/data', configPath: '${root.path}/config.yaml', port: 0);
    final client = await AgentClient.connect(server.uri);
    try {
      Future<Json> search(String query, {int limit = 20, String? cwd}) async => jsonObject(
        await client.request('files.search', {'cwd': cwd ?? work.path, 'query': query, 'limit': limit}),
      );
      final all = await search('');
      expect(all['paths'], unorderedEquals(['.gitignore', '.github/', '.github/check.yml', 'lib/', 'lib/main.dart', 'lib/main_test.dart', 'lib/new.dart', 'notes/', 'notes/my file.md', 'readme.md', 'packages/', 'packages/desktop/', 'packages/desktop/lib/', 'packages/desktop/lib/app.dart', 'docs/', 'docs/desktop-guide.md']));
      expect(all['truncated'], false);
      expect(jsonEncode(all), isNot(contains('contents stay on the server')));
      expect((await search('MAIN'))['paths'], ['lib/main.dart', 'lib/main_test.dart']);
      expect(((await search('lmndrt'))['paths'] as List).first, 'lib/main.dart');
      expect((await search('my file'))['paths'], ['notes/my file.md']);
      expect(((await search('DESKTOP'))['paths'] as List).first, 'packages/desktop/');
      expect(((await search('./packages/desktop/'))['paths'] as List).first, 'packages/desktop/');
      expect(((await search('pkgsdsktp'))['paths'] as List).first, 'packages/desktop/');
      expect((await search('', limit: 1))['truncated'], true);
      expect((await search('', limit: 1))['paths'], hasLength(1));
      expect((await search('main', cwd: '${work.path}/lib'))['paths'], ['main.dart', 'main_test.dart']);
      await File('${work.path}/lib/main.dart').delete();
      expect((await search('main', limit: 1))['paths'], ['lib/main_test.dart']);
      expect((await search('', cwd: plain.path))['paths'], unorderedEquals(['docs/', 'docs/日本語.md', 'empty/']));
      for (final params in [
        {'cwd': work.path, 'query': 'x' * 257},
        {'cwd': work.path, 'query': '', 'limit': 51},
        {'cwd': work.path, 'query': '', 'limit': 0},
        {'cwd': '.', 'query': ''},
        {'cwd': '${work.path}/missing', 'query': ''},
      ]) {
        await expectLater(client.request('files.search', params), throwsStateError);
      }
      // Both requests arrive before the first directory lookup finishes. Only
      // the superseded search is cancelled; other RPCs keep their own IDs.
      final obsolete = client.request('files.search', {'cwd': work.path, 'query': 'old'});
      final cancelled = expectLater(obsolete, throwsStateError);
      final latest = search('new');
      final ping = client.request('ping');
      expect((await latest)['paths'], ['lib/new.dart']);
      expect(jsonObject(await ping)['version'], '0.1.0');
      await cancelled;
    } finally {
      await client.close();
      await server.close();
      await root.delete(recursive: true);
    }
  });

  test('UDS replies overlap, cancellation is scoped, and late search replies are ignored', () async {
    final root = await Directory.systemTemp.createTemp('file-rpc-');
    final http = await HttpServer.bind(InternetAddress('${root.path}/s', type: InternetAddressType.unix), 0);
    final received = StreamController<Json>();
    final peer = Completer<WebSocket>();
    http.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      peer.complete(socket);
      socket.listen((raw) {
        if (!received.isClosed) received.add(jsonObject(jsonDecode(raw as String)));
      });
    });
    final requests = StreamIterator(received.stream);
    final client = await AgentClient.connect(Uri(scheme: 'unix', path: '${root.path}/s'));
    final token = CancellationToken();
    final nextToken = CancellationToken();
    try {
      final socket = await peer.future;
      final ping = client.request('ping');
      expect(await requests.moveNext(), true);
      final pingId = requests.current['id'];
      final old = client.searchFiles('/server/project', 'old', cancellation: token);
      final cancelled = expectLater(old, throwsA(isA<CancelledException>()));
      expect(await requests.moveNext(), true);
      final oldId = requests.current['id'];
      token.cancel();
      await cancelled;
      expect(await requests.moveNext(), true);
      expect(requests.current, {'method': 'files.cancel', 'params': {'request_id': oldId}});
      final next = client.searchFiles('/server/project', 'new', cancellation: nextToken);
      expect(await requests.moveNext(), true);
      final nextId = requests.current['id'];
      expect({pingId, oldId, nextId}, hasLength(3));
      final event = client.events.stream.first;
      socket.add(jsonEncode({'event': {'type': 'text.delta', 'task_id': 'running', 'delta': 'still streaming'}}));
      socket.add(jsonEncode({'id': nextId, 'result': {'paths': ['new.dart'], 'truncated': false}}));
      expect((await next)['paths'], ['new.dart']);
      expect((await event)['delta'], 'still streaming');
      socket.add(jsonEncode({'id': oldId, 'result': {'paths': ['obsolete.dart']}}));
      socket.add(jsonEncode({'id': pingId, 'result': {'version': 'fixture'}}));
      expect(jsonObject(await ping)['version'], 'fixture');
      await client.close();
      await socket.close();
    } finally {
      token.cancel();
      nextToken.cancel();
      await client.close();
      await requests.cancel();
      await received.close();
      await http.close(force: true);
      await root.delete(recursive: true);
    }
  });
}
