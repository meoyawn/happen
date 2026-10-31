import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

import 'transport.dart';

bool hasAuthorizationHeader(Json config) => [
  ...jsonObject(config['headers'] ?? {}).keys,
  ...jsonObject(config['header_env'] ?? {}).keys,
].any((name) => name.toLowerCase() == 'authorization');

/// One configured resource owns its login, refresh, and private credential file.
/// Tokens never enter config snapshots, client events, or conversation history.
class McpOAuth {
  McpOAuth(this.directory, this.name, this.config, this.http);
  final String directory, name;
  final Json config;
  final HttpClient http;
  final lifetime = CancellationToken();
  Json? _credentials;
  Json _challenge = {};
  Future<void>? _loading, _loggingIn;
  Future<String?>? _refreshing;
  bool _rejected = false, _needsLogin = false;
  String? _diskStamp;
  bool Function(Uri)? _callback;
  Uri? _redirect;
  String get _url => config['url'] as String;
  String get _key => sha256.convert(utf8.encode('$name\u0000$_url')).toString();
  Directory get _directory => Directory('$directory/mcp-auth');
  File get _file => File('${_directory.path}/$_key.json');
  Json get _options => jsonObject(config['oauth'] ?? {});
  bool get authenticated => _credentials != null && !_needsLogin;
  bool get signingIn => _loggingIn != null;
  bool get canRefresh => !_needsLogin && (_credentials?['refresh_token'] as String? ?? '').isNotEmpty;

  void challenge(int status, List<String> headers, {required bool sentToken}) {
    if (status != 401 && status != 403) return;
    _challenge = _bearerChallenge(headers);
    if (sentToken) {
      _rejected = true;
      if (status == 403) _needsLogin = true;
    }
  }

  Future<String?> authorization(CancellationToken cancellation) async {
    final token = cancellation.merge(lifetime);
    token.throwIfCancelled();
    try { await (_loading ??= _load()).asCancellable(token); } on McpFailure { _needsLogin = true; return null; }
    token.throwIfCancelled();
    final saved = _credentials;
    if (saved == null || _needsLogin) return null;
    final expires = saved['expires_at'] as num?;
    if (!_rejected && (expires == null || expires > DateTime.now().millisecondsSinceEpoch + 60000)) {
      return saved['access_token'] as String;
    }
    if ((saved['refresh_token'] as String? ?? '').isEmpty) {
      _needsLogin = true;
      return null;
    }
    // Individual requests may stop waiting; the shared server owns the refresh.
    return (_refreshing ??= _refresh(saved).whenComplete(() => _refreshing = null)).asCancellable(token);
  }

  Future<void> _load() async {
    lifetime.throwIfCancelled();
    try {
      _diskStamp = await _stamp();
      if (await FileSystemEntity.type(_file.path, followLinks: false) == FileSystemEntityType.notFound) return;
      if (await FileSystemEntity.type(_file.path, followLinks: false) != FileSystemEntityType.file ||
          (await _file.stat()).size > 65536) {
        throw const McpFailure('MCP credential file is invalid; sign in again');
      }
      final saved = jsonObject(jsonDecode(await _file.readAsString()));
      lifetime.throwIfCancelled();
      if (saved['server_url'] != _url || saved['server_name'] != name ||
          saved['access_token'] is! String || (saved['access_token'] as String).trim().isEmpty ||
          RegExp(r'[\r\n]').hasMatch(saved['access_token'] as String) ||
          saved['client_id'] is! String || (saved['client_id'] as String).trim().isEmpty ||
          saved['expires_at'] != null && saved['expires_at'] is! num ||
          saved['refresh_token'] != null && saved['refresh_token'] is! String ||
          _options['client_id'] != null && _options['client_id'] != saved['client_id']) {
        throw const McpFailure('MCP credentials do not match this server; sign in again');
      }
      _credentials = saved;
    } on CancelledException {
      rethrow;
    } on McpFailure {
      rethrow;
    } catch (_) {
      throw const McpFailure('Unable to read MCP credentials; sign in again');
    }
  }

