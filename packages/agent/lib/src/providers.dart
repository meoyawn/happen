import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';

ToolInterface toolInterface(String provider, {Json settings = const {}}) => switch (provider) {
  'openai' || 'gpt' => OpenAIToolInterface(webSearch: settings['web_search'] != 'disabled', imageGeneration: settings['image_generation'] == true,
    sleepTool: settings['sleep_tool'] != false, goals: settings['goals'] != false,
    codeModeOnly: settings['code_mode_only'] != false, requestUserInput: settings['request_user_input'] == true),
  'opencode' || 'deepseek' => const OpenCodeToolInterface(),
  _ => throw ArgumentError('Unsupported tool provider: $provider'),
};
