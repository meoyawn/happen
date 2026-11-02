import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';
import 'package:tool_runtime/tool_runtime.dart' show codexShell;

// Codex UserInstructions + AgentsMdState. File contents stay verbatim; the
// project-doc separator marks the transition from global to project rules.
ConversationItem renderInstructions(Json current, Json? previous) {
  final files = (current['files'] as List).cast<Json>();
  var text = '';
  for (var index = 0; index < files.length; index++) {
    if (index > 0) {
      text = files[index - 1]['global'] == true && files[index]['global'] != true
        ? '${text.trimRight()}\n\n--- project-doc ---\n\n' : '$text\n\n';
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
  final shell = codexShell().split(RegExp(r'[/\\]')).last.replaceFirst(RegExp(r'\.exe$'), '');
  final now = DateTime.now();
  var timezone = Platform.environment['TZ'] ?? now.timeZoneName;
  if (Platform.environment['TZ'] == null && !Platform.isWindows) {
    try {
      final path = File('/etc/localtime').resolveSymbolicLinksSync();
      if (path.contains('/zoneinfo/')) timezone = path.split('/zoneinfo/').last;
    } on FileSystemException { /* The platform abbreviation remains valid. */ }
  }
  final date = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  return ConversationItem(role: 'user', content: [
    {'type': 'text', 'text': '<environment_context>\n  <cwd>${escape(cwd)}</cwd>\n  <shell>${escape(shell)}</shell>\n'
      '  <current_date>$date</current_date>\n  <timezone>${escape(timezone)}</timezone>\n'
      '  <filesystem><workspace_roots><root>${escape(cwd)}</root></workspace_roots>'
      '<permission_profile type="disabled"><file_system type="unrestricted" /></permission_profile></filesystem>\n</environment_context>'},
  ], native: {'harness': {'context': 'environment'}});
}