  Future<String?> _refresh(Json saved) => _withCredentialLock(lifetime, () async {
    try {
      // A different process may already have rotated this credential while
      // this owner waited for the file lock. Never refresh the stale copy.
      _credentials = null;
      await _load();
      final current = _credentials;
      if (current == null) { _needsLogin = true; return null; }
      if (current['refresh_token'] != saved['refresh_token'] &&
          (current['expires_at'] == null || current['expires_at'] > DateTime.now().millisecondsSinceEpoch + 60000)) {
        _rejected = false;
        return current['access_token'] as String;
      }
      saved = current;
      final info = await _discover(lifetime);
      if (saved['issuer'] == null || saved['issuer'] != info.metadata['issuer'] || saved['resource'] != info.resource) {
        _needsLogin = true;
        throw const McpFailure('MCP authorization server changed; sign in again', status: 401);
      }
      final response = await _exchange(info.metadata, saved, {
        'grant_type': 'refresh_token', 'refresh_token': saved['refresh_token'] as String,
        'resource': info.resource,
      }, lifetime);
      final next = _tokens(response, saved);
      await _save(next, lifetime);
      _credentials = next;
      _rejected = false;
      return next['access_token'] as String;
    } on CancelledException {
      rethrow;
    } on McpFailure catch (error) {
      if (error.status == 401) _needsLogin = true;
      rethrow;
    } catch (_) {
      throw const McpFailure('Unable to refresh MCP sign-in');
    }
  });

  Future<void> login(CancellationToken cancellation, void Function(String url) notify) {
    if (_loggingIn != null) throw const McpFailure('An MCP sign-in is already in progress');
    return _loggingIn = _login(cancellation.merge(lifetime), notify).whenComplete(() => _loggingIn = null);
  }

