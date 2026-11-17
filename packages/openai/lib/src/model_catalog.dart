import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

import 'catalog.dart';
import 'responses.dart';

enum CatalogRefresh { inMemory, online, offline, onlineIfUncached }

const _cacheTtl = Duration(minutes: 5);
typedef _CatalogOperation = ({CancellationToken cancellation, Future<void> done, CatalogRefresh strategy});

sealed class _CatalogState { const _CatalogState(); }
class _CatalogReady extends _CatalogState {
  const _CatalogReady(this.snapshot);
  final _CatalogSnapshot? snapshot;
}
class _CatalogLoading extends _CatalogState {
  const _CatalogLoading(this.snapshot, this.operation);
  final _CatalogSnapshot? snapshot;
  final _CatalogOperation operation;
}
class _CatalogWriting extends _CatalogState {
  const _CatalogWriting(this.previous, this.pending, this.operation);
  final _CatalogSnapshot? previous;
  final _CatalogSnapshot pending;
  final _CatalogOperation operation;
}
class _CatalogFailed extends _CatalogState {
  const _CatalogFailed(this.snapshot, this.error);
  final _CatalogSnapshot? snapshot;
  final Object error;
}

bool _validCatalogTransition(_CatalogState current, _CatalogState next) => switch ((current, next)) {
  (_CatalogReady() || _CatalogFailed(), _CatalogLoading() || _CatalogReady()) => true,
  (_CatalogLoading(), _CatalogLoading() || _CatalogWriting() || _CatalogReady() || _CatalogFailed()) => true,
  (_CatalogWriting(), _CatalogReady() || _CatalogFailed()) => true,
  _ => false,
};

// Ported from Codex models-manager at 0122b120c: fresh, versioned, identity-scoped
// disk snapshots; authoritative visible catalogs; response ETag revalidation.
class GptCatalog {
  GptCatalog(this.client, {required String directory, required this.lifetime})
    : _file = File('$directory/models_cache.json');

  final ResponsesClient client;
  final CancellationToken lifetime;
  final File _file;
  _CatalogState _state = const _CatalogReady(null);

  _CatalogSnapshot? get _snapshot => switch (_state) {
    _CatalogReady(:final snapshot) || _CatalogLoading(:final snapshot) || _CatalogFailed(:final snapshot) => snapshot,
    _CatalogWriting(:final previous) => previous,
  };
  _CatalogOperation? get _operation => switch (_state) {
    _CatalogLoading(:final operation) || _CatalogWriting(:final operation) => operation,
    _ => null,
  };

  void _transition(_CatalogState next) {
    if (!_validCatalogTransition(_state, next)) throw StateError('Invalid model catalog transition');
    _state = next;
  }

  void invalidate() {
    final operation = _operation;
    _transition(const _CatalogReady(null));
    operation?.cancellation.cancel();
  }

  Map<String, Json> get _models {
    final remote = _snapshot?.models;
    if (remote == null) return bundledGptModels;
    // Codex keeps the bundled picker when discovery returns no visible models.
    return remote.values.any((model) => model['visibility'] == 'list')
      ? remote : {...bundledGptModels, ...remote};
  }

  List<GptModel> get models => catalogGptModels(_models.values);
  GptModel model(String id) => GptModel(id, metadata: _models[id]);
  bool available(String id) => _models.containsKey(id);
  String get defaultModel => catalogDefaultGptModel(_models.values);
  String get revision {
    final snapshot = _snapshot;
    return snapshot == null ? gptCatalogRevision : snapshot.etag ??
      'sha256:${sha256.convert(utf8.encode(jsonEncode(snapshot.models)))}';
  }

  Future<void> refresh(CancellationToken cancellation, {CatalogRefresh strategy = CatalogRefresh.onlineIfUncached}) =>
    _start(cancellation, strategy);

  Future<void> refreshIfNewEtag(String etag, CancellationToken cancellation) =>
    _start(cancellation, CatalogRefresh.online, etag: etag);

