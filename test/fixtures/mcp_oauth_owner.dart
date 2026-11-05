import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:mcp/mcp.dart';
import 'package:mcp/src/oauth.dart';
import 'package:mcp/src/transport.dart' show McpCredentialFailure;
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

// One independent real credential owner, used unchanged in another isolate or
// process. It caches the initial token, then waits for an explicit rejected-token
// refresh. No fixture supplies the lock, persistence or refresh acknowledgement.
Future<void> credentialOwner(Json args, void Function(Json) emit, Future<void> start, CancellationToken lifetime) async {
  final http = HttpClient(), events = ReceivePort();
  final traces = events.listen((event) => emit({'trace': event}));
  final auth = McpOAuth(args['directory'] as String, args['name'] as String, {'url': args['url']}, http);
  try {
    await auth.authorization(lifetime);
    emit({'ready': true}); await start.asCancellable(lifetime);
    auth.challenge(401, ['Bearer error="invalid_token"'], sentToken: true);
    final result = await withTrace(TraceContext(sink: events.sendPort, service: 'network'), () => auth.authorization(lifetime));
    emit({'result': result});
  } catch (error) {
    emit({'error': error is McpFailure ? error.message : error.runtimeType.toString(),
      'authenticationRequired': error is McpCredentialFailure && error.authenticationRequired});
  } finally { await auth.close(); http.close(force: true); await traces.cancel(); events.close(); }
}

Future<void> credentialIsolate(Json args) async {
  final output = args['output'] as SendPort, control = ReceivePort(), start = Completer<void>();
  final lifetime = CancellationToken();
  final commands = control.listen((command) {
    if (command == 'start') { if (!start.isCompleted) start.complete(); }
    else { lifetime.cancel(); }
  });
  output.send({'control': control.sendPort});
  try { await credentialOwner(args, output.send, start.future, lifetime); }
  finally { lifetime.cancel(); await commands.cancel(); control.close(); }
}

Future<void> main(List<String> arguments) async {
  final args = jsonObject(jsonDecode(arguments.single)), start = Completer<void>();
  final lifetime = TimeoutCancellationToken(const Duration(minutes: 3));
  final commands = utf8.decoder.bind(stdin).transform(const LineSplitter()).listen((command) {
    if (command == 'start') { if (!start.isCompleted) start.complete(); }
    else { lifetime.cancel(); }
  });
  try { await credentialOwner(args, (value) => stdout.writeln(jsonEncode(value)), start.future, lifetime); }
  finally { lifetime.cancel(); await commands.cancel(); }
}
