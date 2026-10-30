import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

const _clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
const _issuer = 'https://auth.openai.com';
const _redirect = 'http://localhost:1455/auth/callback';

String defaultDataDirectory() {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  return Platform.environment['AGENT_DATA_DIR'] ??
      '$home/.local/share/agent-server';
}

/// Owned by the server isolate: all agents share a single refresh operation.
class AuthManager {
  AuthManager(this.directory, {HttpClient? http})
    : _http = http ?? HttpClient(),
      _ownsHttp = http == null;
  final String directory;
  Future<Json>? _refreshing;
  final HttpClient _http;
  final bool _ownsHttp;
  final _lifetime = CancellationToken();
  File get _file => File('$directory/auth.json');

  /// Local credential state only; never refreshes or returns credential values.
  Future<String> status() async {
    _lifetime.throwIfCancelled();
    try {
      if (!await _file.exists()) return 'signed_out';
      if ((await _file.stat()).size > 64 * 1024) return 'invalid';
      final value = jsonObject(jsonDecode(await _file.readAsString()));
      _lifetime.throwIfCancelled();
      if (value['type'] == 'codex_reference') {
        final source = File(requiredString(value, 'path'));
        if ((await source.stat()).size > 64 * 1024) return 'invalid';
        final saved = jsonObject(jsonDecode(await source.readAsString()));
        final access = requiredString(
          jsonObject(saved['tokens']),
          'access_token',
        );
        final expires = (_claims(access)['exp'] as num?)?.toInt() ?? 0;
        return expires > DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30
            ? 'signed_in'
            : 'expired';
      }
      if (value['type'] != 'chatgpt') return 'invalid';
      requiredString(value, 'access_token');
      requiredString(value, 'account_id');
      if ((value['expires_at'] as num? ?? 0) >
          DateTime.now().millisecondsSinceEpoch + 60000) {
        return 'signed_in';
      }
      return (value['refresh_token'] as String? ?? '').isNotEmpty
          ? 'refresh_required'
          : 'expired';
    } on CancelledException {
      rethrow;
    } catch (_) {
      return 'invalid';
    }
  }

  Future<Json> credentials({bool refresh = false}) {
    return _refreshing ??= _credentials(refresh)
        .whenComplete(() => _refreshing = null);
  }

  Future<Json> _credentials(bool forceRefresh) async {
    _lifetime.throwIfCancelled();
    if (!await _file.exists()) {
      throw StateError(
        'Not signed in. Run "agent login" or "agent login --from-codex".',
      );
    }
    var value = jsonObject(jsonDecode(await _file.readAsString()));
    if (value['type'] == 'codex_reference') {
      final source = jsonObject(
        jsonDecode(await File(requiredString(value, 'path')).readAsString()),
      );
      final tokens = jsonObject(source['tokens']);
      final access = requiredString(tokens, 'access_token');
      final claims = _claims(access);
      final expires = (claims['exp'] as num?)?.toInt() ?? 0;
      if (expires <= DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30) {
        throw StateError(
          'The referenced Codex login expired. Refresh it with Codex, or run "agent login" for an independent login.',
        );
      }
      return {
        'access_token': access,
        'account_id': tokens['account_id'] ?? _accountId(access),
      };
    }
    if (forceRefresh ||
        (value['expires_at'] as num? ?? 0) <
            DateTime.now().millisecondsSinceEpoch + 60000) {
      final response = await _post(
        '/oauth/token',
        {
          'grant_type': 'refresh_token',
          'client_id': _clientId,
          'refresh_token': requiredString(value, 'refresh_token'),
        },
        form: true,
        cancellation: _lifetime,
      );
      _lifetime.throwIfCancelled();
      value = _token(response, oldRefresh: value['refresh_token'] as String?);
      await _save(value);
    }
    return {
      'access_token': requiredString(value, 'access_token'),
      'account_id': requiredString(value, 'account_id'),
    };
  }

  Future<void> useCodex([String? path]) async {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final codexDirectory = Platform.environment['CODEX_HOME'] ?? '$home/.codex';
    final source = File(path ?? '$codexDirectory/auth.json').absolute;
    final data = jsonObject(jsonDecode(await source.readAsString()));
    final tokens = jsonObject(data['tokens']);
    requiredString(tokens, 'access_token');
    await _save({'type': 'codex_reference', 'path': source.path});
  }

