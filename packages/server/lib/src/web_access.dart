import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';

/// The public browser origin has its own owner authentication. Local UDS and
/// bearer clients retain their explicit transport authority.
class WebAccess {
  WebAccess._(this.origin, this._key, this.allowedOrigins, this._sessions);
  final String origin;
  final Set<String> allowedOrigins;
  final List<int> _key;
  final Database _sessions;
  final _attempts = <String, ({int count, DateTime expires})>{};
  final _lifetime = CancellationToken();
  static const _cookie = '__Host-happen-session';
  static const _sessionLifetime = Duration(days: 365);

  static Future<WebAccess> open(String publicUrl, String keyFile, {Set<String> allowedOrigins = const {}}) async {
    final file = File(keyFile);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || !Platform.isWindows && stat.mode & 0x3f != 0) {
      throw ArgumentError('The owner key must be a private file (chmod 600)');
    }
    final key = (await file.readAsString()).trim();
    if (key.length < 32 || key.length > 1024) throw ArgumentError('The owner key must contain 32–1024 characters');
    final origin = Uri.parse(publicUrl).origin;
    for (final value in allowedOrigins) {
      final uri = Uri.parse(value);
      if (uri.origin != value || uri.scheme != 'https' && !(uri.scheme == 'http' && {'localhost', '127.0.0.1'}.contains(uri.host))) {
        throw ArgumentError('Allowed browser origins must be HTTPS origins or loopback development origins');
      }
    }
    // Only keyed digests are durable. A copied database cannot authenticate,
    // and changing the owner key makes every old digest unreachable.
    final sessionsFile = File('$keyFile.sessions.sqlite');
    await sessionsFile.open(mode: FileMode.append).then((file) => file.close());
    if (!Platform.isWindows) {
      final mode = await Process.run('chmod', ['600', sessionsFile.path]);
      if (mode.exitCode != 0) throw StateError('Cannot protect the owner session database');
    }
    final sessions = sqlite3.open(sessionsFile.path);
    try {
      sessions.execute('PRAGMA synchronous=FULL');
      sessions.execute('''CREATE TABLE IF NOT EXISTS owner_sessions (
        digest TEXT PRIMARY KEY, origin TEXT NOT NULL, expires INTEGER NOT NULL
      )''');
      sessions.execute('DELETE FROM owner_sessions WHERE expires <= ?', [DateTime.now().millisecondsSinceEpoch]);
      return WebAccess._(origin, sha256.convert(utf8.encode(key)).bytes, {origin, ...allowedOrigins}, sessions);
    } catch (_) { sessions.close(); rethrow; }
  }

  bool permitsOrigin(HttpRequest request) => allowedOrigins.contains(request.headers.value('origin'));

  bool permitsToken(String token, String origin) {
    if (_lifetime.isCancelled || !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) return false;
    return _sessions.select('SELECT 1 FROM owner_sessions WHERE digest IS ? AND origin IS ? AND expires > ?',
      [_sessionHash(token), origin, DateTime.now().millisecondsSinceEpoch]).isNotEmpty;
  }

  String _sessionHash(String token) => Hmac(sha256, _key).convert(utf8.encode(token)).toString();
  void _revoke(String token) => _sessions.execute('DELETE FROM owner_sessions WHERE digest IS ?', [_sessionHash(token)]);
  void _setCookie(HttpResponse response, String token, int maxAge) {
    final cookie = Cookie(_cookie, token)..path = '/'..secure = true..httpOnly = true..sameSite = SameSite.none..maxAge = maxAge;
    // Each top-level client site gets its own private cookie partition. This
    // also works when an arbitrary server uses a different registrable domain.
    response.headers.add(HttpHeaders.setCookieHeader, '$cookie; Partitioned');
  }

  String? _sessionCookie(HttpRequest request) => request.cookies.where((cookie) => cookie.name == _cookie).firstOrNull?.value;

  bool authorized(HttpRequest request) {
    final token = _sessionCookie(request);
    return token != null && permitsToken(token, request.headers.value('origin') ?? origin);
  }

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('Referrer-Policy', 'no-referrer');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Cross-Origin-Resource-Policy', 'same-origin');
    response.headers.set('Content-Security-Policy', "frame-ancestors 'none'; object-src 'none'; base-uri 'self'");
    if (permitsOrigin(request)) {
      response.headers.set('Access-Control-Allow-Origin', request.headers.value('origin')!);
      response.headers.set('Access-Control-Allow-Credentials', 'true');
      response.headers.set('Vary', 'Origin');
    }
    if (request.method == 'OPTIONS' && request.uri.path.startsWith('/auth/') && permitsOrigin(request)) {
      response.headers.set('Access-Control-Allow-Methods', 'GET, POST');
      response.headers.set('Access-Control-Allow-Headers', 'Content-Type, Priority');
      response.headers.set('Access-Control-Max-Age', '86400');
      response.statusCode = 204;
      await response.close();
      return;
    }
    if (request.uri.path.startsWith('/auth/')) {
      await _authenticate(request);
      return;
    }
    response.statusCode = 404;
    await response.close();
  }

  Future<void> _authenticate(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (request.method == 'GET' && request.uri.path == '/auth/session') {
      final authenticated = authorized(request);
      response.statusCode = authenticated ? 200 : 401;
      response.write(jsonEncode({'authenticated': authenticated, if (authenticated) 'token': _sessionCookie(request)}));
      await response.close();
      return;
    }
    // Fetch metadata and Origin are checked before reading a password or cookie.
    if (request.method != 'POST' || !permitsOrigin(request)) {
      response.statusCode = 403;
      await response.close();
      return;
    }
    if (request.uri.path == '/auth/logout') {
      try {
        final value = await _body(request);
        final token = value['token'];
        if (token is String && permitsToken(token, request.headers.value('origin')!)) _revoke(token);
      } on FormatException { /* Cookie-only logout. */ }
      for (final cookie in request.cookies.where((cookie) => cookie.name == _cookie)) { _revoke(cookie.value); }
      _setCookie(response, '', 0);
      response.statusCode = 204;
      await response.close();
      return;
    }
    if (request.uri.path != '/auth/login') {
      response.statusCode = 404;
      await response.close();
      return;
    }
    final now = DateTime.now();
    _attempts.removeWhere((_, attempt) => !attempt.expires.isAfter(now));
    final address = request.headers.value('cf-connecting-ip') ?? request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final previous = _attempts[address];
    if ((previous?.count ?? 0) >= 10 || _attempts.length >= 4096 && previous == null) {
      response.statusCode = 429;
      response.headers.set('Retry-After', '600');
      await response.close();
      return;
    }
    _attempts[address] = (count: (previous?.count ?? 0) + 1, expires: previous?.expires ?? now.add(const Duration(minutes: 10)));
    var valid = false;
    try {
      if (request.headers.contentType?.mimeType != 'application/json') throw const FormatException('Expected JSON');
      final key = (await _body(request))['key'];
      if (key is! String || key.length > 1024) throw const FormatException('Invalid key');
      final hash = sha256.convert(utf8.encode(key)).bytes;
      var difference = 0;
      for (var i = 0; i < _key.length; i++) { difference |= _key[i] ^ hash[i]; }
      valid = difference == 0;
    } on FormatException { /* Authentication failures have one public response. */ }
    on CancelledException { /* Bounded request body read. */ }
    if (!valid) {
      response.statusCode = 401;
      response.write('{"authenticated":false}');
    } else {
      _attempts.remove(address);
      _lifetime.throwIfCancelled();
      _sessions.execute('DELETE FROM owner_sessions WHERE expires <= ?', [now.millisecondsSinceEpoch]);
      _sessions.execute('''DELETE FROM owner_sessions WHERE digest IN (
        SELECT digest FROM owner_sessions ORDER BY expires DESC LIMIT -1 OFFSET 255
      )''');
      final session = '${newId()}${newId()}';
      _sessions.execute('INSERT INTO owner_sessions(digest, origin, expires) VALUES(?, ?, ?)',
        [_sessionHash(session), request.headers.value('origin')!, now.add(_sessionLifetime).millisecondsSinceEpoch]);
      _setCookie(response, session, _sessionLifetime.inSeconds);
      response.write(jsonEncode({'authenticated': true, 'token': session}));
    }
    await response.close();
  }

  Future<Json> _body(HttpRequest request) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 5));
    final token = _lifetime.merge(deadline);
    final input = ownStream(request, token);
    final bytes = <int>[];
    try {
      await for (final chunk in input.stream) {
        if (bytes.length + chunk.length > 4096) throw const FormatException('Too large');
        bytes.addAll(chunk);
      }
      return jsonObject(jsonDecode(utf8.decode(bytes)));
    } finally { deadline.cancel(); await input.close(); }
  }

  void close() { if (_lifetime.isCancelled) return; _lifetime.cancel(); _sessions.close(); _attempts.clear(); }
}
