import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';
import 'package:protocol/protocol.dart';

ToolInterface toolInterface(String provider, {Json settings = const {}}) => switch (provider) {
  'openai' || 'gpt' => OpenAIToolInterface(webSearch: settings['web_search'] != 'disabled'),
  'opencode' || 'deepseek' => const OpenCodeToolInterface(),
  _ => throw ArgumentError('Unsupported tool provider: $provider'),
};
