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
  final info = supportedGptModels.contains(model) ? GptModel(model).data : null;
  final modalities = info?['input_modalities'] as List?;
  Json media(Json part) {
    final kind = switch (part['type']) { 'input_image' => 'image', 'input_audio' => 'audio', _ => null };
    if (kind != null && modalities != null && !modalities.contains(kind)) {
      return {'type': 'input_text', 'text': '$kind content omitted because you do not support $kind input'};
    }
    if (kind == 'image') {
      final image = {...part};
      // Codex client_common.rs projects image detail for the receiving model.
      if (info?['use_responses_lite'] == true) {
        image.remove('detail');
      } else if (image['detail'] == 'original' && info?['supports_image_detail_original'] != true) {
        image['detail'] = 'high';
      }
      return image;
    }
    return part;
  }
  final context = input.any((item) => item['type'] == 'additional_tools') ? input : [
    if (tools.isNotEmpty) {'type': 'additional_tools', 'role': 'developer', 'tools': tools},
    ...withGptInstructions(instructions, input, sessionId: sessionId),
  ];
  return {
    if (transport == 'websocket') 'type': 'response.create',
    'model': model,
    'input': [for (final item in context) {
      ...item,
      for (final key in ['content', 'output'])
        if (item[key] is List) key: [for (final part in item[key] as List) media(jsonObject(part))],
    }],
    'tool_choice': toolChoice,
    'parallel_tool_calls': false,
    'store': false,
    if (transport == 'http') 'stream': true,
    'include': ['reasoning.encrypted_content'],
    'prompt_cache_key': sessionId,
    'reasoning': {
      'effort': reasoning,
      if (reasoningSummary != 'none') 'summary': reasoningSummary,
      'context': 'all_turns',
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
