import 'dart:convert';
import 'dart:io';

import 'package:gpt/gpt.dart';
import 'package:protocol/protocol.dart';

Future<void> main(List<String> arguments) async {
  final auth = AuthManager(
    arguments.isEmpty ? defaultDataDirectory() : arguments.single,
  );
  final client = ResponsesClient(credentials: auth.credentials);
  final sessionId = newId();
  const instructions =
      'Follow the user instructions accurately. Keep answers brief.';
  final result = <String, Object?>{
    'model': 'gpt-6.1-sol',
    'baseline_effort': 'low',
    'changed_effort': 'high',
    'endpoint': 'chatgpt_subscription',
  };
  String stage = 'initial_response';
  final watch = Stopwatch()..start();
  Future<ResponsesReply> respond(List<Json> input) => client.respond(
    model: 'gpt-6.1-sol',
    instructions: instructions,
    input: input,
    tools: [],
    reasoning: 'low',
    sessionId: sessionId,
    cancellation: CancellationToken(),
  );
  try {
    final original = <Json>[
      {
        'role': 'user',
        'content': 'For this test, the project code is maple-47 and the required output file is result.txt. Remember both. Reply READY.',
      },
    ];
    final first = await respond(original);
    result['initial_usage'] = {...first.usage}..remove('attribution');
    stage = 'native_compaction';
    final compacted = await respond([
      ...original,
      ...first.output,
      {
        'type': 'configuration_update',
        'reasoning': {'effort': 'high'},
      },
      {
        'role': 'user',
        'content': 'One more constraint: the output file must end with a newline. Keep the project code and filename unchanged.',
      },
      {'type': 'compaction_trigger'},
    ]);
    result['compaction_item_types'] = compacted.output
        .map((item) => item['type'])
        .toList();
    result['compaction_usage'] = {...compacted.usage}..remove('attribution');
    if (!compacted.output.any((item) => item['type'] == 'compaction')) {
      throw StateError('No native compaction item returned');
    }
    stage = 'continuation';
    final continued = await respond([
      ...compacted.output,
      {
        'type': 'configuration_update',
        'reasoning': {'effort': 'high'},
      },
      {
        'role': 'user',
        'content': 'What is the project code, required filename, and newline constraint? Answer in one sentence.',
      },
    ]);
    result['continuation_text'] = continued.text;
    result['continuation_usage'] = {...continued.usage}..remove('attribution');
    result['passed'] =
        continued.text.contains('maple-47') &&
        continued.text.contains('result.txt') &&
        continued.text.toLowerCase().contains('newline');
  } catch (error) {
    result['failed_stage'] = stage;
    result['error'] = error.toString();
    result['passed'] = false;
  } finally {
    client.close();
    auth.close();
  }
  result['elapsed_ms'] = watch.elapsedMilliseconds;
  final encoded = const JsonEncoder.withIndent('  ').convert(result);
  stdout.writeln(encoded);
  if (result['passed'] != true) exitCode = 1;
}
