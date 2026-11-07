import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';

ToolInterface toolInterface(String provider, {required String model, Json settings = const {}, Json? modelInfo}) => switch (provider) {
  'openai' || 'gpt' => OpenAIToolInterface(webSearch: settings['web_search'] != 'disabled', imageGeneration: settings['image_generation'] == true,
    sleepTool: settings['sleep_tool'] != false, goals: settings['goals'] != false,
    codeModeOnly: GptModel(model, metadata: modelInfo).data['tool_mode'] == 'code_mode_only',
    requestUserInput: settings['request_user_input'] != false,
    defaultModeRequestUserInput: settings['default_mode_request_user_input'] == true),
  'opencode' || 'deepseek' => const OpenCodeToolInterface(),
  _ => throw ArgumentError('Unsupported tool provider: $provider'),
};