  Future<void> _login(CancellationToken token, void Function(String url) notify) async {
    HttpServer? listener;
    StreamSubscription<HttpRequest>? subscription;
    try {
      token.throwIfCancelled();
      try { await (_loading ??= _load()).asCancellable(token); } on McpFailure { _credentials = null; }
      await _refreshing?.asCancellable(token);
      final info = await _discover(token);
      final metadata = info.metadata;
      final issuerBound = metadata['authorization_response_iss_parameter_supported'] == true;
      final callbackId = base64Url.encode(sha256.convert(utf8.encode(_url)).bytes.take(9).toList()).replaceAll('=', '');
      final path = issuerBound ? '/callback' : '/callback/$callbackId';
      listener = await HttpServer.bind(InternetAddress.loopbackIPv4, _options['callback_port'] as int? ?? 0);
      token.throwIfCancelled();
      final redirect = 'http://127.0.0.1:${listener.port}$path';
      final configuredScopes = (_options['scopes'] as List?)?.cast<String>();
      final scopes = <String>{
        ...?(_credentials?['scope'] as String?)?.split(' ').where((s) => s.isNotEmpty),
        ...?configuredScopes,
        if (_challenge['scope'] is String) ...(_challenge['scope'] as String).split(' ').where((s) => s.isNotEmpty)
        else if (configuredScopes == null) ...info.scopes,
        if ((metadata['scopes_supported'] as List? ?? []).contains('offline_access')) 'offline_access',
      };
      if (scopes.any((scope) => !RegExp(r'^[\x21\x23-\x5b\x5d-\x7e]+$').hasMatch(scope))) {
        throw const McpFailure('MCP authorization scopes are invalid');
      }
      Json client;
      if (_options['client_id'] is String) {
        client = {'client_id': _options['client_id'],
          'token_endpoint_auth_method': _options['token_endpoint_auth_method'] ??
            (_options['client_secret_env'] == null ? 'none' : 'client_secret_post')};
      } else {
        final registration = metadata['registration_endpoint'];
        if (registration is! String) {
          throw const McpFailure('This MCP server requires a pre-registered OAuth client ID');
        }
        final response = await _request('POST', _webUri(registration), token, body: {
          'client_name': 'Happen', 'redirect_uris': [redirect],
          'grant_types': ['authorization_code', 'refresh_token'], 'response_types': ['code'],
          'token_endpoint_auth_method': 'none',
        });
        if (response.status < 200 || response.status >= 300 ||
            response.body['client_id'] is! String || (response.body['client_id'] as String).trim().isEmpty) {
          throw const McpFailure('MCP OAuth client registration failed');
        }
        client = {
          'client_id': response.body['client_id'],
          'client_secret': ?response.body['client_secret'],
          'token_endpoint_auth_method': response.body['token_endpoint_auth_method'] ?? 'none',
        };
      }
      final state = _random(), verifier = _random();
      final authorization = _webUri(metadata['authorization_endpoint'] as String);
      final url = authorization.replace(queryParameters: {
        ...authorization.queryParameters,
        'response_type': 'code', 'client_id': client['client_id'] as String,
        'redirect_uri': redirect, 'state': state,
        'code_challenge': base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', ''),
        'code_challenge_method': 'S256', 'resource': info.resource,
        if (scopes.isNotEmpty) 'scope': scopes.join(' '),
      });
      final result = CancellableCompleter<String>(token);
      // Own completion before handing the browser URL to an asynchronous client.
      unawaited(result.future.then<void>((_) {}, onError: (Object _) {}));
      var received = false;
      _redirect = Uri.parse(redirect);
      _callback = (uri) {
        final query = uri.queryParametersAll;
        if (received || token.isCancelled || query['state']?.length != 1 || query['state']!.single != state) {
          throw const McpFailure('Invalid or expired MCP sign-in callback');
        }
        received = true;
        final issuer = query['iss'];
        if (issuer != null && (issuer.length != 1 || issuer.single != metadata['issuer']) || issuerBound && issuer == null) {
          result.completeError(const McpFailure('MCP sign-in issuer did not match; try again'));
          return false;
        } else if (query.containsKey('error')) {
          result.completeError(const McpFailure('MCP sign-in was declined'));
          return false;
        } else if (query['code']?.length != 1 || query['code']!.single.isEmpty) {
          result.completeError(const McpFailure('MCP sign-in callback did not contain a code'));
          return false;
        } else {
          result.complete(query['code']!.single);
          return true;
        }
      };
      subscription = listener.listen((request) async {
        if (request.method != 'GET' || request.uri.path != path) {
          request.response.statusCode = 404;
        } else {
          var accepted = false;
          try { accepted = _callback!(request.uri); } on McpFailure { /* Keep waiting after unrelated callbacks. */ }
          request.response.statusCode = accepted ? 200 : 400;
          request.response.headers.contentType = ContentType.html;
          request.response.headers.set('Cache-Control', 'no-store');
          request.response.headers.set('Referrer-Policy', 'no-referrer');
          request.response.write(accepted
            ? '<!doctype html><title>Happen</title><p>Authorization received. You can return to Happen.</p>'
            : '<!doctype html><title>Happen</title><p>Sign-in failed. Return to Happen and try again.</p>');
        }
        try {
          await request.response.close();
        } on HttpException { /* A closed browser tab does not discard the callback. */
        } on SocketException { /* The callback is already validated. */ }
      }, onError: (Object _) {
        if (!result.isCompleted) result.completeError(const McpFailure('MCP callback listener failed'));
      });
      token.throwIfCancelled();
      notify(url.toString());
      final code = await result.future;
      token.throwIfCancelled();
      await _withCredentialLock(token, () async {
        final response = await _exchange(metadata, client, {
          'grant_type': 'authorization_code', 'code': code,
          'code_verifier': verifier, 'redirect_uri': redirect, 'resource': info.resource,
        }, token);
        final saved = _tokens(response, {
          ...client, 'issuer': metadata['issuer'], 'resource': info.resource, 'scope': scopes.join(' '),
        });
        await _save(saved, token);
        _credentials = saved;
        _rejected = _needsLogin = false;
      });
    } on CancelledException {
      rethrow;
    } on McpFailure {
      rethrow;
    } catch (_) {
      throw const McpFailure('Unable to sign in to this MCP server');
    } finally {
      _callback = null;
      _redirect = null;
      await listener?.close(force: true);
      await subscription?.cancel();
    }
  }

  void completeLogin(String value) {
    final uri = value.length <= 16384 ? Uri.tryParse(value) : null;
    if (uri == null || _redirect == null || _callback == null || uri.userInfo.isNotEmpty || uri.hasFragment ||
        uri.scheme != _redirect!.scheme || uri.host != _redirect!.host || uri.port != _redirect!.port || uri.path != _redirect!.path) {
      throw const McpFailure('Paste the complete callback URL from this sign-in');
    }
    _callback!(uri);
  }

  Future<String?> _stamp() async {
    final stat = await _file.stat();
    return stat.type == FileSystemEntityType.notFound ? null : '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
  }

  Future<bool> credentialsChanged() async => !signingIn && _loading != null && await _stamp() != _diskStamp;

