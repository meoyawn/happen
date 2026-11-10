import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../config.dart' show ConfigReader, parseConfig;

sealed class ProjectIcon { const ProjectIcon(); }
final class ProjectGlyphIcon extends ProjectIcon {
  const ProjectGlyphIcon(this.name, this.color);
  final String name, color;
}
final class ProjectEmojiIcon extends ProjectIcon {
  const ProjectEmojiIcon(this.emoji);
  final String emoji;
}
final class ProjectMonogramIcon extends ProjectIcon {
  const ProjectMonogramIcon(this.text, this.color);
  final String text, color;
}
final class ProjectFileIcon extends ProjectIcon {
  const ProjectFileIcon(this.path);
  final String path;
}

/// File icons are paths in YAML; other marks have a tagged payload.
Object? projectIconConfig(ProjectIcon? icon) => switch (icon) {
  null => null,
  ProjectFileIcon(:final path) => path,
  ProjectGlyphIcon(:final name, :final color) => {'kind': 'lucide', 'name': name, 'color': color},
  ProjectEmojiIcon(:final emoji) => {'kind': 'emoji', 'emoji': emoji},
  ProjectMonogramIcon(:final text, :final color) => {'kind': 'monogram', 'text': text, 'color': color},
};

ProjectIcon? parseProjectIcon(Object? value) {
  parseConfig(jsonEncode({'icon': value}), partialMcp: true);
  return switch (value) {
    null => null,
    String path => ProjectFileIcon(path),
    {'kind': 'lucide', 'name': final String name, 'color': final String color} => ProjectGlyphIcon(name, color),
    {'kind': 'emoji', 'emoji': final String emoji} => ProjectEmojiIcon(emoji),
    {'kind': 'monogram', 'text': final String text, 'color': final String color} => ProjectMonogramIcon(text, color),
    _ => throw const FormatException('Invalid project icon'),
  };
}

String projectConfigPath(String directory) => p.join(directory, '.happen', 'config.yaml');

Future<ProjectIcon?> loadProjectIcon(String directory, {required CancellationToken cancellation}) async {
  final config = await ConfigReader(partialMcp: true).load(projectConfigPath(directory), cancellation: cancellation);
  return parseProjectIcon(config.values['icon']);
}

/// Updates just the icon value, retaining comments and all other configuration.
/// The caller runs this effect in a worker and serializes writes per project.
Future<void> saveProjectIcon(String directory, ProjectIcon? icon, {required CancellationToken cancellation}) async {
  final file = File(projectConfigPath(directory));
  Future<String> read() async {
    cancellation.throwIfCancelled();
    try {
      if (await file.length() > 1024 * 1024) throw const FormatException('Configuration exceeds 1 MiB');
      return await file.readAsString().asCancellable(cancellation);
    } on PathNotFoundException { return ''; }
  }
  final source = await read();
  final values = parseConfig(source, partialMcp: true);
  if (icon == null && !values.containsKey('icon')) return;
  final value = jsonEncode(projectIconConfig(icon));
  final root = loadYamlNode(source);
  final String updated;
  if (root is YamlMap) {
    final key = root.nodes.keys.where((key) => key.value == 'icon').firstOrNull;
    if (key != null) {
      final node = root.nodes[key]!;
      // A block mapping's span can include the newline before the next key.
      final newline = node.span.text.endsWith('\n') ? '\n' : '';
      updated = source.replaceRange(node.span.start.offset, node.span.end.offset, '$value$newline');
    } else if (root.span.text.startsWith('{')) {
      final end = root.span.end.offset - 1;
      updated = source.replaceRange(end, end, '${root.isEmpty ? '' : ', '}"icon": $value');
    } else {
      final end = root.span.end.offset;
      updated = source.replaceRange(end, end, '${source.substring(0, end).endsWith('\n') ? '' : '\n'}icon: $value\n');
    }
  } else {
    updated = '$source${source.isEmpty || source.endsWith('\n') ? '' : '\n'}icon: $value\n';
  }
  parseConfig(updated, partialMcp: true);
  cancellation.throwIfCancelled();
  await file.parent.create(recursive: true);
  final temporary = await file.parent.createTemp('.icon-');
  try {
    final pending = File(p.join(temporary.path, 'config.yaml'));
    await pending.writeAsString(updated, flush: true);
    cancellation.throwIfCancelled();
    if (await read() != source) throw StateError('Project configuration changed; try saving the icon again');
    cancellation.throwIfCancelled();
    await pending.rename(file.path);
  } finally { await temporary.delete(recursive: true); }
}
