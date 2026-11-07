import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';

/// Serialize the frozen buffer with the same adapter used to send inference.
Json inferenceRequest(Json snapshot) {
  final model = jsonObject(snapshot['model']);
  final request = ModelRequest(
    taskId: requiredString(snapshot, 'sessionID'),
    model: requiredString(model, 'id'),
    modelInfo: snapshot['model_info'] == null ? null : jsonObject(snapshot['model_info']),
    instructions: snapshot['instructions'] as String? ?? '',
    input: (snapshot['input'] as List).map((item) => ConversationItem.fromJson(jsonObject(item))).toList(),
    tools: (snapshot['tools'] as List).map((tool) => ToolDefinition.fromJson(jsonObject(tool))).toList(),
    settings: jsonObject(snapshot['settings']),
    effectiveReasoning: requiredString(snapshot, 'effectiveReasoning'),
  );
  return switch (model['providerID']) {
    'openai' => gptRequest(request),
    'opencode' => openCodeRequest(request),
    'deepseek' => openCodeRequest(request, console: false, transport: 'messages'),
    final provider => throw StateError('Unsupported inference provider: $provider'),
  };
}
