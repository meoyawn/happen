import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';
import 'package:yaml/yaml.dart';

/// Local host skills from user and repository .agents/skills directories.
/// Uses Codex 67f0994's parser and bounded walk.
/// Catalogs contain metadata only. Bodies are read afresh when explicitly loaded.
class FilesystemSkills {
  FilesystemSkills({String? homeDirectory})
    : homeDirectory = homeDirectory ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  final String? homeDirectory;

  /// Composer metadata only; explicit selection also includes non-implicit skills.
  Future<Json> search(Json params, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    final cwd = requiredString(params, 'cwd');
    final query = params['query'];
    final limit = params['limit'] ?? 20;
    if (!p.isAbsolute(cwd) || cwd.contains('\x00')) {
      throw const FormatException('cwd must be an absolute directory');
    }
    if (query is! String || query.length > 256 || query.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('query must be a string of at most 256 characters');
    }
    if (limit is! int || limit < 1 || limit > 50) throw const FormatException('limit must be 1..50');
    if (!await Directory(cwd).exists()) throw const FileSystemException('Search directory is unavailable');
    final catalog = await this.catalog(cwd, cancellation);
    final needle = query.trim().toLowerCase();
    final matches = <({Json skill, int score, int order})>[];
    for (final raw in catalog['skills'] as List) {
      cancellation.throwIfCancelled();
      final skill = jsonObject(raw);
      final score = _matchSkill(skill['name'] as String, needle);
      if (score == null) continue;
      matches.add((skill: skill, score: score, order: matches.length));
    }
    matches.sort((a, b) {
      final score = b.score.compareTo(a.score);
      return score != 0 ? score : a.order.compareTo(b.order);
    });
    final skills = <Json>[];
    var bytes = 0, truncated = matches.length > limit || catalog['error_count'] != 0;
    for (final match in matches.take(limit)) {
      final skill = match.skill;
      final row = <String, Object?>{'name': skill['name'], 'path': skill['path'], 'scope': skill['scope'],
        'description': String.fromCharCodes((skill['short_description'] as String? ?? skill['description'] as String).runes.take(1024))};
      bytes += utf8.encode(jsonEncode(row)).length;
      if (bytes > 32 * 1024) { truncated = true; break; }
      skills.add(row);
    }
    cancellation.throwIfCancelled();
    return {'skills': skills, 'truncated': truncated};
  }

