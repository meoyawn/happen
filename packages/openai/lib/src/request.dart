import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'records.dart';
import 'catalog.dart';

/// The JSON sent to Responses, shared by inference and request inspection.
Json responsesRequest({
  required String model,
  required String instructions,
  required List<Json> input,
  required List<Json> tools,
  required String sessionId,
  String reasoning = 'xhigh',
  String toolChoice = 'auto',
  String transport = 'http',
  String verbosity = 'low',
  String reasoningSummary = 'auto',
  int? maxOutputTokens,
}) {
  if (!{'http', 'websocket'}.contains(transport)) {
    throw ArgumentError('GPT transport must be http or websocket');
  }
  final modalities = supportedGptModels.contains(model) ? GptModel(model).data['input_modalities'] as List : null;
  Json media(Json part) {
    final kind = switch (part['type']) { 'input_image' => 'image', 'input_audio' => 'audio', _ => null };
    return kind != null && modalities != null && !modalities.contains(kind)
      ? {'type': 'input_text', 'text': '$kind content omitted because you do not support $kind input'} : part;
  }
  return {
    if (transport == 'websocket') 'type': 'response.create',
    'model': model,
    'input': [for (final item in withGptInstructions(instructions, input, sessionId: sessionId)) {
      ...item,
      for (final key in ['content', 'output'])
        if (item[key] is List) key: [for (final part in item[key] as List) media(jsonObject(part))],
    }],
    if (tools.isNotEmpty) 'tools': tools,
    'tool_choice': toolChoice,
    'parallel_tool_calls': true,
    'store': false,
    if (transport == 'http') 'stream': true,
    'include': ['reasoning.encrypted_content'],
    'prompt_cache_key': sessionId,
    'reasoning': {
      'effort': reasoning,
      if (reasoningSummary != 'none') 'summary': reasoningSummary,
    },
    'text': {'verbosity': verbosity},
    'max_output_tokens': ?maxOutputTokens,
  };
}

Json gptRequest(ModelRequest request) => responsesRequest(
  model: request.model,
  instructions: request.instructions,
  input: gptInput(request.input),
  tools: gptTools(request.tools),
  sessionId: request.taskId,
  reasoning: request.settings['reasoning'] as String,
  toolChoice: request.toolChoice,
  transport: request.settings['transport'] as String? ?? 'http',
  verbosity: request.settings['verbosity'] as String? ?? 'low',
  reasoningSummary: request.settings['reasoning_summary'] as String? ?? 'auto',
);
