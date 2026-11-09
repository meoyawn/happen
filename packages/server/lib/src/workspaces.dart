import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';
import 'git.dart';

Future<Json> inspectWorkspace(String path, CancellationToken cancellation) =>
  runIsolateEffect(_inspect, {'path': path}, cancellation: cancellation);

Future<Json> _inspect(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final path = requiredString(params, 'path');
  final home = Platform.environment['HOME'];
  final requested = path == '~' ? home ?? path : path.startsWith('~/') && home != null ? '$home/${path.substring(2)}' : path;
  final folder = Directory(requested);
  if (!folder.isAbsolute) throw ArgumentError('Provide an absolute project folder path');
  if (!await folder.exists()) return {'available': false};
  final canonical = await folder.resolveSymbolicLinks();
  cancellation.throwIfCancelled();
  return _checkout(canonical, cancellation);
}

Future<Json> _checkout(String path, CancellationToken cancellation) async {
  final result = await runGit(path, ['rev-parse', '--show-toplevel'], cancellation, accepted: {0, 128});
  var root = result.output.trim(), bare = false;
  if (result.code != 0) {
    final probe = await runGit(path, ['--git-dir=.', 'rev-parse', '--is-bare-repository'], cancellation, accepted: {0, 128});
    bare = probe.code == 0 && probe.output.trim() == 'true';
    if (!bare) return {'available': true, 'path': path, 'identity': path, 'repository': null,
      'repositoryRoot': null, 'subdirectory': '', 'branch': null, 'worktree': false, 'bare': false};
    root = path;
  }
  final explicit = [if (bare) '--git-dir=$root'];
  final values = await Future.wait([
    runGit(root, [...explicit, 'remote', '-v'], cancellation),
    runGit(root, [...explicit, 'symbolic-ref', '--quiet', '--short', 'HEAD'], cancellation, accepted: {0, 1, 128}),
    runGit(root, [...explicit, 'rev-parse', '--git-dir', '--git-common-dir'], cancellation),
  ]);
  final repository = primaryGitRepository(values[0].output);
  final relative = p.relative(path, from: root);
  final dirs = values[2].output.trim().split('\n');
  return {'available': true, 'path': path, 'identity': repository ?? path, 'repository': repository,
    'repositoryRoot': root, 'subdirectory': relative == '.' ? '' : relative,
    'branch': values[1].code == 0 ? values[1].output.trim() : null, 'bare': bare,
    'worktree': dirs.length == 2 && p.normalize(p.join(root, dirs[0])) != p.normalize(p.join(root, dirs[1]))};
}

/// T3 discovers projects from registered roots and agent-session cwd metadata,
/// then groups them by repository identity. It does not walk the whole disk.
Future<Json> discoverWorkspaces(List<String> paths, String? repository, String subdirectory,
  CancellationToken cancellation, {List<String> subdirectories = const []}) => runIsolateEffect(_discover,
    {'paths': paths, 'repository': repository, 'subdirectory': subdirectory,
      'subdirectories': subdirectories}, cancellation: cancellation);