  Future<Json> catalog(String cwd, CancellationToken cancellation) async {
    final chain = <String>[];
    var cursor = p.normalize(p.absolute(cwd));
    var repository = false;
    while (true) {
      cancellation.throwIfCancelled();
      chain.add(cursor);
      final marker = await FileSystemEntity.type(p.join(cursor, '.git'));
      if (marker != FileSystemEntityType.notFound) { repository = true; break; }
      final parent = p.dirname(cursor);
      if (parent == cursor) break;
      cursor = parent;
    }
    final roots = <({String path, String scope})>[
      for (final directory in repository ? chain.reversed : [chain.first])
        (path: p.join(directory, '.agents', 'skills'), scope: 'repo'),
      if (homeDirectory != null) (path: p.join(homeDirectory!, '.agents', 'skills'), scope: 'user'),
    ];
    final skills = <Json>[], errors = <Json>[];
    final seenRoots = <String>{}, seenFiles = <String>{};
    var errorCount = 0;
    void report(String path, String message) {
      errorCount++;
      if (errors.length < 32) errors.add({'path': path, 'message': message});
    }
    for (final root in roots) {
      cancellation.throwIfCancelled();
      if (!await Directory(root.path).exists()) continue;
      try {
        final canonical = await Directory(root.path).resolveSymbolicLinks();
        if (!seenRoots.add(canonical)) continue;
        final queue = <({String path, int depth})>[(path: root.path, depth: 0)];
        final seenDirectories = <String>{};
        var entries = 0, limited = false;
        for (var index = 0; index < queue.length; index++) {
          cancellation.throwIfCancelled();
          final current = queue[index];
          try {
            final directory = Directory(current.path);
            final resolved = await directory.resolveSymbolicLinks();
            if (!seenDirectories.add(resolved)) continue;
            if (seenDirectories.length > 2000) { limited = true; break; }
            final children = <FileSystemEntity>[];
            final stream = StreamIterator(directory.list(followLinks: false));
            try {
              while (await stream.moveNext().asCancellable(cancellation,
                onCancel: () => unawaited(stream.cancel()))) {
                if (++entries > 20000) { limited = true; break; }
                children.add(stream.current);
              }
            } finally { await stream.cancel(); }
            children.sort((a, b) => a.path.compareTo(b.path));
            for (final child in children) {
              cancellation.throwIfCancelled();
              final name = p.basename(child.path);
              if (name.startsWith('.')) continue;
              final type = await FileSystemEntity.type(child.path);
              if (type == FileSystemEntityType.directory) {
                if (current.depth < 5) queue.add((path: child.path, depth: current.depth + 1));
                else limited = true;
              } else if (type == FileSystemEntityType.file && name == 'SKILL.md') {
                final path = await File(child.path).resolveSymbolicLinks();
                if (!seenFiles.add(path)) continue;
                try {
                  final document = parseSkillDocument(await _read(path, cancellation), path);
                  var implicit = true;
                  final policyFile = File(p.join(p.dirname(path), 'agents', 'openai.yaml'));
                  if (await policyFile.exists()) {
                    // Codex treats invalid optional metadata as absent.
                    try {
                      final metadata = loadYaml(await _read(policyFile.path, cancellation));
                      if (metadata is Map && metadata['policy'] is Map) {
                        implicit = metadata['policy']['allow_implicit_invocation'] != false;
                      }
                    } on YamlException { /* Optional metadata. */ }
                      on FormatException { /* Optional metadata. */ }
                      on FileSystemException { /* Optional metadata. */ }
                  }
                  skills.add({
                    'name': document['name'], 'description': document['description'],
                    if (document['short_description'] != null) 'short_description': document['short_description'],
                    'path': path, 'root': canonical, 'scope': root.scope, 'implicit': implicit,
                  });
                } on FormatException catch (error) {
                  report(path, error.message);
                } on FileSystemException {
                  report(path, 'Unable to read skill file');
                }
              }
            }
            if (limited && entries > 20000) break;
          } on FileSystemException {
            report(current.path, 'Unable to scan skill directory');
          }
        }
        if (limited) report(root.path, 'Skill scan reached its traversal limit');
      } on FileSystemException {
        report(root.path, 'Unable to scan skill root');
      }
    }
    skills.sort((a, b) {
      final scope = (a['scope'] == 'repo' ? 0 : 1).compareTo(b['scope'] == 'repo' ? 0 : 1);
      if (scope != 0) return scope;
      final name = (a['name'] as String).compareTo(b['name'] as String);
      return name != 0 ? name : (a['path'] as String).compareTo(b['path'] as String);
    });
    cancellation.throwIfCancelled();
    return {'skills': skills, 'errors': errors, 'error_count': errorCount};
  }

  Future<Json> read(String cwd, String id, CancellationToken cancellation) async {
    final current = await catalog(cwd, cancellation);
    final skills = (current['skills'] as List).map(jsonObject).toList();
    var pathId = id;
    if (p.isAbsolute(id)) {
      try { pathId = await File(id).resolveSymbolicLinks(); }
      on FileSystemException { /* Missing IDs use the same unavailable error. */ }
    }
    final exact = skills.where((skill) => skill['path'] == pathId).toList();
    final matches = exact.isNotEmpty ? exact : skills.where((skill) => skill['name'] == id).toList();
    if (matches.length != 1) {
      throw StateError(matches.isEmpty ? 'Unable to load skill $id'
        : 'Skill name is ambiguous; use the listed SKILL.md path as its ID');
    }
    final path = matches.single['path'] as String;
    final document = parseSkillDocument(await _read(path, cancellation), path);
    final directory = p.dirname(path);
    final files = <String>[];
    final queue = <String>[directory], visited = <String>{};
    // OpenCode returns a sorted sample of ten supporting files.
    for (var index = 0; index < queue.length && index < 2000; index++) {
      cancellation.throwIfCancelled();
      try {
        final folder = Directory(queue[index]);
        if (!visited.add(await folder.resolveSymbolicLinks())) continue;
        final stream = StreamIterator(folder.list(followLinks: false));
        try {
          while (await stream.moveNext().asCancellable(cancellation,
            onCancel: () => unawaited(stream.cancel()))) {
            final entry = stream.current;
            if (_resourceIgnored.contains(p.basename(entry.path))) continue;
            if (entry is Directory) queue.add(entry.path);
            if (entry is File && p.basename(entry.path) != 'SKILL.md') files.add(entry.path);
            if (files.length >= 20000) break;
          }
        } finally { await stream.cancel(); }
      } on FileSystemException { /* A resource can disappear during listing. */ }
      if (files.length >= 20000) break;
    }
    files.sort();
    return {'name': document['name'], 'directory': directory,
      'content': document['content'], 'files': files.take(10).toList()};
  }
}

const _resourceIgnored = {'.git', 'node_modules', '.venv', 'venv', '__pycache__', '.DS_Store'};

