import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'instructions_data.dart';
import 'instructions_diff.dart';

// SessionSystemPrompt.render's conditional guidance for the tools we expose.
final openCodeInstructions = systemPrompt.replaceFirst(r'${OPENCODE_TOOL_GUIDANCE}', [
  '- Prefer dedicated tools over shell commands; fall back to the shell when a tool cannot do what you need.',
  "- Do not chain shell commands with separators like `echo \"====\";` or `printf '---'`; the output becomes noisy in a way that makes the user's side of the conversation worse.",
  '- Use the write tool to create files or completely replace their content. Prefer using the edit tool for targeted changes.',
  '- Use the edit tool for targeted changes to existing text files. It replaces the exact text in `oldString` with `newString`, and the values must differ. By default, `oldString` must occur exactly once. If it occurs multiple times, include more surrounding context to make it unique or set `replaceAll` to true to replace every occurrence.',
].join('\n'));

ConversationItem renderInstructions(Json current, Json? previous) {
  final files = (current['files'] as List).cast<Json>();
  String render(Json file) => 'Instructions from: ${file['path']}\n${file['text']}';
  String changed(Json before, Json after) {
    final diff = "The instructions from ${after['path']} changed. Here's the diff:\n```diff\n"
      '${instructionDiff(before['text'] as String, after['text'] as String)}\n```';
    final replacement = 'The instructions changed:\n${render(after)}';
    return diff.length < replacement.length ? diff : replacement;
  }
  String text;
  if (previous == null) {
    text = files.map(render).join('\n\n');
  } else {
    final before = {for (final file in (previous['files'] as List).cast<Json>()) file['path']: file};
    final after = {for (final file in files) file['path']: file};
    text = [
      for (final file in before.values) if (!after.containsKey(file['path'])) 'The instructions from ${file['path']} no longer apply.',
      for (final file in files) if (!before.containsKey(file['path'])) 'New instructions apply from:\n${render(file)}',
      for (final file in files) if (before.containsKey(file['path']) && before[file['path']]!['text'] != file['text'])
        changed(before[file['path']]!, file),
    ].join('\n\n');
  }
  if (files.isEmpty) text = 'Previously loaded instructions no longer apply.';
  return ConversationItem(role: 'developer', content: [{'type': 'text', 'text': text}],
    native: {'harness': {'context': 'agents_md'}});
}

ConversationItem renderEnvironment(String cwd, {bool replacement = false}) {
  var root = Directory(cwd), git = false;
  while (true) {
    if (FileSystemEntity.typeSync('${root.path}/.git') != FileSystemEntityType.notFound) { git = true; break; }
    if (root.parent.path == root.path) { root = Directory(cwd); break; }
    root = root.parent;
  }
  final platform = Platform.isMacOS ? 'darwin' : Platform.isWindows ? 'win32' : Platform.operatingSystem;
  final text = [
    replacement ? 'The environment you are running in is now:' : 'Here is some useful information about the environment you are running in:',
    '<env>', '  Working directory: $cwd', '  Workspace root folder: ${root.path}',
    '  Is directory a git repo: ${git ? 'yes' : 'no'}', '  Platform: $platform',
    '  Prefer ${Directory.systemTemp.path} over generic system temporary directories such as /tmp; it is pre-created and approved for external access.',
    '</env>',
  ].join('\n');
  return ConversationItem(role: 'developer', content: [{'type': 'text', 'text': text}],
    native: {'harness': {'context': 'environment'}});
}