  Future<void> _start(CancellationToken cancellation, CatalogRefresh strategy, {String? etag}) {
    cancellation.throwIfCancelled();
    lifetime.throwIfCancelled();
    if (strategy == CatalogRefresh.inMemory || !client.endpoint.path.endsWith('/backend-api/codex/responses')) {
      return Future.value();
    }
    final running = _operation;
    if (running != null) {
      return running.done.asCancellable(cancellation).then((_) {
        // A cache-only read cannot satisfy an explicit request to refresh online.
        if (etag != null || strategy == CatalogRefresh.online && running.strategy != CatalogRefresh.online) {
          return _start(cancellation, strategy, etag: etag);
        }
      });
    }
    final completed = Completer<void>();
    final operation = (cancellation: CancellationToken(), done: completed.future, strategy: strategy);
    _transition(_CatalogLoading(_snapshot, operation));
    final hook = CancellationHook(cancellation.merge(lifetime), () => _cancel(operation));
    unawaited(_refresh(operation, cancellation, etag: etag).then<void>(
      (_) => completed.complete(), onError: (Object error, StackTrace stack) => completed.completeError(error, stack),
    ).whenComplete(hook.dispose));
    return completed.future.asCancellable(cancellation);
  }

  bool _owns(_CatalogOperation operation) => identical(_operation?.cancellation, operation.cancellation);

  void _cancel(_CatalogOperation operation) {
    if (!_owns(operation)) return;
    _transition(_CatalogReady(_snapshot));
    operation.cancellation.cancel();
  }

