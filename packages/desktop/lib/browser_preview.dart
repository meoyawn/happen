import 'dart:async';

import 'package:protocol/protocol.dart';

import 'connection.dart';

extension BrowserPreviewRequests on AgentClient {
  Future<List<Json>> discoverRemoteDevServers({required CancellationToken cancellation}) async {
    final reply = jsonObject(await browserRequest('browser.ports', {}, cancellation: cancellation,
      timeout: const Duration(seconds: 20)));
    return (reply['servers'] as List).map(jsonObject).toList();
  }
}

/// A tab keeps its entered URL and owns the lease for the loaded preview.
class BrowserPreview {
  BrowserPreview(this.client);
  final AgentClient client;
  ({String id, Uri local, Uri tunnel})? _lease;
  bool get isOpen => _lease != null;

  Future<Uri> open(Uri uri, CancellationToken cancellation) async {
    if (!client.isConnected) throw StateError('Connect to Happen Server to preview this dev server.');
    if (_lease?.local.port != uri.port) release();
    final id = newId();
    var adopted = false;
    try {
      final reply = jsonObject(await client.browserRequest('browser.preview.open', {'port': uri.port, 'lease': id},
        cancellation: cancellation, timeout: const Duration(seconds: 40)));
      cancellation.throwIfCancelled();
      final tunnel = Uri.parse(requiredString(reply, 'origin'));
      if (tunnel.scheme != 'https' || !tunnel.host.endsWith('.trycloudflare.com') || tunnel.userInfo.isNotEmpty ||
          tunnel.hasPort || tunnel.hasQuery || tunnel.hasFragment || (tunnel.path.isNotEmpty && tunnel.path != '/')) {
        throw const FormatException('Invalid Cloudflare preview URL');
      }
      release();
      _lease = (id: id, local: Uri.parse(uri.origin), tunnel: tunnel);
      adopted = true;
      return _atOrigin(tunnel, uri);
    } finally {
      if (!adopted) unawaited(_release(id));
    }
  }

  Uri localAddress(Uri uri) {
    if (_lease case final lease? when uri.scheme == 'https' && uri.origin == lease.tunnel.origin) {
      return _atOrigin(lease.local, uri);
    }
    return uri;
  }

  Uri loadAddress(Uri uri) {
    if (_lease case final lease? when (uri.scheme == 'http' || uri.scheme == 'https') && uri.origin == lease.local.origin) {
      return _atOrigin(lease.tunnel, uri);
    }
    return uri;
  }

  void release() {
    if (_lease case final lease?) {
      _lease = null;
      unawaited(_release(lease.id));
    }
  }

  Future<void> _release(String id) async {
    if (!client.isConnected) return;
    try { await client.browserRequest('browser.preview.close', {'lease': id}, timeout: const Duration(seconds: 5)); }
    catch (_) { /* The server retires remaining leases when its connection closes. */ }
  }
}

Uri _atOrigin(Uri origin, Uri page) => origin.replace(path: page.path,
  query: page.hasQuery ? page.query : null, fragment: page.hasFragment ? page.fragment : null);
