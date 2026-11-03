import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

// Codex core/src/tools/handlers/request_user_input_spec.rs. This is a direct
// control tool; Codex deliberately excludes it from Code Mode declarations.
const requestUserInputDefinition = ToolDefinition(
  name: 'request_user_input',
  description: 'Request user input for one to three short questions and wait for the response. '
    'This tool is only available in Default or Plan mode.',
  parameters: {
    'type': 'object',
    'properties': {
      'questions': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'header': {'type': 'string', 'description': 'Short header label shown in the UI (12 or fewer chars).'},
            'id': {'type': 'string', 'description': 'Stable identifier for mapping answers (snake_case).'},
            'options': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'description': {'type': 'string', 'description': 'One short sentence explaining impact/tradeoff if selected.'},
                  'label': {'type': 'string', 'description': 'User-facing label (1-5 words).'},
                },
                'required': ['label', 'description'], 'additionalProperties': false,
              },
              'description': 'Provide 2-3 mutually exclusive choices. Put the recommended option first and suffix its label with '
                '"(Recommended)". Do not include an "Other" option in this list; the client will add a free-form "Other" option automatically.',
            },
            'question': {'type': 'string', 'description': 'Single-sentence prompt shown to the user.'},
          },
          'required': ['id', 'header', 'question', 'options'], 'additionalProperties': false,
        },
        'description': 'Questions to show the user. Prefer 1 and do not exceed 3',
      },
    },
    'required': ['questions'], 'additionalProperties': false,
  },
);

List<Json> requestUserInputQuestions(Object? input) {
  validateToolInput(input, requestUserInputDefinition.parameters, 'request_user_input');
  final questions = (jsonObject(input)['questions'] as List).map(jsonObject).toList();
  if (questions.any((question) => (question['options'] as List).isEmpty)) {
    throw const FormatException('request_user_input requires non-empty options for every question');
  }
  return questions;
}
