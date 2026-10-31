import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';

import 'package:tool_runtime/tool_runtime.dart';

class NativeTools {
  NativeTools(this.cwd, this.cancellation) {
    _runner = CommandRunner(cancellation);
  }
  final String cwd;
  final CancellationToken cancellation;
  final _background = <Future<void>>{};
  final _notifications = <String>[];
  late final CommandRunner _runner;

  String resolve(String path) => p.normalize(p.isAbsolute(path) ? path
    : path == '~' ? Platform.environment['HOME'] ?? cwd
    : path.startsWith('~/') ? p.join(Platform.environment['HOME'] ?? cwd, path.substring(2))
    : p.join(cwd, path));

  Future<Json> execute(String name, Json input) async {
    cancellation.throwIfCancelled();
    switch (name) {
      case 'shell':
        final id = newId();
        final background = input['background'] == true;
        final timeout = input['timeout'] as int? ?? (background ? 0 : 120000);
        final result = _run(defaultShell,
          ['-c', requiredString(input, 'command')],
          directory: resolve(input['workdir'] as String? ?? '.'), timeout: timeout);
        if (!background) return result;
        late final Future<void> pending;
        pending = result.then((value) {
          _notifications.add('Background command $id completed.\n${value['output']}');
        }, onError: (Object error) {
          if (!cancellation.isCancelled) _notifications.add('Background command $id failed: $error');
        }).whenComplete(() => _background.remove(pending));
        _background.add(pending);
        return {'output': 'Command moved to the background (shell ID: $id).\nYou will be notified automatically when the command finishes. DO NOT poll for completion.',
          'shellID': id, 'truncated': false, 'status': 'running'};
      case 'read': return _read(input);
      case 'write':
        final file = File(resolve(requiredString(input, 'path')));
        final existed = await file.exists();
        final before = existed ? await file.readAsString() : '';
        var content = input['content'] as String;
        if (before.startsWith('\ufeff') && !content.startsWith('\ufeff')) content = '\ufeff$content';
        await file.parent.create(recursive: true);
        cancellation.throwIfCancelled();
        await file.writeAsString(content);
        return {'output': '${existed ? 'Wrote' : 'Created'} file successfully: ${input['path']}'};
      case 'edit': return _edit(input);
      case 'patch': return {'output': await applyPatch(cwd, input['patchText'] as String)};
      case 'glob':
      case 'grep': return _search(name, input);
      default: throw StateError('Unknown OpenCode tool: $name');
    }
  }

  Future<Json> _read(Json input) async {
    final path = requiredString(input, 'path'), absolute = resolve(path);
    final offset = (input['offset'] as int? ?? 1) == 0 ? 1 : input['offset'] as int? ?? 1;
    final requested = input['limit'] as int? ?? 2000;
    final limit = (requested == 0 ? 2000 : requested).clamp(1, 2000);
    final type = await FileSystemEntity.type(absolute);
    if (type == FileSystemEntityType.directory) {
      final entries = await Directory(absolute).list(followLinks: false).toList();
      entries.sort((a, b) => (a is Directory) != (b is Directory)
        ? (a is Directory ? -1 : 1) : p.basename(a.path).compareTo(p.basename(b.path)));
      final selected = entries.skip(offset - 1).take(limit).toList();
      final next = offset - 1 + selected.length < entries.length ? offset + selected.length : null;
      return {'output': [
        selected.isEmpty ? 'Read directory $path, 0 entries' : 'Read directory $path, entries $offset-${offset + selected.length - 1}',
        ...selected.map((entry) => '${p.basename(entry.path)}${entry is Directory ? p.separator : ''}'),
        if (next != null) '[Output truncated. Continue reading with offset: $next]',
      ].join('\n')};
    }
    if (type != FileSystemEntityType.file) throw StateError('Unable to read $path');
    final file = File(absolute);
    final first = await file.openRead(0, 4096).fold<List<int>>([], (a, b) => a..addAll(b));
    if (first.contains(0)) throw StateError('Cannot read binary file: $path');
    final lines = <String>[];
    var index = 0, bytes = 0;
    int? next;
    await for (final raw in file.openRead().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
      cancellation.throwIfCancelled();
      if (++index < offset) continue;
      final line = raw.length > 2000 ? '${raw.substring(0, 2000)}... (line truncated to 2000 chars)' : raw;
      final size = utf8.encode(line).length + (lines.isEmpty ? 0 : 1);
      if (lines.length >= limit || bytes + size > 50 * 1024) { next = index; break; }
      lines.add(line);
      bytes += size;
    }
    if (lines.isEmpty && offset != 1) throw StateError('Offset $offset is out of range for this file ($index ${index == 1 ? 'line' : 'lines'})');
    return {'output': [
      lines.isEmpty ? 'Read file $path, 0 lines' : 'Read file $path, lines $offset-${offset + lines.length - 1}',
      for (var i = 0; i < lines.length; i++) '${offset + i}: ${lines[i]}',
      if (next != null) '[Output truncated. Continue reading with offset: $next]',
    ].join('\n')};
  }

