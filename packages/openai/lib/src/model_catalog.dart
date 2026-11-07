import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

import 'catalog.dart';
import 'responses.dart';

// Matches Codex models-manager: five-minute freshness, five-second refresh,
// bundled fallback, and a cache scoped to the authenticated account and route.
class GptCatalog {
  GptCatalog(this.client, {required String directory, required this.lifetime})
    : _file = File('$directory/models_cache.json');

  final ResponsesClient client;
  final CancellationToken lifetime;
  final File _file;
  _CatalogSnapshot? _snapshot;
  Future<void>? _refreshing;
  CancellationToken? _refreshCancellation;

  void invalidate() {
    _refreshCancellation?.cancel();
    _refreshing = null;
    _snapshot = null;
  }

  GptModel model(String id) => GptModel(id, metadata: _snapshot?.models[id]);
  String get defaultModel => catalogDefaultGptModel([
    for (final id in supportedGptModels) model(id).data,
  ]);
  String get revision {
    final snapshot = _snapshot;
    return snapshot == null ? gptCatalogRevision : snapshot.etag ??
      'sha256:${sha256.convert(utf8.encode(jsonEncode(snapshot.models)))}';
  }

  Future<void> refresh(CancellationToken cancellation) {
    cancellation.throwIfCancelled();
    final pending = _refreshing ??= _refresh();
    unawaited(pending.then<void>((_) { if (identical(_refreshing, pending)) _refreshing = null; },
      onError: (Object _, StackTrace _) { if (identical(_refreshing, pending)) _refreshing = null; }));
    return pending.asCancellable(cancellation);
  }

  Future<void> _refresh() async {
    // Custom Responses endpoints have their own model contract. Discovery is
    // part of the ChatGPT Codex backend, including a locally routed backend.
    if (!client.endpoint.path.endsWith('/backend-api/codex/responses')) return;
    final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
    final operation = _refreshCancellation = CancellationToken();
    final token = lifetime.merge(deadline).merge(operation);
    try {
      final Json auth;
      try { auth = await client.credentials().asCancellable(token); }
      catch (_) {
        if (identical(_refreshCancellation, operation)) _snapshot = null;
        rethrow;
      }
      token.throwIfCancelled();
      if (auth['access_token'] is! String || (auth['access_token'] as String).isEmpty) {
        _snapshot = null;
        return;
      }
      final identity = sha256.convert(utf8.encode(jsonEncode([
        client.endpoint.toString(), auth['account_id'] ?? auth['access_token'], auth['plan_type'], gptCatalogClientVersion,
      ]))).toString();
      if (_snapshot?.identity != identity) {
        _snapshot = null;
        try {
          final saved = jsonObject(jsonDecode(await _file.readAsString().asCancellable(token)));
          if (saved['identity'] == identity) _snapshot = _CatalogSnapshot.read(saved);
        } on CancelledException { rethrow; } catch (_) { /* Use the bundled catalog if the cache is unavailable. */ }
      }
      if (_snapshot case final saved? when DateTime.now().toUtc().difference(saved.fetchedAt) < const Duration(minutes: 5)) return;
      final response = await client.models(auth, etag: _snapshot?.etag, cancellation: token);
      final next = _CatalogSnapshot.read({
        'identity': identity, 'fetched_at': DateTime.now().toUtc().toIso8601String(),
        'etag': response.etag, 'models': response.body?['models'] ?? _snapshot?.models.values.toList(),
      });
      token.throwIfCancelled();
      final temporary = File('${_file.path}.${newId()}.tmp');
      try {
        await temporary.writeAsString(jsonEncode(next.toJson()));
        token.throwIfCancelled();
        await temporary.rename(_file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      token.throwIfCancelled();
      _snapshot = next;
    } on CancelledException {
      lifetime.throwIfCancelled();
    } catch (_) {
      // A refresh failure retains this account's cache or the bundled fallback.
      lifetime.throwIfCancelled();
    } finally {
      deadline.cancel();
      if (identical(_refreshCancellation, operation)) _refreshCancellation = null;
    }
  }
}

class _CatalogSnapshot {
  _CatalogSnapshot(this.identity, this.fetchedAt, this.etag, this.models);
  final String identity;
  final DateTime fetchedAt;
  final String? etag;
  final Map<String, Json> models;

  factory _CatalogSnapshot.read(Json saved) {
    final models = <String, Json>{};
    for (final raw in saved['models'] as List) {
      final data = jsonObject(raw), id = requiredString(jsonObject(raw), 'slug');
      if (supportedGptModels.contains(id)) {
        final model = GptModel(id, metadata: data);
        if (model.instructions.isEmpty || model.contextWindow < 1 ||
            !model.reasoningLevels.contains(model.defaultReasoning)) {
          throw const FormatException('Invalid model metadata');
        }
        models[id] = data;
      }
    }
    if (models.isEmpty) throw const FormatException('Model catalog has no supported models');
    return _CatalogSnapshot(requiredString(saved, 'identity'), DateTime.parse(requiredString(saved, 'fetched_at')),
      saved['etag'] as String?, Map.unmodifiable(models));
  }
  Json toJson() => {'identity': identity, 'fetched_at': fetchedAt.toIso8601String(), 'etag': etag, 'models': models.values.toList()};
}