  String? _identity(Json auth) {
    if (auth['access_token'] is! String || (auth['access_token'] as String).isEmpty) return null;
    Json claims = {}, principal = {};
    try {
      final parts = (auth['access_token'] as String).split('.');
      if (parts.length == 3) {
        claims = jsonObject(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))));
        principal = jsonObject(claims['https://api.openai.com/auth'] ?? {});
      }
    } on FormatException { /* Opaque provider credentials have no JWT claims. */ }
    // A ChatGPT token can rotate without changing its account. Opaque bearer
    // credentials without account metadata must be scoped to the token itself.
    return sha256.convert(utf8.encode(jsonEncode([
      client.endpoint.toString(), auth['account_id'] ?? auth['access_token'],
      auth['user_id'] ?? principal['chatgpt_user_id'] ?? claims['sub'],
      auth['email'] ?? claims['email'], auth['plan_type'] ?? principal['chatgpt_plan_type'],
    ]))).toString();
  }

  Future<bool> _current(_CatalogOperation operation, String identity, CancellationToken token) async {
    token.throwIfCancelled();
    if (!_owns(operation)) return false;
    final current = _identity(await client.credentials().asCancellable(token));
    token.throwIfCancelled();
    if (!_owns(operation)) return false;
    if (current == identity) return true;
    _transition(const _CatalogReady(null));
    return false;
  }

  Future<void> _refresh(_CatalogOperation operation, CancellationToken caller, {String? etag}) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
    final token = lifetime.merge(caller).merge(operation.cancellation).merge(deadline);
    _CatalogSnapshot? previous;
    try {
      final auth = await client.credentials().asCancellable(token);
      token.throwIfCancelled();
      if (!_owns(operation)) return;
      final identity = _identity(auth);
      previous = _snapshot?.identity == identity ? _snapshot : null;
      _transition(_CatalogLoading(previous, operation));
      if (identity == null) { _transition(const _CatalogReady(null)); return; }

      if (etag != null && previous?.etag == etag) {
        final stored = await _readCache(token, fresh: false);
        if (!await _current(operation, identity, token)) return;
        if (stored?.identity == identity && stored?.etag == etag &&
            DateTime.now().toUtc().difference(stored!.fetchedAt) >= _cacheTtl ~/ 2) {
          await _persist(operation, stored.renew(), previous!, identity, token);
        } else { _transition(_CatalogReady(previous)); }
        return;
      }
      if (operation.strategy != CatalogRefresh.online) {
        final cached = await _readCache(token);
        if (!await _current(operation, identity, token)) return;
        if (cached?.identity == identity) { _transition(_CatalogReady(cached)); return; }
        if (operation.strategy == CatalogRefresh.offline) { _transition(_CatalogReady(previous)); return; }
      }
      // Always fetch the full response: account access can change with the same ETag.
      final response = await client.models(auth, cancellation: token);
      final next = _CatalogSnapshot.read({
        'identity': identity, 'client_version': gptCatalogClientVersion,
        'fetched_at': DateTime.now().toUtc().toIso8601String(),
        'etag': response.etag, 'models': response.body['models'],
      });
      if (!await _current(operation, identity, token)) return;
      await _persist(operation, next, next, identity, token);
    } catch (error) {
      if (_owns(operation)) _transition(_CatalogFailed(previous, error));
      caller.throwIfCancelled();
      lifetime.throwIfCancelled();
      // Network, timeout, malformed metadata and storage failures retain the
      // current identity's last successful in-process catalog and freshness.
    } finally {
      deadline.cancel();
      operation.cancellation.cancel();
    }
  }

  Future<_CatalogSnapshot?> _readCache(CancellationToken token, {bool fresh = true}) async {
    try {
      final saved = _CatalogSnapshot.read(jsonObject(jsonDecode(await _file.readAsString().asCancellable(token))));
      if (fresh && DateTime.now().toUtc().difference(saved.fetchedAt) > _cacheTtl) return null;
      return saved;
    } on CancelledException { rethrow; }
    catch (_) { token.throwIfCancelled(); return null; }
  }

  Future<void> _persist(_CatalogOperation operation, _CatalogSnapshot stored, _CatalogSnapshot published,
    String identity, CancellationToken token) async {
    _transition(_CatalogWriting(_snapshot, stored, operation));
    final temporary = File('${_file.path}.${newId()}.tmp');
    Object? failure;
    try {
      await _file.parent.create(recursive: true);
      token.throwIfCancelled();
      await temporary.writeAsString(jsonEncode(stored.toJson()), flush: true);
      if (!await _current(operation, identity, token)) return;
      await temporary.rename(_file.path);
    } catch (error) { failure = error; }
    finally { if (await temporary.exists()) await temporary.delete(); }
    if (!await _current(operation, identity, token)) return;
    // Remote metadata remains usable when persistence fails; success is only
    // acknowledged after the atomic rename has committed the disk snapshot.
    _transition(failure == null ? _CatalogReady(published) : _CatalogFailed(published, failure));
  }
}

class _CatalogSnapshot {
  _CatalogSnapshot(this.identity, this.fetchedAt, this.etag, this.models);
  final String identity;
  final DateTime fetchedAt;
  final String? etag;
  final Map<String, Json> models;

  factory _CatalogSnapshot.read(Json saved) {
    if (saved['client_version'] != gptCatalogClientVersion) throw const FormatException('Model catalog version mismatch');
    final models = <String, Json>{};
    for (final raw in saved['models'] as List) {
      final data = jsonObject(raw), id = requiredString(jsonObject(raw), 'slug');
      final model = GptModel(id, metadata: data);
      if (models.containsKey(id) || model.instructions.isEmpty || model.contextWindow < 1 ||
          !model.reasoningLevels.contains(model.defaultReasoning) || data['priority'] is! int ||
          !{'list', 'hide'}.contains(data['visibility'])) {
        throw const FormatException('Invalid model metadata');
      }
      models[id] = data;
    }
    return _CatalogSnapshot(requiredString(saved, 'identity'), DateTime.parse(requiredString(saved, 'fetched_at')),
      saved['etag'] as String?, Map.unmodifiable(models));
  }
  _CatalogSnapshot renew() => _CatalogSnapshot(identity, DateTime.now().toUtc(), etag, models);
  Json toJson() => {'identity': identity, 'client_version': gptCatalogClientVersion,
    'fetched_at': fetchedAt.toIso8601String(), 'etag': etag, 'models': models.values.toList()};
}
