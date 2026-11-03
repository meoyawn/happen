import 'package:protocol/protocol.dart';

import 'model.dart';
import 'tool_input.dart';

// OpenCode's question tool contract: answers retain the order of the prompts.
const questionDefinition = ToolDefinition(
  name: 'question',
  description: 'Ask the user questions during execution to gather requirements, '
    'clarify instructions, or get decisions on implementation choices.\n'
    'A "Type your own answer" option is added automatically; do not include a '
    'separate option for free form answers. Set multiple: true to allow selecting '
    'more than one option. Put a recommended option first and append '
    '"(Recommended)" to its label. Wait for the user to answer before continuing.',
  parameters: {
    'type': 'object',
    'properties': {
      'questions': {
        'type': 'array', 'minItems': 1,
        'items': {
          'type': 'object',
          'properties': {
            'question': {'type': 'string', 'minLength': 1, 'description': 'Complete question'},
            'header': {'type': 'string', 'description': 'Very short label (max 30 characters)'},
            'options': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'label': {'type': 'string', 'minLength': 1, 'description': 'Concise display text'},
                  'description': {'type': 'string', 'description': 'Explanation of this choice'},
                },
                'required': ['label', 'description'], 'additionalProperties': false,
              },
            },
            'multiple': {'type': 'boolean', 'description': 'Allow selecting multiple choices'},
          },
          'required': ['question', 'header', 'options'], 'additionalProperties': false,
        },
      },
    },
    'required': ['questions'], 'additionalProperties': false,
  },
);

List<Json> questionPrompts(Object? input) {
  validateToolInput(input, questionDefinition.parameters, 'question');
  return (jsonObject(input)['questions'] as List).map(jsonObject).toList();
}

List<List<String>> questionAnswers(List<Json> questions, Object? input) {
  if (input is! List || input.length != questions.length) {
    throw const FormatException('Provide one answer array for each question');
  }
  return [
    for (var i = 0; i < questions.length; i++) _answer(questions[i], input[i]),
  ];
}

List<String> _answer(Json question, Object? input) {
  if (input is! List || input.any((value) => value is! String || value.trim().isEmpty)) {
    throw const FormatException('Answers must be nonempty strings');
  }
  final values = input.cast<String>().map((value) => value.trim()).toSet().toList();
  if (question['multiple'] != true && values.length > 1) {
    throw const FormatException('This question accepts only one answer');
  }
  return values;
}

String questionAnswerText(List<Json> questions, List<List<String>> answers) =>
  'User has answered your questions: ${[
    for (var i = 0; i < questions.length; i++)
      '"${questions[i]['question']}"="${answers[i].isEmpty ? 'Unanswered' : answers[i].join(', ')}"',
  ].join(', ')}. You can now continue with the user\'s answers in mind.';
