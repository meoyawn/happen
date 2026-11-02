import 'dart:io';

import 'package:flutter/widgets.dart';

typedef ConversationFileLocation = ({String path, int? line});

ConversationFileLocation? conversationFileLocation(String source, String directory) {
  final sourceSuffix = RegExp(r':([1-9]\d*)(?::\d+)?(?=#|$)').firstMatch(source);
  var uri = Uri.tryParse(source);
  if (uri != null && uri.scheme.isNotEmpty && uri.scheme != 'file' &&
      !source.contains('://') && sourceSuffix != null) {
    uri = Uri.tryParse(source.replaceRange(sourceSuffix.start, sourceSuffix.end, ''));
  }
  if (uri == null || !{'', 'file'}.contains(uri.scheme) || source.startsWith('#') ||
      uri.hasAuthority && (uri.scheme != 'file' || uri.host.isNotEmpty && uri.host != 'localhost')) {
    return null;
  }
  if (uri.path.isEmpty) return null;
  if (uri.scheme.isEmpty) {
    final home = Platform.environment['HOME'];
    if (uri.path.startsWith('~/') && home != null) {
      uri = Uri.file('$home/${uri.path.substring(2)}').replace(fragment: uri.fragment);
    } else {
      uri = Directory(directory.isEmpty ? Directory.current.path : directory).absolute.uri.resolveUri(uri);
    }
  }
  var path = uri.replace(fragment: '', query: '', host: '').toFilePath();
  final suffix = RegExp(r':([1-9]\d*)(?::\d+)?$').firstMatch(path);
  final fragment = RegExp(r'^L?([1-9]\d*)(?:C\d+)?(?:-L?\d+(?:C\d+)?)?$', caseSensitive: false)
    .firstMatch(uri.fragment);
  final line = int.tryParse(fragment?[1] ?? suffix?[1] ?? sourceSuffix?[1] ?? '');
  if (suffix != null) path = path.substring(0, suffix.start);
  return (path: File(path).absolute.uri.normalizePath().toFilePath(), line: line);
}

class ConversationFileScope extends InheritedWidget {
  const ConversationFileScope({super.key, required this.onOpen, required super.child});
  final ValueChanged<ConversationFileLocation> onOpen;

  static void open(BuildContext context, ConversationFileLocation location) {
    final scope = context.getInheritedWidgetOfExactType<ConversationFileScope>();
    if (scope == null) throw StateError('File viewer is unavailable');
    scope.onOpen(location);
  }

  @override
  bool updateShouldNotify(ConversationFileScope oldWidget) => onOpen != oldWidget.onOpen;
}