int? _matchSkill(String name, String query) {
  if (query.isEmpty) return 0;
  final lower = name.toLowerCase();
  if (lower == query) return 100000;
  if (lower.startsWith(query)) return 80000 - name.length;
  if (lower.contains(query)) return 60000 - name.length;
  var position = 0, gaps = 0;
  for (final rune in query.runes) {
    final character = String.fromCharCode(rune);
    final found = lower.indexOf(character, position);
    if (found < 0) return null;
    gaps += found - position;
    position = found + character.length;
  }
  return 40000 - gaps * 10 - name.length;
}

Future<String> _read(String path, CancellationToken cancellation) async {
  const limit = 2 * 1024 * 1024;
  final chunks = StreamIterator(File(path).openRead(0, limit + 1));
  final bytes = <int>[];
  try {
    while (await chunks.moveNext().asCancellable(cancellation,
      onCancel: () => unawaited(chunks.cancel()))) {
      bytes.addAll(chunks.current);
      if (bytes.length > limit) throw const FormatException('Skill file exceeds 2 MiB; read it using file tools');
    }
  } finally { await chunks.cancel(); }
  cancellation.throwIfCancelled();
  return utf8.decode(bytes, allowMalformed: true);
}

/// Codex requires a description, defaults the name to its containing directory,
/// and tolerates unquoted prose containing colon-space in YAML scalar fields.
Json parseSkillDocument(String contents, String path) {
  final lines = const LineSplitter().convert(contents);
  if (lines.isEmpty || lines.first.trim() != '---') {
    throw const FormatException('Missing YAML frontmatter delimited by ---');
  }
  final end = lines.indexWhere((line) => line.trim() == '---', 1);
  if (end <= 1) throw const FormatException('Missing YAML frontmatter delimited by ---');
  final frontmatter = lines.sublist(1, end).join('\n');
  Object? value;
  try {
    value = loadYaml(frontmatter);
  } on YamlException {
    try { value = loadYaml(_repairScalars(frontmatter)); }
    on YamlException { throw const FormatException('Invalid skill YAML frontmatter'); }
  }
  if (value is! Map) throw const FormatException('Invalid skill YAML frontmatter');
  String field(Object? value, String name) {
    if (value == null) return '';
    if (value is! String) throw FormatException('Invalid skill $name');
    return value.trim().split(RegExp(r'\s+', unicode: true)).join(' ');
  }
  final supplied = field(value['name'], 'name');
  final name = supplied.isEmpty ? field(p.basename(p.dirname(path)), 'name') : supplied;
  final description = field(value['description'], 'description');
  if (name.runes.length > 64 || name.isEmpty) throw const FormatException('Skill name must contain 1..64 characters');
  if (description.isEmpty) throw const FormatException('Missing skill description');
  final metadata = value['metadata'];
  if (metadata != null && metadata is! Map) throw const FormatException('Invalid skill metadata');
  final short = field(metadata is Map ? metadata['short-description'] : null, 'short-description');
  final delimiter = RegExp(r'^[ \t]*---[ \t]*\r?$', multiLine: true).allMatches(contents).take(2).last;
  var body = contents.substring(delimiter.end);
  if (body.startsWith('\r\n')) body = body.substring(2);
  else if (body.startsWith('\n')) body = body.substring(1);
  return {'name': name, 'description': description,
    if (short.isNotEmpty) 'short_description': short, 'content': body};
}

String _repairScalars(String source) {
  int? blockIndent;
  return const LineSplitter().convert(source).map((line) {
    final indent = line.length - line.trimLeft().length;
    if (blockIndent != null) {
      if (line.trim().isEmpty || indent > blockIndent!) return line;
      blockIndent = null;
    }
    final colon = line.indexOf(':');
    if (colon < 1 || colon + 1 < line.length && !RegExp(r'\s').hasMatch(line[colon + 1])) return line;
    final value = line.substring(colon + 1), start = value.trimLeft();
    if (start.isEmpty || start.startsWith('"') || start.startsWith("'")) return line;
    if (start.startsWith('|') || start.startsWith('>')) { blockIndent = indent; return line; }
    final comment = RegExp(r'(^|\s)#').firstMatch(start);
    final scalar = (comment == null ? start : start.substring(0, comment.start)).trimRight();
    var invalidFlow = false;
    if (scalar.isNotEmpty && ['[', '{', '@', String.fromCharCode(96)].contains(scalar[0])) {
      try { loadYaml(scalar); } on YamlException { invalidFlow = true; }
    }
    if (!RegExp(r':\s').hasMatch(scalar) && !invalidFlow) return line;
    return line.substring(0, colon + 1) + value.substring(0, value.length - start.length)
      + "'" + scalar.replaceAll("'", "''") + "'" + (comment == null ? '' : start.substring(comment.start));
  }).join('\n');
}
