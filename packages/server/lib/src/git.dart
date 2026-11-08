// Git subprocess and repository discovery follow codex-rs/git-utils, ddd1812a5.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';

typedef GitOutput = ({int code, String output, String error});

Future<GitOutput> runGit(String cwd, List<String> arguments, CancellationToken cancellation, {
  Map<String, String> environment = const {}, bool write = false,
  Set<int> accepted = const {0}, void Function(String)? onOutput,
}) => runIsolateEffect(_gitEffect, {'cwd': cwd, 'arguments': arguments,
    'environment': environment, 'write': write, 'accepted': accepted.toList(), 'progress': onOutput != null},
  cancellation: cancellation, onEvent: onOutput == null ? null : (event) => onOutput(event['output'] as String));

Future<GitOutput> _gitEffect(Json params, CancellationToken cancellation, void Function(Json) emit) =>
  _runGit(params['cwd'] as String, (params['arguments'] as List).cast<String>(), cancellation,
    environment: (params['environment'] as Map).cast<String, String>(), write: params['write'] == true,
    accepted: (params['accepted'] as List).cast<int>().toSet(),
    onOutput: params['progress'] == true ? (output) => emit({'output': output}) : null);

Future<GitOutput> _runGit(String cwd, List<String> arguments, CancellationToken cancellation, {
  Map<String, String> environment = const {}, bool write = false,
  Set<int> accepted = const {0}, void Function(String)? onOutput,
}) async {
  cancellation.throwIfCancelled();
  final deadline = TimeoutCancellationToken(Duration(seconds: write ? 120 : 5));
  final token = cancellation.merge(deadline);
  Process? process;
  CancellationHook? hook;
  final progress = Stopwatch()..start();
  var lastProgress = -100;
  try {
    final args = ['-c', 'safe.bareRepository=explicit',
      if (!write) ...['-c', 'core.hooksPath=${Platform.isWindows ? 'NUL' : '/dev/null'}',
        '-c', 'core.fsmonitor=false'],
      '--literal-pathspecs', ...arguments];
    final env = <String, String>{
      for (final entry in Platform.environment.entries)
        if (!{'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
          'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CONFIG_PARAMETERS',
          'GIT_CONFIG_COUNT'}.contains(entry.key) &&
          !entry.key.startsWith('GIT_CONFIG_KEY_') && !entry.key.startsWith('GIT_CONFIG_VALUE_'))
          entry.key: entry.value,
      'GIT_TERMINAL_PROMPT': '0', 'GCM_INTERACTIVE': 'never',
      if (!write) 'GIT_OPTIONAL_LOCKS': '0',
      ...environment,
    };
    // As in Codex's process-group guard, cancellation owns Git's hook/SSH children.
    process = await Process.start(Platform.isWindows ? 'git' : '/bin/bash',
      Platform.isWindows ? args : ['--noprofile', '--norc', '-c', _gitSupervisor, 'happen-git', 'git', ...args],
      workingDirectory: cwd, environment: env, includeParentEnvironment: false);
    final owned = process;
    hook = CancellationHook(token, () => owned.kill(Platform.isWindows ? ProcessSignal.sigkill : ProcessSignal.sigterm));
    Future<String> capture(Stream<List<int>> stream) async {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        if (bytes.length < maxFrameBytes ~/ 2) bytes.add(chunk.take(maxFrameBytes ~/ 2 - bytes.length).toList());
        if (onOutput != null && progress.elapsedMilliseconds - lastProgress >= 100) {
          final text = utf8.decode(chunk, allowMalformed: true).trim();
          if (text.isNotEmpty) {
            lastProgress = progress.elapsedMilliseconds;
            onOutput(clippedText(text, 2000));
          }
        }
      }
      return utf8.decode(bytes.takeBytes(), allowMalformed: true);
    }
    final output = capture(owned.stdout), errors = capture(owned.stderr);
    await owned.stdin.close();
    final code = await owned.exitCode;
    final result = (code: code, output: await output, error: await errors);
    cancellation.throwIfCancelled();
    if (deadline.isCancelled) throw StateError('Git ${arguments.first} timed out');
    if (!accepted.contains(code)) {
      throw StateError(result.error.trim().isEmpty ? 'Git ${arguments.first} failed (exit $code)' : clippedText(result.error.trim(), 12000));
    }
    return result;
  } finally {
    hook?.dispose();
    process?.kill();
    deadline.cancel();
  }
}

const _gitSupervisor = r'''
set -m
"$@" <&0 &
child=$!
trap 'trap - TERM INT HUP EXIT; kill -KILL -- -"$child" 2>/dev/null; wait "$child" 2>/dev/null' TERM INT HUP EXIT
wait "$child" 2>/dev/null
result=$?
exit "$result"
''';