Future<Json> _discover(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 45));
  final token = cancellation.merge(deadline);
  final paths = <String>{...(params['paths'] as List).cast<String>()};
  final registered = Set.of(paths);
  final repository = params['repository'] as String?, subdirectory = params['subdirectory'] as String;
  final subdirectories = (params['subdirectories'] as List? ?? []).cast<String>().toSet();
  if (subdirectories.length > 1000) throw ArgumentError('Too many project subdirectories');
  for (final relative in [subdirectory, ...subdirectories]) {
    if (p.isAbsolute(relative) || p.split(relative).contains('..')) throw ArgumentError('Invalid project subdirectory');
  }
  var truncated = false, inspected = 0;
  final results = <String, Json>{}, roots = <String>{}, seen = <String>{};
  final contained = <String>[];
  try {
    // Read only the session metadata prefix, never conversation contents.
    final home = Platform.environment['HOME'];
    final codex = Platform.environment['CODEX_HOME'] ?? (home == null ? null : '$home/.codex');
    if (codex != null) {
      final queue = [Directory('$codex/sessions')];
      var files = 0;
      while (queue.isNotEmpty && files < 5000) {
        token.throwIfCancelled();
        final directory = queue.removeLast();
        List<FileSystemEntity> entries;
        try { entries = await directory.list(followLinks: false).toList(); }
        on FileSystemException { continue; }
        entries.sort((a, b) => a.path.compareTo(b.path));
        for (final entry in entries) {
          token.throwIfCancelled();
          if (entry is Directory) { queue.add(entry); continue; }
          if (entry is! File || !entry.path.endsWith('.jsonl')) continue;
          if (++files > 5000) break;
          RandomAccessFile? file;
          try {
            file = await entry.open();
            final prefix = utf8.decode(await file.read(8192), allowMalformed: true);
            final line = prefix.split('\n').first;
            if (!RegExp(r'"type"\s*:\s*"session_meta"').hasMatch(line)) continue;
            // Headers can include long base instructions after cwd. Decode the
            // selected JSON string without requiring the rest of that record.
            final field = RegExp(r'"cwd"\s*:\s*("(?:\\.|[^"\\])*")').firstMatch(line);
            final cwd = field == null ? null : jsonDecode(field[1]!);
            if (cwd is String && p.isAbsolute(cwd)) paths.add(cwd);
          } on FileSystemException { /* Missing session metadata is disposable. */ }
          on FormatException { /* Incomplete or older headers are not candidates. */ }
          finally { await file?.close(); }
        }
      }
      truncated = files >= 5000;
    }
    Future<void> add(String candidate) async {
      token.throwIfCancelled();
      if (!seen.add(candidate) || !await Directory(candidate).exists()) return;
      final canonical = await Directory(candidate).resolveSymbolicLinks();
      if (canonical != candidate && !seen.add(canonical)) return;
      inspected++;
      final checkout = await _checkout(canonical, token);
      final root = checkout['repositoryRoot'] as String?;
      if (root != null) roots.add(root);
      // A configured workspace container is a catalog of its immediate Git
      // checkouts. Registered repository roots themselves are never traversed.
      if (root == null && registered.contains(candidate)) {
        await for (final child in Directory(canonical).list(followLinks: false)) {
          token.throwIfCancelled();
          if (child is! Directory) continue;
          final marker = await FileSystemEntity.type('${child.path}/.git', followLinks: false);
          if (marker == FileSystemEntityType.directory || marker == FileSystemEntityType.file ||
              await File('${child.path}/HEAD').exists() && await Directory('${child.path}/objects').exists()) {
            contained.add(child.path);
          }
        }
      }
      if (checkout['bare'] == true) return;
      if (repository != null && checkout['repository'] != repository) return;
      final path = root == null ? canonical : p.normalize(p.join(root, subdirectory));
      if (!await Directory(path).exists()) return;
      final resolved = await Directory(path).resolveSymbolicLinks();
      // Session cwd aliases never create duplicate choices for one physical path.
      final locations = <String, String>{};
      if (root != null) {
        for (final relative in {'', ...subdirectories}) {
          token.throwIfCancelled();
          final folder = Directory(p.join(root, relative));
          if (await folder.exists()) locations[relative] = await folder.resolveSymbolicLinks();
        }
      }
      results[resolved] = {...checkout, 'path': resolved, 'locations': locations};
    }
    final candidates = paths.toList();
    for (var index = 0; index < candidates.length && index < 5000; index++) {
      token.throwIfCancelled();
      try { await add(candidates[index]); }
      catch (_) { token.throwIfCancelled(); truncated = true; }
      candidates.addAll(contained);
      contained.clear();
    }
    truncated |= candidates.length > 5000;
    for (final root in roots.toList()) {
      token.throwIfCancelled();
      final checkout = await _checkout(root, token);
      if (repository != null && checkout['repository'] != repository) continue;
      final explicit = [if (checkout['bare'] == true) '--git-dir=$root'];
      var worktrees = await runGit(root, [...explicit, 'worktree', 'list', '--porcelain', '-z'], token, accepted: {0, 128, 129});
      if (worktrees.code != 0) {
        worktrees = await runGit(root, [...explicit, 'worktree', 'list', '--porcelain'], token);
      }
      final records = worktrees.output.contains('\x00') ? worktrees.output.split('\x00') : worktrees.output.split('\n');
      for (final record in records) {
        if (!record.startsWith('worktree ')) continue;
        final path = record.substring(9);
        try { await add(path); }
        on FileSystemException { /* Pruned and inaccessible worktrees are omitted. */ }
      }
    }
    return {'checkouts': results.values.toList()..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String)),
      'truncated': truncated, 'inspected': inspected};
  } catch (_) {
    if (!deadline.isCancelled) rethrow;
    cancellation.throwIfCancelled();
    return {'checkouts': results.values.toList(), 'truncated': true, 'inspected': inspected};
  } finally { deadline.cancel(); }
}
