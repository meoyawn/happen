// Ported from codex-rs/app-server/tests/suite/v2/fs.rs and
// exec-server/src/local_file_system_read_tests.rs. Exercise the wire boundary.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory home, root;
  late AgentServer server;
  late AgentClient client;

  Future<Json> rpc(String method, Json params) async => jsonObject(await client.request('fs/$method', params));
  Future<void> rejected(String method, Json params, String message) => expectLater(
    rpc(method, params), throwsA(isA<StateError>().having((error) => error.toString(), 'message', contains(message))));

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('happen-fs-');
    server = await AgentServer.start(directory: '${home.path}/server', port: 0,
      configPath: '${home.path}/config.yaml', skillsHome: home.path, telemetry: false);
    client = await AgentClient.connect(server.uri, sharedFilesystem: false);
  });
  setUp(() async { root = await Directory('${home.path}/${newId()}').create(); });
  tearDown(() => root.delete(recursive: true));
  tearDownAll(() async { await client.close(); await server.close(); await home.delete(recursive: true); });

  test('Codex metadata returns only used fields', () async {
    final path = '${root.path}/note.txt';
    await File(path).writeAsString('hello');
    final metadata = await rpc('getMetadata', {'path': path});
    expect(metadata.keys, unorderedEquals(['createdAtMs', 'modifiedAtMs', 'isDirectory', 'isFile', 'isSymlink']));
    expect(metadata['isDirectory'], false);
    expect(metadata['isFile'], true);
    expect(metadata['isSymlink'], false);
    expect(metadata['createdAtMs'], isNonNegative);
    expect(metadata['modifiedAtMs'], greaterThan(0));
  });

  test('Codex filesystem operations create, write, read, list, copy and remove', () async {
    final source = '${root.path}/source', nested = '$source/nested', copied = '${root.path}/copied';
    expect(await rpc('createDirectory', {'path': nested}), isEmpty);
    expect(await rpc('writeFile', {'path': '$nested/note.txt', 'dataBase64': base64Encode(utf8.encode('hello from app-server'))}), isEmpty);
    await rpc('writeFile', {'path': '$source/root.txt', 'dataBase64': base64Encode(utf8.encode('hello from source root'))});
    expect(await rpc('readFile', {'path': '$nested/note.txt'}), {'dataBase64': base64Encode(utf8.encode('hello from app-server'))});
    await rpc('copy', {'sourcePath': '$nested/note.txt', 'destinationPath': '${root.path}/copy.txt'});
    expect(await File('${root.path}/copy.txt').readAsString(), 'hello from app-server');
    await rpc('copy', {'sourcePath': source, 'destinationPath': copied, 'recursive': true});
    expect(await File('$copied/nested/note.txt').readAsString(), 'hello from app-server');
    expect((await rpc('readDirectory', {'path': source}))['entries'], unorderedEquals([
      {'fileName': 'nested', 'isDirectory': true, 'isFile': false},
      {'fileName': 'root.txt', 'isDirectory': false, 'isFile': true},
    ]));
    await rpc('remove', {'path': copied});
    expect(await Directory(copied).exists(), false);
    expect(await rpc('remove', {'path': copied}), isEmpty);
    await rejected('remove', {'path': copied, 'force': false}, 'unavailable');
  });

  test('Codex writes binary bytes and rejects invalid base64 without changing the file', () async {
    final path = '${root.path}/blob.bin', bytes = [0, 1, 2, 255];
    await rpc('writeFile', {'path': path, 'dataBase64': base64Encode(bytes)});
    expect(await File(path).readAsBytes(), bytes);
    expect((await rpc('readFile', {'path': path}))['dataBase64'], base64Encode(bytes));
    await rejected('writeFile', {'path': path, 'dataBase64': '%%%'}, 'fs/writeFile requires valid base64 dataBase64:');
    expect(await File(path).readAsBytes(), bytes);
    await rpc('writeFile', {'path': path, 'dataBase64': ''});
    expect(await File(path).length(), 0);
  });

  test('Codex filesystem methods reject relative paths', () async {
    final absolute = '${root.path}/absolute.txt';
    await File(absolute).writeAsString('hello');
    for (final (method, params) in <(String, Json)>[
      ('readFile', {'path': 'relative.txt'}),
      ('writeFile', {'path': 'relative.txt', 'dataBase64': 'aGVsbG8='}),
      ('createDirectory', {'path': 'relative-dir', 'recursive': null}),
      ('getMetadata', {'path': 'relative.txt'}),
      ('readDirectory', {'path': 'relative-dir'}),
      ('remove', {'path': 'relative.txt', 'recursive': null, 'force': null}),
      ('copy', {'sourcePath': 'relative.txt', 'destinationPath': absolute}),
      ('copy', {'sourcePath': absolute, 'destinationPath': 'relative-copy.txt'}),
      ('watch', {'watchId': 'relative', 'path': 'relative-path'}),
    ]) {
      await rejected(method, params, 'absolute');
    }
    expect(await File(absolute).readAsString(), 'hello');
  });

  test('Codex recursive options and copy descendant guards preserve the source', () async {
    final source = '${root.path}/source';
    await Directory('$source/nested').create(recursive: true);
    await File('$source/note.txt').writeAsString('keep');
    await rejected('copy', {'sourcePath': source, 'destinationPath': '${root.path}/copy'}, 'requires recursive: true');
    for (final target in [source, '$source/nested/copy']) {
      await rejected('copy', {'sourcePath': source, 'destinationPath': target, 'recursive': true}, 'itself or one of its descendants');
    }
    await rejected('remove', {'path': source, 'recursive': false}, '');
    await rejected('createDirectory', {'path': '${root.path}/missing/child', 'recursive': false}, '');
    expect(await File('$source/note.txt').readAsString(), 'keep');
    expect(await Directory('$source/nested/copy').exists(), false);
  });

  test('Codex metadata and directory listings follow links and omit dangling links', () async {
    await File('${root.path}/note.txt').writeAsString('hello');
    await Directory('${root.path}/notes').create();
    await File('${root.path}/notes/nested.txt').writeAsString('nested');
    await File('${root.path}/.hidden').writeAsString('hidden');
    for (final (name, target, directory) in [('note-link.txt', 'note.txt', false), ('notes-link', 'notes', true)]) {
      await Link('${root.path}/$name').create(target);
      final metadata = await rpc('getMetadata', {'path': '${root.path}/$name'});
      expect(metadata['isSymlink'], true);
      expect(metadata['isDirectory'], directory);
      expect(metadata['isFile'], !directory);
    }
    await Link('${root.path}/dangling-link').create('missing');
    final entries = (await rpc('readDirectory', {'path': root.path}))['entries'] as List;
    expect(entries.map((dynamic entry) => entry['fileName']), unorderedEquals([
      '.hidden', 'note.txt', 'notes', 'note-link.txt', 'notes-link',
    ]));
    expect(entries.singleWhere((dynamic entry) => entry['fileName'] == 'notes-link'),
      {'fileName': 'notes-link', 'isDirectory': true, 'isFile': false});
    expect((await rpc('readDirectory', {'path': '${root.path}/notes-link'}))['entries'], [
      {'fileName': 'nested.txt', 'isDirectory': false, 'isFile': true},
    ]);
    await rejected('getMetadata', {'path': '${root.path}/dangling-link'}, 'unavailable');
  }, skip: Platform.isWindows);

  test('Codex copies preserve symlinks and detect descendants through directory aliases', () async {
    final source = '${root.path}/source', copied = '${root.path}/copied';
    await Directory('$source/nested').create(recursive: true);
    await Link('$source/nested-link').create('nested');
    await Link('${root.path}/alias').create(source);
    await rejected('copy', {'sourcePath': source, 'destinationPath': '${root.path}/alias/copy', 'recursive': true}, 'itself or one of its descendants');
    await rpc('copy', {'sourcePath': source, 'destinationPath': copied, 'recursive': true});
    expect(await FileSystemEntity.type('$copied/nested-link', followLinks: false), FileSystemEntityType.link);
    expect(await Link('$copied/nested-link').target(), 'nested');
    await rpc('copy', {'sourcePath': '$source/nested-link', 'destinationPath': '${root.path}/link-copy'});
    expect(await Link('${root.path}/link-copy').target(), 'nested');
    await rpc('remove', {'path': '${root.path}/alias'});
    expect(await Directory(source).exists(), true);
  }, skip: Platform.isWindows);

  test('Codex recursive copies skip special files and standalone copies and reads reject them', () async {
    final source = '${root.path}/source', copied = '${root.path}/copied';
    await Directory(source).create();
    await File('$source/note.txt').writeAsString('hello');
    final pipe = await Process.run('mkfifo', ['$source/named-pipe']);
    expect(pipe.exitCode, 0, reason: '${pipe.stderr}');
    await rpc('copy', {'sourcePath': source, 'destinationPath': copied, 'recursive': true});
    expect(await File('$copied/note.txt').readAsString(), 'hello');
    expect(await FileSystemEntity.type('$copied/named-pipe'), FileSystemEntityType.notFound);
    await rejected('copy', {'sourcePath': '$source/named-pipe', 'destinationPath': '${root.path}/pipe-copy'}, 'only supports regular files, directories, and symlinks');
    await rejected('readFile', {'path': '$source/named-pipe'}, 'regular file');
  }, skip: Platform.isWindows);

  test('Codex reads span multiple chunks and reject oversize before allocation', () async {
    final path = '${root.path}/large.bin', bytes = Uint8List(4 * 1024 * 1024)..fillRange(0, 4 * 1024 * 1024, 0x5a);
    await File(path).writeAsBytes(bytes);
    expect(base64Decode((await rpc('readFile', {'path': path}))['dataBase64'] as String), bytes);
    final file = await File('${root.path}/oversize.bin').open(mode: FileMode.write);
    try { await file.truncate(32 * 1024 * 1024 + 1); } finally { await file.close(); }
    // Happen's 64 MB frame budget bounds the otherwise identical Codex read.
    await rejected('readFile', {'path': '${root.path}/oversize.bin'}, '32 MB');
  });

  test('Codex watches report direct paths, atomic replacements and missing targets, then unwatch', () async {
    final directory = await Directory('${root.path}/.git').create();
    final head = '${directory.path}/HEAD', missing = '${directory.path}/FETCH_HEAD';
    await File(head).writeAsString('main');
    final events = <Json>[];
    final subscription = client.events.stream.where((event) => event['method'] == 'fs/changed').listen(events.add);
    addTearDown(subscription.cancel);
    for (final (id, path) in [('git', directory.path), ('head', head), ('missing', missing)]) {
      expect((await rpc('watch', {'watchId': id, 'path': path}))['path'], path);
      addTearDown(() => rpc('unwatch', {'watchId': id}));
    }
    Future<void> replace(String path, String contents) async {
      await File('$path.lock').writeAsString(contents);
      await File('$path.lock').rename(path);
    }
    await replace(head, 'feature');
    await replace(missing, 'origin/main');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline) &&
        !['git', 'head', 'missing'].every((id) => events.any((event) => event['params']['watchId'] == id))) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(events.map((event) => event['params']['watchId']).toSet(), {'git', 'head', 'missing'});
    expect(events.firstWhere((event) => event['params']['watchId'] == 'head')['params']['changedPaths'], [head]);
    expect(events.firstWhere((event) => event['params']['watchId'] == 'missing')['params']['changedPaths'], [missing]);
    for (final id in ['git', 'head', 'missing']) { await rpc('unwatch', {'watchId': id}); }
    events.clear();
    await replace(head, 'after unwatch');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(events, isEmpty);
  });

  test('Codex watch IDs and unwatch are scoped to their owning connection', () async {
    final path = '${root.path}/HEAD';
    await File(path).writeAsString('main');
    final other = await AgentClient.connect(server.uri, sharedFilesystem: false);
    addTearDown(other.close);
    final events = <Json>[];
    final subscription = other.events.stream.where((event) => event['method'] == 'fs/changed').listen(events.add);
    addTearDown(subscription.cancel);
    await rpc('watch', {'watchId': 'head', 'path': path});
    await rejected('watch', {'watchId': 'head', 'path': path}, 'watchId already exists: head');
    await other.request('fs/watch', {'watchId': 'head', 'path': path});
    await rpc('unwatch', {'watchId': 'head'});
    await client.close();
    client = await AgentClient.connect(server.uri, sharedFilesystem: false);
    await File(path).writeAsString('feature');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (events.isEmpty && DateTime.now().isBefore(deadline)) { await Future<void>.delayed(const Duration(milliseconds: 20)); }
    expect(events.single['params'], {'watchId': 'head', 'changedPaths': [path]});
    await other.request('fs/unwatch', {'watchId': 'head'});
  });
}
