import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

const sqliteWasmAsset = (url: 'https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.8.0/sqlite3.wasm',
  sha256: 'efd308be92a34f3aa15f289a37f213b0230fd80888a1364326ee29579d892d37');
const cloudflaredVersion = '2026.11.0';
const cloudflaredAssets = {
  'x64': (url: 'https://github.com/cloudflare/cloudflared/releases/download/2026.11.0/cloudflared-linux-amd64',
    sha256: '51f7c68b57ed7269164075d7e789efce5b59355982f06392deeb037d982a51fd'),
  'arm64': (url: 'https://github.com/cloudflare/cloudflared/releases/download/2026.11.0/cloudflared-linux-arm64',
    sha256: 'abe54a006acf9faf2d19ee9d953cb0d0804e92f59c5382a162e57b84d086f56f'),
};

Future<File> downloadAsset(({String url, String sha256}) asset, CancellationToken cancellation) async {
  final home = Platform.environment['HOME']!;
  final cache = Directory('$home/.cache/happen/assets');
  await cache.create(recursive: true);
  final file = File('${cache.path}/${asset.sha256}');
  if (await file.exists() && (await sha256.bind(file.openRead()).first).toString() == asset.sha256) return file;
  final pending = File('${file.path}.${newId()}.part');
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final deadline = TimeoutCancellationToken(const Duration(minutes: 5));
  final token = cancellation.merge(deadline);
  final hook = CancellationHook(token, () => http.close(force: true));
  try {
    token.throwIfCancelled();
    final response = await (await http.getUrl(Uri.parse(asset.url))).close().asCancellable(token);
    if (response.statusCode != 200) throw StateError('Asset download failed (${response.statusCode})');
    final output = pending.openWrite();
    final input = ownStream(response, token);
    try { await output.addStream(input.stream); await output.flush(); }
    finally { await input.close(); await output.close(); }
    token.throwIfCancelled();
    if ((await sha256.bind(pending.openRead()).first).toString() != asset.sha256) throw StateError('Asset SHA-256 verification failed');
    return await pending.rename(file.path);
  } finally {
    hook.dispose(); deadline.cancel(); http.close(force: true);
    if (await pending.exists()) await pending.delete();
  }
}