  Future<({Json metadata, String resource, List<String> scopes})> _discover(CancellationToken token) async {
    final resourceUri = _webUri(_url);
    // Discovery is deliberately unauthenticated. Resource-only headers never
    // travel to a separate authorization server or metadata origin.
    final probe = await _request('POST', resourceUri, token, resourceHeaders: true, body: {
      'jsonrpc': '2.0', 'id': newId(), 'method': 'server/discover', 'params': {},
    });
    if (probe.status == 401 || probe.status == 403) {
      final next = _bearerChallenge(probe.headers['www-authenticate'] ?? []);
      if (next.isNotEmpty) _challenge = next;
    }
    final candidates = <Uri>{
      if (_challenge['resource_metadata'] is String) _webUri(_challenge['resource_metadata'] as String),
      resourceUri.replace(path: '/.well-known/oauth-protected-resource${resourceUri.path == '/' ? '' : resourceUri.path}', query: ''),
      resourceUri.replace(path: '/.well-known/oauth-protected-resource', query: ''),
    };
    Json? resource;
    for (final uri in candidates) {
      final response = await _request('GET', uri, token);
      if (response.status == 200) { resource = response.body; break; }
      if (response.status != 404 && response.status != 405) {
        throw const McpFailure('Unable to discover MCP authorization metadata');
      }
    }
    final canonical = resource?['resource'] as String? ?? resourceUri.toString();
    final canonicalUri = _webUri(canonical);
    if (canonicalUri.origin != resourceUri.origin || canonicalUri.hasQuery ||
        resourceUri.path != canonicalUri.path &&
          !resourceUri.path.startsWith('${canonicalUri.path.replaceFirst(RegExp(r'/$'), '')}/')) {
      throw const McpFailure('MCP authorization metadata describes a different resource');
    }
    final issuers = resource?['authorization_servers'] as List?;
    if (resource != null && (issuers == null || issuers.isEmpty)) {
      throw const McpFailure('MCP resource metadata has no authorization server');
    }
    final issuer = issuers == null ? resourceUri.origin : issuers.first as String;
    final base = _webUri(issuer);
    if (base.hasQuery) throw const McpFailure('MCP authorization issuer is invalid');
    final issuerPath = base.path == '/' ? '' : base.path;
    Json? metadata;
    for (final uri in <Uri>{
      base.replace(path: '/.well-known/oauth-authorization-server$issuerPath'),
      base.replace(path: '/.well-known/openid-configuration$issuerPath'),
      base.replace(path: '$issuerPath/.well-known/openid-configuration'),
    }) {
      final response = await _request('GET', uri, token);
      if (response.status == 200) { metadata = response.body; break; }
      if (response.status != 404 && response.status != 405 && response.status != 503) {
        throw const McpFailure('Unable to discover MCP authorization server');
      }
    }
    if (metadata == null || metadata['issuer'] != issuer) {
      throw const McpFailure('MCP authorization metadata issuer did not match');
    }
    final authorization = _webUri(requiredString(metadata, 'authorization_endpoint'));
    final endpoint = _webUri(requiredString(metadata, 'token_endpoint'));
    if (metadata['registration_endpoint'] case final String registration) _webUri(registration);
    if (metadata['authorization_response_iss_parameter_supported'] != true &&
        authorization.origin != base.origin && authorization.origin != endpoint.origin) {
      throw const McpFailure('MCP authorization endpoints are not bound to their issuer');
    }
    if (!(metadata['code_challenge_methods_supported'] as List? ?? []).contains('S256')) {
      throw const McpFailure('MCP authorization server does not support PKCE S256');
    }
    return (metadata: metadata, resource: canonical,
      scopes: (resource?['scopes_supported'] as List? ?? []).cast<String>());
  }

