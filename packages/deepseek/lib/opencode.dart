import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

const _clientId = 'opencode-cli';

/// Owns one Console login and its coalesced refresh operation.
/// Browser authorization is completed at the URL delivered to [login].
class OpenCodeAuthManager {
  OpenCodeAuthManager(this.directory, {HttpClient? http, Uri? endpoint})
    : _http =
          http ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 30)),
      _ownsHttp = http == null,
      endpoint = _server(endpoint);

  final String directory;
  final Uri endpoint;
  final HttpClient _http;
  final bool _ownsHttp;
  final _lifetime = CancellationToken();
  Future<Json>? _refreshing;
  Future<void>? _loggingIn;
  File get _file => File('$directory/opencode-auth.json');

  Future<void> login({
    required void Function(String url, String code) notify,
    required CancellationToken cancellation,
  }) {
    _lifetime.throwIfCancelled();
    cancellation.throwIfCancelled();
    if (_loggingIn != null || _refreshing != null) {
      return Future.error(
        StateError('OpenCode authentication is already active'),
      );
    }
    return _loggingIn = _login(
      notify,
      cancellation.merge(_lifetime),
    ).whenComplete(() => _loggingIn = null);
  }

  Future<void> _login(
    void Function(String, String) notify,
    CancellationToken cancellation,
  ) async {
    final device = _object(
      await _json(
        'POST',
        '/auth/device/code',
        cancellation,
        body: {'client_id': _clientId, 'supports_org_scope': true},
      ),
    );
    final deviceCode = _required(device, 'device_code');
    final userCode = _required(device, 'user_code');
    final verification = endpoint
        .resolve('${endpoint.path}/')
        .resolve(_required(device, 'verification_uri_complete'));
    if (!{'http', 'https'}.contains(verification.scheme) ||
        verification.host.isEmpty ||
        verification.userInfo.isNotEmpty) {
      throw StateError('OpenCode returned an invalid verification URL');
    }
    var interval = _seconds(device['interval']);
    final deadline = TimeoutCancellationToken(
      _seconds(device['expires_in']),
      timeoutException: TimeoutException(
        'OpenCode device authorization expired',
      ),
    );
    final operation = cancellation.merge(deadline);
    try {
      operation.throwIfCancelled();
      notify(verification.toString(), userCode);
      while (true) {
        await cancellableDelay(interval, operation);
        final (status, raw) = await _request(
          'POST',
          '/auth/device/token',
          operation,
          body: {
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            'device_code': deviceCode,
            'client_id': _clientId,
          },
        );
        final token = _object(raw);
        if (status == 200 && token['access_token'] != null) {
          final value = _token(token);
          final access = _required(value, 'access_token');
          final identity = await Future.wait([
            _json('GET', '/api/user', operation, access: access),
            _json('GET', '/api/orgs', operation, access: access),
          ]);
          final user = _object(identity[0]);
          _required(user, 'id');
          _required(user, 'email');
          if (identity[1] is! List) {
            throw StateError('OpenCode returned invalid organizations');
          }
          final orgs = (identity[1] as List).map(_object).toList();
          for (final org in orgs) {
            _required(org, 'id');
            _required(org, 'name');
          }
          final selected = value['org_id'];
          if (selected != null) {
            if (!orgs.any((org) => org['id'] == selected)) {
              throw StateError(
                'The selected OpenCode organization is unavailable; sign in again',
              );
            }
          } else if (orgs.length == 1) {
            value['org_id'] = orgs.single['id'];
          } else {
            throw StateError(
              'Select an organization during OpenCode authorization and sign in again',
            );
          }
          await _save(value, operation);
          return;
        }
        if (token['error'] == 'authorization_pending' &&
            (status == 200 || status == 400)) {
          continue;
        }
        if (token['error'] == 'slow_down' && (status == 200 || status == 400)) {
          interval += const Duration(seconds: 5);
          continue;
        }
        throw StateError('OpenCode device authorization failed (HTTP $status)');
      }
    } finally {
      deadline.cancel();
    }
  }

  /// Returns only the access token and selected organization, never the refresh token.
  Future<Json> credentials({bool refresh = false}) {
    _lifetime.throwIfCancelled();
    return _refreshing ??= _credentials(refresh)
        .whenComplete(() => _refreshing = null);
  }

  Future<Json> _credentials(bool refresh) async {
    await _loggingIn;
    _lifetime.throwIfCancelled();
    if (!await _file.exists()) {
      throw StateError('Not signed in to OpenCode Console');
    }
    _lifetime.throwIfCancelled();
    if ((await _file.stat()).size > 64 * 1024) {
      throw StateError('Invalid saved OpenCode login');
    }
    _lifetime.throwIfCancelled();
    Json value;
    try {
      value = _object(jsonDecode(await _file.readAsString()));
    } on FormatException {
      throw StateError('Invalid saved OpenCode login');
    }
    _lifetime.throwIfCancelled();
    if (value['version'] != 1 ||
        value['type'] != 'opencode' ||
        value['server'] != endpoint.toString()) {
      throw StateError(
        'Saved OpenCode login belongs to a different Console; sign in again',
      );
    }
    final org = _required(value, 'org_id');
    final expires = value['expires_at'];
    if (expires is! int || expires <= 0) {
      throw StateError('Invalid saved OpenCode login');
    }
    if (refresh || expires <= DateTime.now().millisecondsSinceEpoch + 60000) {
      final (status, response) = await _request(
        'POST',
        '/auth/device/token',
        _lifetime,
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': _required(value, 'refresh_token'),
          'client_id': _clientId,
        },
      );
      if (status != 200) {
        throw StateError(
          'OpenCode Console login could not be refreshed; sign in again (HTTP $status)',
        );
      }
      value = _token(_object(response));
      if (value['org_id'] != null && value['org_id'] != org) {
        throw StateError(
          'OpenCode organization changed during refresh; sign in again',
        );
      }
      value['org_id'] = org;
      await _save(value, _lifetime);
    }
    _lifetime.throwIfCancelled();
    return {'access_token': _required(value, 'access_token'), 'org_id': org};
  }

  Json _token(Json response) => {
    'version': 1,
    'type': 'opencode',
    'server': endpoint.toString(),
    'access_token': _required(response, 'access_token'),
    'refresh_token': _required(response, 'refresh_token'),
    'expires_at':
        DateTime.now().millisecondsSinceEpoch +
        _seconds(response['expires_in']).inMilliseconds,
    if (response['org_id'] != null) 'org_id': _required(response, 'org_id'),
  };

  Future<Object?> _json(
    String method,
    String path,
    CancellationToken cancellation, {
    Json? body,
    String? access,
  }) async {
    final (status, response) = await _request(
      method,
      path,
      cancellation,
      body: body,
      access: access,
    );
    if (status < 200 || status >= 300) {
      throw StateError('OpenCode authentication failed (HTTP $status)');
    }
    return response;
  }

  Future<(int, Object?)> _request(
    String method,
    String path,
    CancellationToken cancellation, {
    Json? body,
    String? access,
  }) async {
    cancellation.throwIfCancelled();
    HttpClientRequest? request;
    Future<void> Function()? closeBody;
    final hook = CancellationHook(
      cancellation,
      () => request?.abort(cancellation.exception),
    );
    try {
      request = await _http
          .openUrl(method, endpoint.replace(path: '${endpoint.path}$path'))
          .then((request) {
            if (cancellation.isCancelled) request.abort(cancellation.exception);
            return request;
          })
          .asCancellable(cancellation);
      cancellation.throwIfCancelled();
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(
          HttpHeaders.userAgentHeader,
          'happen/0.1.0 (Dart; OpenCode Console device login)',
        );
      if (access != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $access');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request
          .close()
          .timeout(const Duration(seconds: 30))
          .asCancellable(cancellation);
      final incoming = ownStream(response, cancellation);
      closeBody = incoming.close;
      final iterator = StreamIterator(
        incoming.stream.timeout(const Duration(seconds: 30)),
      );
      final bytes = <int>[];
      try {
        while (await iterator.moveNext().asCancellable(cancellation)) {
          if (bytes.length + iterator.current.length > 1024 * 1024) {
            throw StateError(
              'OpenCode authentication response exceeds the size limit',
            );
          }
          bytes.addAll(iterator.current);
        }
      } finally {
        await closeBody();
        unawaited(iterator.cancel().catchError((Object _) {}));
      }
      cancellation.throwIfCancelled();
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw StateError(
          'OpenCode authentication returned invalid JSON (HTTP ${response.statusCode})',
        );
      }
      return (response.statusCode, decoded);
    } catch (error) {
      cancellation.throwIfCancelled();
      if (error is StateError) rethrow;
      throw StateError('OpenCode authentication transport failed');
    } finally {
      hook.dispose();
      await closeBody?.call();
      request?.abort();
    }
  }

  Future<void> _save(Json value, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    await Directory(directory).create(recursive: true);
    await _privateMode(directory, '700', cancellation);
    final temporary = File('$directory/.opencode-auth-${newId()}');
    try {
      cancellation.throwIfCancelled();
      await temporary.create();
      await _privateMode(temporary.path, '600', cancellation);
      cancellation.throwIfCancelled();
      await temporary.writeAsString(jsonEncode(value), flush: true);
      cancellation.throwIfCancelled();
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

Uri _server(Uri? selected) {
  final uri = selected ?? Uri.parse('https://opencode.ai/console');
  if (!{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw ArgumentError(
      'Console endpoint must be an HTTP URL without credentials, query or fragment',
    );
  }
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

Json _object(Object? value) {
  if (value is! Map) {
    throw StateError('OpenCode authentication returned an invalid object');
  }
  return Map<String, dynamic>.from(value);
}

String _required(Json object, String key) {
  final value = object[key];
  if (value is! String || value.isEmpty) {
    throw StateError('OpenCode authentication is missing $key');
  }
  return value;
}

Duration _seconds(Object? value) {
  if (value is! num || !value.isFinite || value <= 0 || value > 31536000) {
    throw StateError('OpenCode authentication returned an invalid duration');
  }
  return Duration(
    microseconds: (value * Duration.microsecondsPerSecond).ceil(),
  );
}

Future<void> _privateMode(
  String path,
  String mode,
  CancellationToken cancellation,
) async {
  cancellation.throwIfCancelled();
  if (Platform.isWindows) return;
  final process = await Process.start('chmod', [mode, File(path).absolute.path])
      .then((process) {
        if (cancellation.isCancelled) process.kill();
        return process;
      })
      .asCancellable(cancellation);
  final hook = CancellationHook(cancellation, () => process.kill());
  try {
    final output = Future.wait([
      process.stdout.drain<void>(),
      process.stderr.drain<void>(),
    ]);
    final status = await process.exitCode.asCancellable(cancellation);
    await output.asCancellable(cancellation);
    cancellation.throwIfCancelled();
    if (status != 0) {
      throw StateError('Could not secure the OpenCode login file');
    }
  } finally {
    hook.dispose();
    process.kill();
  }
}
