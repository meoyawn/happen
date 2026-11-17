import 'package:protocol/protocol.dart';
import 'connection_web.dart';
Future<void> signInTunnel(String url, String key, CancellationToken cancellation) async {
  final server = Uri.parse(url);
  if (key.isEmpty) { await restoreServerSignIn(server, cancellation); }
  else { await signInServer(server, key, cancellation); }
}
