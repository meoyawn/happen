import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:opencode/opencode.dart';

ToolInterface toolInterface(String provider) => switch (provider) {
  'openai' || 'gpt' => const OpenAIToolInterface(),
  'opencode' || 'deepseek' => const OpenCodeToolInterface(),
  _ => throw ArgumentError('Unsupported tool provider: $provider'),
};
