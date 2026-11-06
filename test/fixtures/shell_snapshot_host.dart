import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';

// A separate host gives every real runtime its own HOME, startup files and
// environment. No process-wide test overrides or production injection hooks.
Future<void> main(List<String> args) async {
  final lifetime = CancellationToken();
  final runtime = const OpenAIToolInterface().createRuntime(args[0], lifetime);
  final signals = [ProcessSignal.sigterm, ProcessSignal.sigint]
      .map((signal) => signal.watch().listen((_) => lifetime.cancel())).toList();
  Future<Json> command(Json input) async {
    final oneShot = input.remove('one_shot') == true;
    final chars = input.remove('stdin') as String?;
    var result = jsonObject(await runtime.call(oneShot ? 'shell_command' : 'exec_command', {
      'shell': args[1],
      'max_output_tokens': 100000,
      if (!oneShot) 'yield_time_ms': 1000,
      ...input,
    }, cancellation: lifetime));
    final output = StringBuffer('${result['output'] ?? ''}');
    var sent = false;
    while (result['session_id'] != null) {
      result = jsonObject(await runtime.call('write_stdin', {
        'session_id': result['session_id'],
        'yield_time_ms': 1000,
        if (!sent && chars != null) 'chars': chars,
      }, cancellation: lifetime));
      sent = true;
      output.write(result['output'] ?? '');
    }
    return {...result, 'output': output.toString()};
  }

  try {
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final request = jsonObject(jsonDecode(line));
      if (request['close'] == true) break;
      try {
        final calls = (request['commands'] as List).map(jsonObject);
        final results = request['parallel'] == true
            ? await Future.wait(calls.map(command))
            : [for (final input in calls) await command(input)];
        stdout.writeln(jsonEncode({'results': results}));
      } on CancelledException {
        break;
      } catch (error) {
        stdout.writeln(jsonEncode({'error': '$error'}));
      }
    }
  } finally {
    lifetime.cancel();
    await runtime.close();
    for (final signal in signals) { await signal.cancel(); }
  }
}
