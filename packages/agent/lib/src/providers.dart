import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';

ToolInterface toolInterface(String provider, {required String model, Json settings = const {}, Json? modelInfo}) {
  switch (provider) {
    case 'openai' || 'gpt':
      final info = GptModel(model, metadata: modelInfo);
      return OpenAIToolInterface(
        webSearch: settings['web_search'] != 'disabled',
        imageGeneration: settings['image_generation'] == true,
        sleepTool: settings['sleep_tool'] != false,
        goals: settings['goals'] != false,
        codeModeOnly: info.data['tool_mode'] == 'code_mode_only',
        codeModeToolSearch: settings['code_mode_tool_search'] == true,
        requestUserInput: settings['request_user_input'] != false,
        defaultModeRequestUserInput: settings['default_mode_request_user_input'] == true,
        sendMessageToUserAsync: info.supportsExperimentalTool('send_message_to_user_async'),
        literatureSearch: info.supportsExperimentalTool('literature_search_query'),
      );
    case 'opencode' || 'deepseek':
      return const OpenCodeToolInterface();
    default:
      throw ArgumentError('Unsupported tool provider: $provider');
  }
}