Future<Json> gitStatus(String cwd, CancellationToken cancellation, {bool includeUnstaged = true}) async {
  final discovery = await runGit(cwd, ['rev-parse', '--show-toplevel'], cancellation, accepted: {0, 128});
  if (discovery.code == 128) return {'isRepo': false, 'host': Platform.localHostname, 'files': <Json>[]};
  final root = await Directory(discovery.output.trim()).resolveSymbolicLinks();
  final status = await runGit(root, ['status', '--porcelain=v2', '--branch', '-z', '--untracked-files=all'], cancellation);
  if (utf8.encode(status.output).length >= maxFrameBytes ~/ 2) throw StateError('Too many changed files to display');
  String? branch, head, upstream;
  var ahead = 0, behind = 0;
  final files = <Json>[];
  final records = status.output.split('\u0000');
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    if (record.startsWith('# branch.head ')) {
      final value = record.substring(14);
      branch = value == '(detached)' ? null : value;
    } else if (record.startsWith('# branch.oid ')) {
      final value = record.substring(13);
      head = value == '(initial)' ? null : value;
    } else if (record.startsWith('# branch.upstream ')) {
      upstream = record.substring(18);
    } else if (record.startsWith('# branch.ab ')) {
      final counts = record.substring(12).split(' ');
      ahead = int.parse(counts[0].substring(1)); behind = int.parse(counts[1].substring(1));
    } else if (record.startsWith('? ')) {
      files.add({'path': record.substring(2), 'status': '??'});
    } else if (record.startsWith('1 ') || record.startsWith('2 ') || record.startsWith('u ')) {
      final fields = record.split(' ');
      final rename = record.startsWith('2 ');
      files.add({'path': fields.skip(rename ? 9 : record.startsWith('u ') ? 10 : 8).join(' '),
        'status': fields[1], 'conflicted': record.startsWith('u '),
        if (rename) 'previousPath': records[++i]});
    }
  }
  if (!includeUnstaged) {
    files.removeWhere((file) => {'.', ' ', '?'}.contains((file['status'] as String)[0]));
  }
  final remotes = (await runGit(root, ['remote'], cancellation)).output.trim().split('\n').where((line) => line.isNotEmpty).toList();
  String? remote;
  if (branch != null) {
    final configured = await runGit(root, ['config', '--get', 'branch.$branch.pushRemote'], cancellation, accepted: {0, 1});
    final pushDefault = await runGit(root, ['config', '--get', 'remote.pushDefault'], cancellation, accepted: {0, 1});
    final tracking = await runGit(root, ['config', '--get', 'branch.$branch.remote'], cancellation, accepted: {0, 1});
    remote = [configured.output.trim(), pushDefault.output.trim(), tracking.output.trim(),
      if (remotes.contains('origin')) 'origin', if (remotes.length == 1) remotes.single]
      .where((name) => name.isNotEmpty && remotes.contains(name)).firstOrNull;
  }
  final counts = <String, (int, int, bool)>{};
  if (files.isNotEmpty && (head != null || !includeUnstaged)) {
    final diff = await runGit(root, ['diff', '--numstat', '-z', '--find-renames', '--no-ext-diff', '--no-textconv',
      if (!includeUnstaged) '--cached' else head!], cancellation);
    final entries = diff.output.split('\u0000');
    for (var index = 0; index < entries.length; index++) {
      final record = entries[index];
      final first = record.indexOf('\t'), second = record.indexOf('\t', record.indexOf('\t') + 1);
      if (first < 0 || second < 0) continue;
      final added = int.tryParse(record.substring(0, first)), removed = int.tryParse(record.substring(first + 1, second));
      var path = record.substring(second + 1);
      if (path.isEmpty && index + 2 < entries.length) { index += 2; path = entries[index]; }
      counts[path] = (added ?? 0, removed ?? 0, added == null);
    }
  }
  for (final file in files) {
    final path = requiredString(file, 'path');
    var count = counts[path] ?? (0, 0, false);
    if (file['previousPath'] case final String previous) {
      final old = counts[previous] ?? (0, 0, false);
      count = (count.$1 + old.$1, count.$2 + old.$2, count.$3 || old.$3);
    }
    if (includeUnstaged && (file['status'] == '??' || head == null)) count = await _newFileCount(p.join(root, path), cancellation);
    file.addAll({'additions': count.$1, 'deletions': count.$2, 'binary': count.$3});
  }
  return {'isRepo': true, 'host': Platform.localHostname, 'root': root, 'branch': branch, 'head': head, 'upstream': upstream,
    'remote': remote, 'ahead': ahead, 'behind': behind, 'files': files,
    'additions': files.fold<int>(0, (sum, file) => sum + (file['additions'] as int)),
    'deletions': files.fold<int>(0, (sum, file) => sum + (file['deletions'] as int))};
}

