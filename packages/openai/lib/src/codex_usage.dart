import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai/ai.dart' show ModelFailure, httpRequest;
import 'package:protocol/protocol.dart';

import '../auth.dart' show openAICredentialScope;
import 'responses.dart' show Credentials;

/// Account-level usage for ChatGPT OAuth. The network worker owns the client.
class CodexUsageClient {
  CodexUsageClient(this._http, this._credentials);
  final HttpClient _http;
  final Credentials _credentials;

  static final _base = Uri.parse('https://chatgpt.com/backend-api/wham/');
  static const _resets = 'rate-limit-reset-credits';

  static bool supports(Uri responses) => responses.scheme == 'https' && responses.host.isNotEmpty &&
    responses.origin == _base.origin &&
    responses.path == '/backend-api/codex/responses';

  Future<Json> read({required CancellationToken cancellation}) => _authorized(cancellation, (auth, token) async {
    final (usage, details) = await (
      _request('usage', auth, cancellation: token),
      _readResets(auth, token),
    ).wait;
    return {
      'account_scope': openAICredentialScope(_base, auth),
      'plan_type': usage['plan_type'] ?? auth['plan_type'],
      for (final key in ['rate_limit', 'credits', 'rate_limit_reset_credits'])
        if (usage.containsKey(key)) key: usage[key],
      'reset_details': ?details,
    };
  });

  Future<Json?> _readResets(Json auth, CancellationToken cancellation) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
    try {
      final data = await _request(_resets, auth, cancellation: cancellation.merge(deadline));
      final credits = data['credits'];
      if (credits is! List) return null;
      return {'available_count': data['available_count'], 'credits': [
        for (final credit in credits)
          if (credit case {'id': final String id, 'status': 'available'} when id.isNotEmpty)
            {'id': id, 'title': credit['title'], 'description': credit['description'], 'expires_at': credit['expires_at']},
      ]};
    } catch (_) {
      cancellation.throwIfCancelled();
      // The usage response can still supply limits, balance, and a reset count.
      return null;
    } finally { deadline.cancel(); }
  }

  Future<Json> redeem(String scope, String? creditId, String requestId, {required CancellationToken cancellation}) =>
    _authorized(cancellation, (auth, token) async {
      // A picker can outlive an account switch on the machine handling it.
      if (scope != openAICredentialScope(_base, auth)) return {'code': 'account_changed'};
      final reply = await _request('$_resets/consume', auth, body: {
        'credit_id': ?creditId, 'redeem_request_id': requestId,
      }, cancellation: token);
      return {'code': reply['code']};
    });

  Future<Json> _authorized(CancellationToken cancellation, Future<Json> Function(Json, CancellationToken) operation) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 12));
    final token = cancellation.merge(deadline);
    try {
      token.throwIfCancelled();
      final auth = await _credentials(refresh: false).asCancellable(token);
      return await operation(auth, token);
    } finally { deadline.cancel(); }
  }

  Future<Json> _request(String path, Json initialAuth, {Json? body, required CancellationToken cancellation}) async {
    final bytes = body == null ? const <int>[] : utf8.encode(jsonEncode(body));
    for (var refresh = false; ; refresh = true) {
      cancellation.throwIfCancelled();
      final auth = refresh ? await _credentials(refresh: true).asCancellable(cancellation) : initialAuth;
      if (refresh && openAICredentialScope(_base, initialAuth) != openAICredentialScope(_base, auth)) {
        throw StateError('The ChatGPT account changed');
      }
      final id = requiredString(auth, 'account_id'), access = requiredString(auth, 'access_token');
      final response = await httpRequest(_http, body == null ? 'GET' : 'POST', _base.resolve(path),
        cancellation: cancellation, body: bytes, headers: {
          'authorization': 'Bearer $access', 'chatgpt-account-id': id,
          'originator': 'agent', 'accept': 'application/json',
          if (body != null) 'content-type': 'application/json',
        });
      final incoming = ownStream(response, cancellation);
      try {
        if (response.statusCode == 401 && !refresh) continue;
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw ModelFailure('codex_usage_http', 'ChatGPT usage request failed (HTTP ${response.statusCode})');
        }
        final reply = BytesBuilder(copy: false);
        await for (final chunk in incoming.stream) {
          if (reply.length + chunk.length > 1024 * 1024) throw const FormatException('ChatGPT usage response exceeds 1 MiB');
          reply.add(chunk);
        }
        cancellation.throwIfCancelled();
        return jsonObject(jsonDecode(utf8.decode(reply.takeBytes())));
      } finally { await incoming.close(); }
    }
  }
}
