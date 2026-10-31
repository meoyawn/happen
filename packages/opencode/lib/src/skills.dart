import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

// OpenCode e8238bae packages/core/src/tool/plugin/skill.ts and src/skill.ts.
const skillDefinition = ToolDefinition(
  name: 'skill',
  description: "Load a specialized skill's instructions and resources into the current conversation when the task at hand matches its description.\n\n"
    'The skill ID must match an available skill or a skill explicitly referenced by the user.',
  parameters: {
    'type': 'object',
    'properties': {'id': {'type': 'string',
      'description': 'The ID of an available skill or a skill explicitly referenced by the user'}},
    'required': ['id'], 'additionalProperties': false,
  },
);

String skillOutput(Json skill) => [
  '<skill_content name="' + (skill['name'] as String) + '">',
  '# Skill: ' + (skill['name'] as String),
  '',
  (skill['content'] as String).trim(),
  '',
  'Base directory for this skill: ' + (skill['directory'] as String),
  'Relative paths in this skill (e.g., scripts/, reference/) are relative to this base directory.',
  'Note: file list is sampled.',
  '',
  '<skill_files>',
  for (final file in skill['files'] as List) '<file>$file</file>',
  '</skill_files>',
  '</skill_content>',
].join('\n');