  Future<Json> _edit(Json input) async {
    final path = requiredString(input, 'path'), file = File(resolve(requiredString(input, 'path')));
    var old = input['oldString'] as String, replacement = input['newString'] as String;
    if (old == replacement) throw StateError('No changes to apply: oldString and newString are identical.');
    if (old.isEmpty) throw StateError('oldString must not be empty. Use write to create or overwrite a file.');
    final original = await file.readAsString();
    final endingsOnly = old.replaceAll('\r', '') == replacement.replaceAll('\r', '');
    var source = endingsOnly ? original : original.replaceAll('\r\n', '\n');
    if (!endingsOnly) {
      old = old.replaceAll('\r\n', '\n'); replacement = replacement.replaceAll('\r\n', '\n');
    }
    var matches = _occurrences(source, old);
    if (matches.isEmpty) {
      String normalize(String value) => value.replaceAll(RegExp('[\u2018\u2019]'), "'")
        .replaceAll(RegExp('[\u201c\u201d]'), '"').replaceAll(RegExp('[\u2010-\u2015]'), '-')
        .replaceAll(RegExp('[\u00a0\u2000-\u200a\u202f\u205f\u3000]'), ' ');
      matches = _occurrences(normalize(source), normalize(old));
    }
    if (matches.isEmpty) throw StateError('Could not find oldString in $path. It must match exactly, including whitespace and indentation.');
    if (matches.length > 1 && input['replaceAll'] != true) {
      throw StateError('Found ${matches.length} matches for oldString, but expected exactly one. Add more surrounding context to make oldString unique, or set replaceAll to true to replace every occurrence.');
    }
    for (final start in (input['replaceAll'] == true ? matches : matches.take(1)).toList().reversed) {
      source = source.replaceRange(start, start + old.length, replacement);
    }
    if (!endingsOnly && original.contains('\r\n')) source = source.replaceAll('\n', '\r\n');
    if (source == original) throw StateError('No changes to apply: the edit leaves $path unchanged.');
    cancellation.throwIfCancelled();
    await file.writeAsString(source);
    return {'output': 'Edited file successfully: $path'};
  }

  List<int> _occurrences(String source, String pattern) {
    final matches = <int>[];
    for (var offset = source.indexOf(pattern); offset >= 0; offset = source.indexOf(pattern, offset + pattern.length)) {
      matches.add(offset);
    }
    return matches;
  }

  Future<Json> _search(String name, Json input) async {
    final target = resolve(input['path'] as String? ?? '.');
    final file = await FileSystemEntity.type(target) == FileSystemEntityType.file;
    final directory = file ? p.dirname(target) : target;
    final result = await _run('rg', [
      if (name == 'glob') ...['--files', '--null', '--glob', input['pattern'] as String,
        if (input['hidden'] == true) '--hidden', '--glob', '!.git/**']
      else ...['--json', '--line-number', '--color', 'never',
        if (input['literal'] == true) '--fixed-strings',
        if (input['caseSensitive'] == false) '--ignore-case',
        if (input['include'] != null) ...['--glob', input['include'] as String],
        '--', input['pattern'] as String, file ? p.basename(target) : '.'],
    ], directory: directory, timeout: 30000, maxBytes: null);
    if ((result['exit'] as int) > 1) throw StateError(result['output'] as String);
    final limit = input['limit'] as int? ?? 100;
    if (name == 'glob') {
      final all = (result['output'] as String).split('\u0000').where((line) => line.isNotEmpty).toList();
      return {'output': [
        if (all.isEmpty) 'No files found' else ...all.take(limit).map((path) => p.join(directory, path)),
        if (all.length > limit) '\n(Results are truncated: showing first $limit results. Consider using a more specific path or pattern.)',
      ].join('\n')};
    }
    final matches = <Json>[];
    for (final line in const LineSplitter().convert(result['output'] as String)) {
      final item = jsonObject(jsonDecode(line));
      if (item['type'] == 'match') matches.add(jsonObject(item['data']));
    }
    final lines = <String>[matches.isEmpty ? 'No matches found' : 'Found ${matches.length.clamp(0, limit)} matches'];
    String? previous;
    for (final match in matches.take(limit)) {
      final path = p.join(directory, match['path']['text'] as String);
      if (path != previous) { if (previous != null) lines.add(''); lines.add('$path:'); previous = path; }
      lines.add('  Line ${match['line_number']}: ${(match['lines']['text'] as String).trimRight()}');
    }
    if (matches.length > limit) lines.add('\n(Results are truncated: showing first $limit results. Consider using a more specific path or pattern.)');
    return {'output': lines.join('\n')};
  }

  Future<Json> _run(String executable, List<String> arguments, {required String directory, required int timeout, int? maxBytes = 50 * 1024}) async {
    final command = await _runner.start(executable, arguments, directory: directory,
      timeout: timeout == 0 ? null : Duration(milliseconds: timeout));
    await command.done.asCancellable(cancellation);
    final captured = await command.capture(maxBytes: maxBytes);
    return {'output': '${captured.text}${captured.truncated ? '\n[Output truncated. Full output saved to: ${command.outputFile.path}]' : ''}${command.timedOut ? '\nCommand timed out after $timeout ms.' : ''}',
      'exit': command.exitCode, 'truncated': captured.truncated, if (command.timedOut) 'timeout': true, 'status': 'completed'};
  }

  Future<List<String>> notifications({bool wait = false}) async {
    if (wait && _notifications.isEmpty && _background.isNotEmpty) {
      await Future.any(_background).asCancellable(cancellation);
    }
    final result = _notifications.toList(); _notifications.clear(); return result;
  }

  void close() => _runner.close();
}