  Future<Json> _exchange(Json metadata, Json client, Map<String, String> form, CancellationToken token) async {
    final values = <String, String>{...form, 'client_id': client['client_id'] as String};
    String? basic;
    final secret = _options['client_secret_env'] is String
      ? Platform.environment[_options['client_secret_env']] : client['client_secret'] as String?;
    final method = client['token_endpoint_auth_method'] ?? 'none';
    if (method != 'none') {
      if (secret == null || secret.isEmpty) throw const McpFailure('MCP OAuth client secret is missing');
      if (method == 'client_secret_post') {
        values['client_secret'] = secret;
      } else if (method == 'client_secret_basic') {
        basic = 'Basic ${base64.encode(utf8.encode('${Uri.encodeQueryComponent(values['client_id']!)}:${Uri.encodeQueryComponent(secret)}'))}';
        values.remove('client_id');
      } else {
        throw const McpFailure('MCP OAuth token authentication method is unsupported');
      }
    }
    final response = await _request('POST', _webUri(metadata['token_endpoint'] as String), token, form: values, authorization: basic);
    if (response.status < 200 || response.status >= 300) {
      throw McpFailure(response.body['error'] == 'invalid_grant' || response.status == 401
        ? 'MCP sign-in expired; sign in again' : 'MCP OAuth token exchange failed',
        status: response.body['error'] == 'invalid_grant' ? 401 : response.status);
    }
    return response.body;
  }

  Json _tokens(Json response, Json previous) {
    final access = response['access_token'];
    if (access is! String || access.trim().isEmpty || RegExp(r'[\r\n]').hasMatch(access) ||
        (response['token_type'] as String? ?? 'Bearer').toLowerCase() != 'bearer' ||
        response['refresh_token'] != null && response['refresh_token'] is! String ||
        response['expires_in'] != null && (response['expires_in'] is! num || response['expires_in'] < 0)) {
      throw const McpFailure('MCP authorization server returned invalid credentials');
    }
    return {
      ...previous, 'server_name': name, 'server_url': _url, 'access_token': access,
      'refresh_token': ?(response['refresh_token'] ?? previous['refresh_token']),
      'scope': response['scope'] ?? previous['scope'],
      'expires_at': response['expires_in'] is num
        ? DateTime.now().millisecondsSinceEpoch + ((response['expires_in'] as num) * 1000).toInt() : null,
    };
  }