Future<(int, int, bool)> _newFileCount(String path, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  try {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return (0, 0, false);
    if (type == FileSystemEntityType.link) return (1, 0, false);
    if (type != FileSystemEntityType.file || await File(path).length() > maxFrameBytes ~/ 2) return (0, 0, true);
    var lines = 0, last = -1;
    await for (final bytes in File(path).openRead(0, maxFrameBytes ~/ 2)) {
      cancellation.throwIfCancelled();
      if (bytes.contains(0)) return (0, 0, true);
      lines += bytes.where((byte) => byte == 10).length;
      if (bytes.isNotEmpty) last = bytes.last;
    }
    return (lines + (last != -1 && last != 10 ? 1 : 0), 0, false);
  } on FileSystemException {
    // Files can disappear between status and the read.
    return (0, 0, false);
  }
}

Future<List<Json>> gitBranches(String root, CancellationToken cancellation) async {
  final output = await runGit(root, ['for-each-ref', '--sort=-committerdate',
    '--format=%(refname)%00%(symref)', 'refs/heads', 'refs/remotes'], cancellation);
  return [for (final line in const LineSplitter().convert(output.output))
    if (line.split('\u0000') case [final ref, ''])
      {'ref': ref, 'name': ref.replaceFirst(RegExp(r'^refs/(heads|remotes)/'), ''), 'remote': ref.startsWith('refs/remotes/')}];
}

Future<Json> gitFileDiff(Json status, String path, CancellationToken cancellation) async {
  final files = (status['files'] as List).map(jsonObject);
  final file = files.where((file) => file['path'] == path).firstOrNull;
  if (file == null) throw StateError('This file no longer has changes. Refresh the checkout');
  final root = requiredString(status, 'root');
  final untracked = file['status'] == '??' || status['head'] == null;
  final result = await runGit(root, ['diff', '--no-ext-diff', '--no-textconv', '--no-color', '--find-renames',
    if (untracked) ...['--no-index', '--', Platform.isWindows ? 'NUL' : '/dev/null', p.join(root, path)]
    else ...[status['head'] as String, '--', if (file['previousPath'] case final String previous) previous, path]],
    cancellation, accepted: {0, 1});
  final truncated = utf8.encode(result.output).length >= maxFrameBytes ~/ 2;
  return {...file, 'diff': result.output, 'truncated': truncated};
}

/// An isolated index previews exactly the selected working files, preserving the user's index.
Future<({String tree, String summary, String patch})> gitCommitContext(
  Json status, List<String> paths, String index, CancellationToken cancellation, {bool includeUnstaged = true}
) async {
  final root = requiredString(status, 'root');
  final env = {'GIT_INDEX_FILE': index};
  if (includeUnstaged) {
    await runGit(root, ['read-tree', if (status['head'] == null) '--empty' else status['head'] as String], cancellation, environment: env);
    await runGit(root, ['add', '--all', '--', ...paths], cancellation, environment: env);
  } else {
    final staged = (await runGit(root, ['write-tree'], cancellation)).output.trim();
    await runGit(root, ['read-tree', staged], cancellation, environment: env);
  }
  final changed = await runGit(root, ['diff', '--cached', '--quiet'], cancellation, environment: env, accepted: {0, 1});
  if (changed.code == 0) throw StateError('The selected files have no changes to commit');
  final tree = (await runGit(root, ['write-tree'], cancellation, environment: env)).output.trim();
  final summary = (await runGit(root, ['diff', '--cached', '--stat'], cancellation, environment: env)).output;
  final patch = (await runGit(root, ['diff', '--cached', '--no-ext-diff', '--no-textconv'], cancellation, environment: env)).output;
  return (tree: tree, summary: clippedText(summary, 8000), patch: clippedText(patch, 50000));
}

List<String> gitSelectedPaths(Json status, Object? selection) {
  final files = (status['files'] as List).map(jsonObject).toList();
  if (selection != null && (selection is! List || selection.any((path) => path is! String))) {
    throw const FormatException('filePaths must contain changed file paths');
  }
  final requested = selection == null ? files.map((file) => file['path'] as String).toSet()
    : (selection as List).cast<String>().toSet();
  if (requested.isEmpty || requested.any((path) => !files.any((file) => file['path'] == path))) {
    throw const FormatException('Select at least one changed file');
  }
  final paths = <String>{};
  for (final file in files.where((file) => requested.contains(file['path']))) {
    if (file['conflicted'] == true) throw StateError('Resolve merge conflicts before committing');
    paths.add(requiredString(file, 'path'));
    if (file['previousPath'] case final String previous) paths.add(previous);
  }
  for (final path in paths) {
    if (p.isAbsolute(path) || p.split(p.normalize(path)).contains('..') || path.contains('\u0000')) {
      throw const FormatException('Commit paths must stay within the repository');
    }
  }
  return paths.toList()..sort();
}
