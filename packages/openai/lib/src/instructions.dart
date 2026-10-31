import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

// Codex UserInstructions + AgentsMdState. File contents stay verbatim; the
// project-doc separator marks the transition from global to project rules.
ConversationItem renderInstructions(Json current, Json? previous) {
  final files = (current['files'] as List).cast<Json>();
  var text = '';
  for (var index = 0; index < files.length; index++) {
    if (index > 0) {
      text += files[index - 1]['global'] == true && files[index]['global'] != true
        ? '\n\n--- project-doc ---\n\n' : '\n\n';
    }
    text += files[index]['text'] as String;
  }
  if (files.isEmpty) {
    text = 'The previously provided AGENTS.md instructions no longer apply.';
  } else if ((previous?['files'] as List? ?? []).isNotEmpty) {
    text = 'These AGENTS.md instructions replace all previously provided AGENTS.md instructions.\n\n$text';
  }
  final directory = files.isEmpty ? '' : ' for ${current['cwd']}';
  return ConversationItem(role: 'user', content: [
    {'type': 'text', 'text': '# AGENTS.md instructions$directory\n\n<INSTRUCTIONS>\n$text\n</INSTRUCTIONS>'},
  ], native: {'harness': {'context': 'agents_md'}});
}

ConversationItem renderEnvironment(String cwd) {
  String escape(String value) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  final shell = (Platform.environment['SHELL'] ?? (Platform.isWindows ? 'powershell' : '/bin/sh')).split('/').last;
  return ConversationItem(role: 'user', content: [
    {'type': 'text', 'text': '<environment_context>\n  <cwd>${escape(cwd)}</cwd>\n  <shell>${escape(shell)}</shell>\n</environment_context>'},
  ], native: {'harness': {'context': 'environment'}});
}