  Future<({int status, Json body, Map<String, List<String>> headers})> _request(
    String method, Uri uri, CancellationToken cancellation, {
    Json? body, Map<String, String>? form, String? authorization, bool resourceHeaders = false,
  }) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 20));
    final token = cancellation.merge(lifetime).merge(deadline);
    HttpClientRequest? request;
    final hook = CancellationHook(token, () => request?.abort(token.exception));
    try {
      token.throwIfCancelled();
      request = await http.openUrl(method, uri).then((value) {
        if (token.isCancelled) value.abort(token.exception);
        return value;
      }).asCancellable(token);
      token.throwIfCancelled();
      request.followRedirects = false;
      request.headers.set('Accept', 'application/json, text/event-stream');
      if (resourceHeaders && uri.origin == _webUri(_url).origin) {
        for (final entry in jsonObject(config['headers'] ?? {}).entries) { request.headers.set(entry.key, entry.value); }
        for (final entry in jsonObject(config['header_env'] ?? {}).entries) {
          final value = Platform.environment[entry.value];
          if (value == null) throw const McpFailure('MCP credential environment variable is missing');
          request.headers.set(entry.key, value);
        }
      }
      if (authorization != null) request.headers.set('Authorization', authorization);
      if (form != null) {
        request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
        request.write(form.entries.map((entry) => '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}').join('&'));
      } else if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().asCancellable(token);
      final headers = <String, List<String>>{};
      response.headers.forEach((name, values) => headers[name.toLowerCase()] = values);
      // A discovery probe can be an indefinitely open SSE response. Only its
      // status and challenge are needed; never wait for a successful stream.
      if (resourceHeaders) {
        await response.listen((_) {}).cancel();
        return (status: response.statusCode, body: <String, dynamic>{}, headers: headers);
      }
      final bytes = <int>[];
      final input = StreamIterator(response);
      try {
        while (await input.moveNext().asCancellable(token, onCancel: () => unawaited(input.cancel()))) {
          bytes.addAll(input.current);
          if (bytes.length > 1024 * 1024) throw const McpFailure('MCP OAuth response exceeds 1 MiB');
        }
      } finally { await input.cancel(); }
      Json data = {};
      try { data = jsonObject(jsonDecode(utf8.decode(bytes))); } catch (_) {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          throw const McpFailure('MCP OAuth endpoint returned invalid JSON');
        }
      }
      return (status: response.statusCode, body: data, headers: headers);
    } on CancelledException { rethrow;
    } on McpFailure { rethrow;
    } catch (_) {
      token.throwIfCancelled();
      throw const McpFailure('MCP OAuth request failed');
    } finally {
      hook.dispose();
      request?.abort();
      deadline.cancel();
    }
  }

  Future<void> _save(Json saved, CancellationToken token) async {
    token.throwIfCancelled();
    await _prepareDirectory();
    final temporary = File('${_directory.path}/.$_key.${newId()}.tmp');
    try {
      await temporary.create();
      await _private(temporary.path, '600');
      token.throwIfCancelled();
      await temporary.writeAsString(jsonEncode(saved), flush: true);
      token.throwIfCancelled();
      await temporary.rename(_file.path);
      _diskStamp = await _stamp();
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<T> _withCredentialLock<T>(CancellationToken token, Future<T> Function() action) async {
    token.throwIfCancelled();
    await _prepareDirectory();
    final locks = Directory('${_directory.path}/locks');
    if (FileSystemEntity.isLinkSync(locks.path)) throw const McpFailure('MCP credential lock directory must not be a symbolic link');
    await locks.create();
    await _private(locks.path, '700');
    final path = '${locks.path}/$_key.lock';
    if (FileSystemEntity.isLinkSync(path)) throw const McpFailure('MCP credential lock must not be a symbolic link');
    final lock = await File(path).open(mode: FileMode.append);
    var acquired = false;
    try {
      await _private(path, '600');
      while (!acquired) {
        token.throwIfCancelled();
        try { await lock.lock(FileLock.exclusive); acquired = true; } on FileSystemException catch (error) {
          if (![11, 13, 35].contains(error.osError?.errorCode)) rethrow;
          await cancellableDelay(const Duration(milliseconds: 25), token);
        }
      }
      token.throwIfCancelled();
      return await action();
    } on CancelledException { rethrow;
    } on McpFailure { rethrow;
    } catch (_) { throw const McpFailure('Unable to update MCP credentials');
    } finally {
      if (acquired) await lock.unlock();
      await lock.close();
    }
  }

  Future<void> _prepareDirectory() async {
    final type = await FileSystemEntity.type(_directory.path, followLinks: false);
    if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.directory) {
      throw const McpFailure('MCP credential directory must not be a symbolic link');
    }
    await _directory.create(recursive: true);
    await _private(_directory.path, '700');
  }

  Future<void> logout(CancellationToken cancellation) async {
    await close();
    _credentials = null;
    await _withCredentialLock(cancellation, () async {
      if (await FileSystemEntity.type(_file.path, followLinks: false) != FileSystemEntityType.notFound) await _file.delete();
    });
  }

  Future<void> close() async {
    lifetime.cancel();
    for (final work in <Future<Object?>?>[_loading, _loggingIn, _refreshing]) {
      try { await work; } catch (_) { /* Shutdown owns cancellation. */ }
    }
  }
}

Future<void> _private(String path, String mode) async {
  if (Platform.isWindows) return;
  if ((await Process.run('chmod', [mode, path])).exitCode != 0) {
    throw const McpFailure('Unable to protect MCP credentials');
  }
}

Uri _webUri(String value) {
  final uri = Uri.tryParse(value);
  final loopback = uri != null && (uri.host == 'localhost' || (InternetAddress.tryParse(uri.host)?.isLoopback ?? false));
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment ||
      uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
    throw const McpFailure('MCP OAuth endpoints require HTTPS or HTTP loopback');
  }
  return uri;
}

String _random() => base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');

Json _bearerChallenge(List<String> headers) {
  for (final header in headers) {
    for (final start in RegExp(r'(?:^|,)\s*Bearer(?:\s+|$)', caseSensitive: false).allMatches(header)) {
      final values = <String, dynamic>{};
      var offset = start.end, invalid = false;
      final parameter = RegExp(r'''\s*([!#$%&'*+.^_`|~A-Za-z0-9-]+)\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^,\s]+))\s*(?:,|$)''');
      while (offset < header.length) {
        final match = parameter.matchAsPrefix(header, offset);
        if (match == null) break;
        final key = match[1]!.toLowerCase();
        if (values.containsKey(key)) invalid = true;
        values[key] = (match[2] ?? match[3]!).replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
        offset = match.end;
      }
      if (!invalid && values.isNotEmpty) return values;
    }
  }
  return {};
}
