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

const requestUserInputAsyncDefinition = ToolDefinition(
  name: 'request_user_input_async',
  description: 'Ask the user one or more questions during ongoing work. Use this tool only to request missing information, '
    'preferences, constraints, clarification, or approval. The tool returns immediately without ending the turn or waiting '
    'for a reply; any reply arrives asynchronously as a new user message. Keep questions concise, self-contained, and easy '
    'to understand, using a level of detail appropriate to the user and task. The UI always allows a free-text answer, '
    'including when suggested options are provided. A preselected option is not submitted automatically.',
  parameters: {
    'type': 'object',
    'properties': {
      'questions': {
        'type': 'array', 'minItems': 1,
        'description': 'One or more self-contained questions to present together, in display order.',
        'items': {
          'type': 'object',
          'properties': {
            'options': {
              'type': 'array', 'minItems': 1, 'items': {'type': 'string'},
              'description': 'Suggested answers, in display order. Put the recommended answer first; the first option is '
                'preselected by default. The user can select one option or enter a free-text answer. Do not include an '
                'Other option or a free-text placeholder; the UI provides free-text input automatically. Omit options '
                'for a free-text-only question.',
            },
            'title': {'type': 'string',
              'description': 'The complete question shown to the user, including any context needed to answer it.'},
          },
          'required': ['title'], 'additionalProperties': false,
        },
      },
    },
    'required': ['questions'], 'additionalProperties': false,
  },
);

List<Json> requestUserInputAsyncQuestions(Object? input) {
  validateToolInput(input, requestUserInputAsyncDefinition.parameters, 'request_user_input_async');
  final questions = (jsonObject(input)['questions'] as List).map(jsonObject).toList();
  if (questions.any((question) => (question['title'] as String).trim().isEmpty)) {
    throw const FormatException('question titles must not be empty');
  }
  if (questions.any((question) =>
      (question['options'] as List? ?? []).any((option) => (option as String).trim().isEmpty))) {
    throw const FormatException('options must contain at least one non-empty answer');
  }
  return [for (final question in questions) {
    'header': 'Question', 'question': question['title'],
    'options': [for (final option in question['options'] as List? ?? []) {'label': option, 'description': ''}],
  }];
}

List<Json> requestUserInputQuestions(Object? input) {
  validateToolInput(input, requestUserInputDefinition.parameters, 'request_user_input');
  final questions = (jsonObject(input)['questions'] as List).map(jsonObject).toList();
  if (questions.any((question) => (question['options'] as List).isEmpty)) {
    throw const FormatException('request_user_input requires non-empty options for every question');
  }
  return questions;
}