  Future<void> login({
    bool device = false,
    required void Function(String url, String message) notify,
    CancellationToken? cancellation,
  }) async {
    final cancel = cancellation == null
        ? _lifetime
        : cancellation.merge(_lifetime);
    cancel.throwIfCancelled();
    if (device) {
      final info = await _post('/api/accounts/deviceauth/usercode', {
        'client_id': _clientId,
      }, cancellation: cancel);
      notify(
        '$_issuer/codex/device',
        'Enter code: ${requiredString(info, 'user_code')}',
      );
      var interval = int.tryParse(info['interval'].toString()) ?? 5;
      interval = interval.clamp(1, 30);
      final deadline = DateTime.now().add(const Duration(minutes: 15));
      while (DateTime.now().isBefore(deadline)) {
        await cancellableDelay(Duration(seconds: interval), cancel);
        final result = await _request('/api/accounts/deviceauth/token', {
          'device_auth_id': requiredString(info, 'device_auth_id'),
          'user_code': requiredString(info, 'user_code'),
        }, cancellation: cancel);
        if (result.$1 == 200) {
          await _exchange(
            requiredString(result.$2, 'authorization_code'),
            requiredString(result.$2, 'code_verifier'),
            '$_issuer/deviceauth/callback',
            cancel,
          );
          return;
        }
        final error = result.$2['error'];
        final code = error is Map ? error['code'] : error;
        if (code == 'slow_down') {
          interval += 5;
        } else if (result.$1 != 403 &&
            result.$1 != 404 &&
            code != 'deviceauth_authorization_pending') {
          throw StateError('Device login failed (HTTP ${result.$1}).');
        }
      }
      throw TimeoutException('Device login expired');
    }

    final verifier = _random();
    final state = _random();
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 1455);
    final result = Completer<String>();
    final hook = CancellationHook(cancel, () {
      if (!result.isCompleted) result.completeError(const CancelledException());
    });
    server.listen((request) async {
      if (request.uri.path != '/auth/callback') {
        request.response.statusCode = 404;
      } else if (request.uri.queryParameters['state'] != state) {
        request.response.statusCode = 400;
        request.response.write('Invalid OAuth state.');
      } else if (!result.isCompleted) {
        final code = request.uri.queryParameters['code'];
        if (code == null || request.uri.queryParameters.containsKey('error')) {
          result.completeError(StateError('ChatGPT login was declined.'));
          request.response.write('Login was declined.');
        } else {
          result.complete(code);
          request.response.write(
            'Authorization received. You can return to the terminal.',
          );
        }
      }
      await request.response.close();
    });
    final url = Uri.parse('$_issuer/oauth/authorize').replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': _clientId,
        'redirect_uri': _redirect,
        'scope': 'openid profile email offline_access',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'id_token_add_organizations': 'true',
        'codex_cli_simplified_flow': 'true',
        'originator': 'agent',
      },
    );
    try {
      notify(url.toString(), 'Complete ChatGPT login in your browser.');
      final code = await result.future.timeout(const Duration(minutes: 5));
      cancel.throwIfCancelled();
      await _exchange(code, verifier, _redirect, cancel);
    } finally {
      hook.dispose();
      await server.close(force: true);
    }
  }

  Future<void> _exchange(
    String code,
    String verifier,
    String redirect,
    CancellationToken cancellation,
  ) async {
    final response = await _post(
      '/oauth/token',
      {
        'grant_type': 'authorization_code',
        'client_id': _clientId,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirect,
      },
      form: true,
      cancellation: cancellation,
    );
    cancellation.throwIfCancelled();
    await _save(_token(response));
  }

  Json _token(Json response, {String? oldRefresh}) {
    final access = requiredString(response, 'access_token');
    final refresh = response['refresh_token'] as String? ?? oldRefresh;
    if (refresh == null || refresh.isEmpty) {
      throw const FormatException('Missing refresh token');
    }
    return {
      'type': 'chatgpt',
      'access_token': access,
      'refresh_token': refresh,
      'account_id': _accountId(access),
      'expires_at':
          DateTime.now().millisecondsSinceEpoch +
          ((response['expires_in'] as num? ?? 3600) * 1000).toInt(),
    };
  }

  Future<Json> _post(
    String path,
    Json body, {
    bool form = false,
    required CancellationToken cancellation,
  }) async {
    final result = await _request(
      path,
      body,
      form: form,
      cancellation: cancellation,
    );
    if (result.$1 != 200) {
      throw StateError('ChatGPT authentication failed (HTTP ${result.$1}).');
    }
    return result.$2;
  }

  Future<(int, Json)> _request(
    String path,
    Json body, {
    bool form = false,
    required CancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    HttpClientRequest? request;
    final hook = CancellationHook(
      cancellation,
      () => request?.abort(cancellation.exception),
    );
    try {
      request = await _http
          .postUrl(Uri.parse('$_issuer$path'))
          .then((value) {
            if (cancellation.isCancelled) value.abort(cancellation.exception);
            return value;
          })
          .asCancellable(cancellation);
      cancellation.throwIfCancelled();
      request.headers.contentType = ContentType(
        'application',
        form ? 'x-www-form-urlencoded' : 'json',
      );
      request.write(
        form
            ? Uri(
                queryParameters: body.map((k, v) => MapEntry(k, v.toString())),
              ).query
            : jsonEncode(body),
      );
      final response = await request
          .close()
          .timeout(const Duration(seconds: 30))
          .asCancellable(cancellation);
      final iterator = StreamIterator(
        response.timeout(const Duration(seconds: 30)),
      );
      final bytes = <int>[];
      try {
        while (await iterator.moveNext().asCancellable(
          cancellation,
          onCancel: () => unawaited(iterator.cancel()),
        )) {
          if (bytes.length + iterator.current.length > 1024 * 1024) {
            throw const FormatException('Authentication response too large');
          }
          bytes.addAll(iterator.current);
        }
      } finally {
        await iterator.cancel();
      }
      Json data = {};
      try {
        data = jsonObject(jsonDecode(utf8.decode(bytes)));
      } on FormatException {
        // Report only HTTP status, never token-bearing response bodies.
      }
      return (response.statusCode, data);
    } catch (_) {
      cancellation.throwIfCancelled();
      rethrow;
    } finally {
      hook.dispose();
      request?.abort();
    }
  }

  Future<void> _save(Json value) async {
    await Directory(directory).create(recursive: true);
    if (!Platform.isWindows) await Process.run('chmod', ['700', directory]);
    final temporary = File('$directory/.auth-${newId()}');
    await temporary.create();
    try {
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', temporary.path]);
      }
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(_file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void close() {
    _lifetime.cancel();
    if (_ownsHttp) _http.close(force: true);
  }
}

String _random() {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

Json _claims(String token) {
  final parts = token.split('.');
  if (parts.length != 3) throw const FormatException('Invalid access token');
  return jsonObject(
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))),
  );
}

String _accountId(String access) {
  final claims = _claims(access);
  return requiredString(
    jsonObject(claims['https://api.openai.com/auth']),
    'chatgpt_account_id',
  );
}
