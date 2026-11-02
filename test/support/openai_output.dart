/// Printed values follow the native code-mode status/timing block.
List<String> printedOpenAIOutput(Object? output) => (output as List).skip(1)
  .map((part) => (part as Map)['text'] as String).toList();

String openAIMessageText(Map message) => message['content'] is String ? message['content'] as String
  : (message['content'] as List? ?? []).map((part) => (part as Map)['text'] ?? '').join('\n');
