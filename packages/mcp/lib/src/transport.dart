import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai/ai.dart' show decodeSse;
import 'package:ffi/ffi.dart';
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import 'challenges.dart';

part 'stdio.dart';

const mcpProtocolVersion = '2026-07-28';
const mcpUserAgent = 'happen-mcp-client/0.1.0';
// Codex's modern MCP wire bound, independent of Code Mode/model budgets.
// Its legacy local codec and legacy HTTP retain their uncapped wire behavior.
const _maxMessageBytes = 8 * 1024 * 1024;
const _versionKey = 'io.modelcontextprotocol/protocolVersion';
const _subscriptionKey = 'io.modelcontextprotocol/subscriptionId';
// Match Codex's bounded streamable HTTP recovery delays.
const _httpRetryDelays = [Duration(milliseconds: 250), Duration(seconds: 1)];
const _legacyVersions = {'2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'};

bool _onlyLegacy(Object? value) => value is List && value.isNotEmpty && value.every(_legacyVersions.contains);
bool _legacyPrevalidation(String message) {
  if (message == 'Bad Request: No valid session ID provided') return true;
  final match = RegExp(r'^Bad Request: Unsupported protocol version(?:: 2026-07-28)? \(supported versions: (.+)\)$').firstMatch(message);
  if (match == null) return false;
  final versions = match[1]!.split(',').map((value) => value.trim()).toList();
  return versions.any(_legacyVersions.contains) && versions.every((value) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) && value.compareTo(mcpProtocolVersion) < 0);
}

bool _legacyError(Json error) => error['code'] == -32601 ||
  error['code'] == -32022 && _onlyLegacy(error['data']?['supported']) ||
  const {-32022, -32600, -32602}.contains(error['code']) &&
    (error['message'] as String? ?? '').trim().toLowerCase() == 'unsupported protocol version: 2026-07-28';

bool _transientHttpStatus(int? status) =>
    const {408, 429, 500, 502, 503, 504}.contains(status);

bool _retryableHttpFailure(Object error) => switch (error) {
  McpCredentialFailure() => false,
  SocketException() || HttpException() || HandshakeException() => true,
  McpFailure(:final status) => _transientHttpStatus(status),
  _ => false,
};

class McpFailure implements Exception {
  const McpFailure(this.message, {this.code, this.status, this.data, this.legacyFallback = false});
  final String message;
  final int? code, status;
  final Json? data;
  final bool legacyFallback;
  @override
  String toString() => message;
}

/// A credential preparation failure is not a transient MCP HTTP response.
/// In particular, a failed proactive refresh of a still-valid token is an
/// ordinary error, while expired/rejected credentials require reconnecting.
class McpCredentialFailure extends McpFailure {
  const McpCredentialFailure(super.message, {required this.authenticationRequired, super.status});
  final bool authenticationRequired;
}

/// One shared transport generation. Requests have independent cancellation.
class McpConnection {
  McpConnection(this.config, this.http, this.onNotification, {this.authorization, this.onAuthChallenge});
  final Json config;
  final HttpClient http;
  final void Function(Json) onNotification;
  final Future<String?> Function(CancellationToken)? authorization;
  final void Function(int status, List<String> headers, {required bool sentToken})? onAuthChallenge;
  final lifetime = CancellationToken();
  final _pending = <Object, _Pending>{};
  _StdioProcess? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  final _stderrDone = Completer<void>();
  final _stderrLine = <int>[];
  Future<void>? _closing, _recovering;
  var _generation = 0;
  final closed = Completer<void>();
  String version = mcpProtocolVersion;
  String? _session;
  Json discovery = {};
  bool get modern => version == mcpProtocolVersion;
  int? get processId => _process?.pid;

  Future<void> connect(CancellationToken cancellation) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
    try { await _connect(cancellation.merge(lifetime).merge(deadline)); }
    finally { deadline.cancel(); }
  }

  Future<void> _connect(CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    if (config['command'] != null) {
      final process = await _startStdio(config, cancellation);
      _process = process;
      _stderr = process.error.listen(_logStderr, onDone: () {
        _flushStderr(); if (!_stderrDone.isCompleted) _stderrDone.complete();
      }, onError: (Object _) { if (!_stderrDone.isCompleted) _stderrDone.complete(); });
      _stdout = boundedLines(process.output, maxBytes: _maxMessageBytes, byteLimit: () => modern ? _maxMessageBytes : null).listen(
        (line) {
          try {
            _receive(jsonObject(jsonDecode(line)));
          } catch (error) {
            unawaited(close(reason: McpFailure(error.toString())));
          }
        },
        onError: (Object error) => unawaited(close(reason: McpFailure(error.toString()))),
        onDone: () => unawaited(close()),
      );
      unawaited(process.exited.then((_) => close()));
    } else {
      final uri = Uri.parse(requiredString(config, 'url'));
      if (!{'https', 'http'}.contains(uri.scheme) || uri.userInfo.isNotEmpty) {
        throw ArgumentError(
          'MCP URL must use HTTP(S) without embedded credentials',
        );
      }
    }
    for (var attempt = 0; ; attempt++) {
    try {
      try {
      discovery = await request(
        'server/discover',
        {},
        cancellation: cancellation,
        timeout: const Duration(seconds: 10),
      );
      if (!(discovery['supportedVersions'] as List? ?? []).contains(
        mcpProtocolVersion,
      )) {
        throw McpFailure(
          'MCP server does not support the requested modern protocol',
          code: -32022,
          legacyFallback: _onlyLegacy(discovery['supportedVersions']),
        );
      }
    } on McpFailure catch (error) {
      if (!error.legacyFallback || error.status == 401 || error.status == 403 || config['legacy_fallback'] == false) {
        rethrow;
      }
      await _legacy(cancellation);
      }
      _generation++;
      return;
    } catch (error) {
      final modernRetry = error is McpFailure && error.code == -32022 &&
        (error.data?['supported'] as List? ?? []).contains(mcpProtocolVersion);
      if (_process != null || attempt >= _httpRetryDelays.length || !modernRetry && !_retryableHttpFailure(error)) rethrow;
      await cancellableDelay(_httpRetryDelays[attempt], cancellation);
      version = mcpProtocolVersion; _session = null;
    }
    }
  }

  Future<void> _legacy(CancellationToken cancellation) async {
    version = '2025-06-18';
    final result = await request('initialize', {
      'protocolVersion': version,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'happen', 'version': '0.1.0'},
    }, cancellation: cancellation);
    final selected = result['protocolVersion'];
    if (!_legacyVersions.contains(selected)) {
      throw const McpFailure(
        'MCP server selected an unsupported legacy version',
      );
    }
    version = selected as String;
    discovery = result;
    await _notify('notifications/initialized', {}, cancellation);
  }

  Future<Json> request(
    String method,
    Json params, {
    required CancellationToken cancellation,
    Duration? timeout = const Duration(seconds: 60),
    void Function(Json)? onNotification,
    Json? inputSchema,
    bool retrySafe = false,
  }) => _request(method, params, cancellation: cancellation, timeout: timeout, onNotification: onNotification, inputSchema: inputSchema, retrySafe: retrySafe);

  Future<Json> _request(String method, Json params, {required CancellationToken cancellation, Duration? timeout,
    void Function(Json)? onNotification, Json? inputSchema, bool retrySafe = false, bool recovered = false}) async {
    cancellation.throwIfCancelled();
    lifetime.throwIfCancelled();
    if (_pending.length >= 256) {
      throw const McpFailure('MCP pending request limit reached');
    }
    final deadline = timeout == null
        ? CancellationToken()
        : TimeoutCancellationToken(timeout);
    final token = cancellation.merge(lifetime).merge(deadline);
    final id = newId();
    final protocolVersion = version;
    final generation = _generation, stateful = !modern && _session != null;
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': {
        ...params,
        if (protocolVersion == mcpProtocolVersion)
          '_meta': {
            ...jsonObject(params['_meta'] ?? {}),
            _versionKey: version,
            'io.modelcontextprotocol/clientInfo': {
              'name': 'happen',
              'version': '0.1.0',
            },
            'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
          },
      },
    };
    try {
      if (protocolVersion == mcpProtocolVersion && utf8.encode(jsonEncode(body)).length > _maxMessageBytes) {
        throw const McpFailure('MCP request exceeds $_maxMessageBytes bytes');
      }
      if (_process != null) {
        final pending = _Pending(method, onNotification);
        _pending[id] = pending;
        final hook = CancellationHook(token, () {
          _pending.remove(id);
          if (method != 'initialize' && !lifetime.isCancelled) {
            _write({
              'jsonrpc': '2.0',
              'method': 'notifications/cancelled',
              'params': {'requestId': id},
            });
          }
          if (!pending.result.isCompleted) {
            pending.result.completeError(token.exception!);
          }
        });
        try {
          token.throwIfCancelled();
          _write(body);
          return await pending.result.future;
        } finally {
          hook.dispose();
          _pending.remove(id);
        }
      }
      return await _http(body, token, onNotification, inputSchema,
        retrySafe: retrySafe, protocolVersion: protocolVersion);
    } on McpFailure catch (error) {
      if (recovered || _process != null || !stateful || error.status != 404 ||
          const {'initialize', 'notifications/initialized', 'server/discover'}.contains(method)) rethrow;
      // The server rejected the old session before admitting this request.
      // Rebuild its envelope after the coalesced handshake, once per call.
      if (generation == _generation) {
        await (_recovering ??= () async {
          _session = null; version = mcpProtocolVersion;
          await connect(lifetime);
        }().whenComplete(() => _recovering = null)).asCancellable(token);
      }
      return await _request(method, params, cancellation: token, onNotification: onNotification,
        inputSchema: inputSchema, retrySafe: retrySafe, recovered: true);
    } finally {
      deadline.cancel();
    }
  }

  void _write(Json message) {
    if (lifetime.isCancelled) return;
    _process?.input.writeln(jsonEncode(message));
  }

  void _logStderr(List<int> bytes) {
    for (final byte in bytes) {
      if (byte == 10) { _flushStderr(); continue; }
      _stderrLine.add(byte);
      if (_stderrLine.length >= 16384) _flushStderr();
    }
  }
  void _flushStderr() {
    if (_stderrLine.isEmpty) return;
    // Diagnostics are untrusted local logs, never MCP responses, client events
    // or telemetry carriers. Bound unterminated lines independently of framing.
    stderr.writeln('MCP server stderr: ${utf8.decode(_stderrLine, allowMalformed: true)}');
    _stderrLine.clear();
  }

  void _receive(Json message) {
    if (message['jsonrpc'] != '2.0') {
      throw const FormatException('Invalid MCP envelope');
    }
    if (message.containsKey('method')) {
      if (message.containsKey('id')) {
        if (modern) {
          throw const FormatException(
            'Modern MCP servers cannot send requests',
          );
        }
        _write({
          'jsonrpc': '2.0',
          'id': message['id'],
          'error': {
            'code': -32601,
            'message': 'Client capability is not supported',
          },
        });
        return;
      }
      final params = jsonObject(message['params'] ?? {});
      final parent =
          params['_meta']?[_subscriptionKey] ?? params['progressToken'];
      if (parent != null) {
        _pending[parent]?.notify?.call(message);
      } else if (!modern ||
          message['method'] == 'notifications/events/list_changed') {
        onNotification(message);
      }
      return;
    }
    final pending = _pending.remove(message['id']);
    if (pending == null || pending.result.isCompleted) return;
    try {
      pending.result.complete(_result(message, discovery: pending.method == 'server/discover'));
    } catch (error, stack) {
      pending.result.completeError(error, stack);
    }
  }

  Json _result(Json message, {int? status, bool discovery = false, bool legacyHttp = false}) {
    if (message['error'] is Map) {
      final error = jsonObject(message['error']);
      throw McpFailure(
        error['message'] as String? ?? 'MCP request failed (code ${error['code']})',
        code: error['code'] as int?,
        status: status,
        data: error['data'] is Map ? jsonObject(error['data']) : null,
        legacyFallback: discovery && (legacyHttp || _legacyError(error)),
      );
    }
    if (status != null && (status < 200 || status >= 300)) {
      throw McpFailure('MCP HTTP request failed ($status)', status: status);
    }
    final result = jsonObject(message['result']);
    if (result['resultType'] != null &&
        !['complete', 'input_required'].contains(result['resultType'])) {
      throw const McpFailure('Unsupported MCP result type');
    }
    // This client declares no elicitation, roots, or sampling capabilities.
    // Preserve requestState at the protocol boundary for a caller that can resume.
    return result;
  }

  Future<Json> _http(
    Json body,
    CancellationToken token,
    void Function(Json)? notify,
    Json? schema, {
    bool retrySafe = false,
    required String protocolVersion,
  }) async {
    final canRetry = retrySafe || const {
      'tools/list',
      'resources/list',
      'resources/templates/list',
      'resources/read',
      'prompts/list',
      'prompts/get',
      'events/list',
    }.contains(body['method']);
    for (var retries = 0; ; retries++) {
      token.throwIfCancelled();
      try {
        return await _httpOnce(body, token, notify, schema, protocolVersion: protocolVersion);
      } catch (error) {
        token.throwIfCancelled();
        if (!canRetry || retries >= _httpRetryDelays.length ||
            !_retryableHttpFailure(error)) {
          rethrow;
        }
        final delay = _httpRetryDelays[retries];
        traceInstant('mcp.http.retry', category: 'retry', attributes: {
          'mcp.method': body['method'],
          'attempt': retries + 1,
          'delay_ms': delay.inMilliseconds,
          'error.type': error.runtimeType.toString(),
          if (error is McpFailure) 'http.response.status_code': error.status,
        });
        await cancellableDelay(delay, token);
      }
    }
  }

  Future<Json> _httpOnce(
    Json body,
    CancellationToken token,
    void Function(Json)? notify,
    Json? schema, {required String protocolVersion}
  ) async {
    HttpClientRequest? outgoing;
    StreamIterator<Json>? messages;
    Future<void> Function()? closeBody;
    final hook = CancellationHook(token, () => outgoing?.abort(token.exception));
    try {
      final access = await authorization?.call(token);
      var uri = Uri.parse(requiredString(config, 'url')), verb = 'POST';
      Uri? referer;
      var sendBody = true;
      final modern = protocolVersion == mcpProtocolVersion;
      final version = protocolVersion;
      final messageLimit = modern ? _maxMessageBytes : null;
      final encodedBody = utf8.encode(jsonEncode(body));
      HttpClientResponse response;
      for (var redirects = 0; ; redirects++) {
      token.throwIfCancelled();
      outgoing = await http.openUrl(verb, uri).then((value) {
        if (token.isCancelled) value.abort(token.exception);
        return value;
      }).asCancellable(token);
      token.throwIfCancelled();
      outgoing.followRedirects = false;
      outgoing.headers.set('User-Agent', mcpUserAgent);
      if (sendBody) outgoing.headers.contentType = ContentType.json;
      outgoing.headers.set('Accept', 'application/json, text/event-stream');
      for (final entry in jsonObject(config['headers'] ?? {}).entries) {
        outgoing.headers.set(entry.key, entry.value as String);
      }
      for (final entry in jsonObject(config['header_env'] ?? {}).entries) {
        final value = Platform.environment[entry.value];
        if (value == null) {
          throw StateError('MCP credential environment variable is missing');
        }
        outgoing.headers.set(entry.key, value);
      }
      if (access != null) outgoing.headers.set('Authorization', 'Bearer $access');
      if (referer != null) {
        outgoing.headers.set('Referer', referer.toString());
        if (uri.scheme == 'http') outgoing.headers.removeAll('Proxy-Authorization');
      }
      if (!sendBody) {
        for (final name in ['Content-Type', 'Content-Length', 'Content-Encoding', 'Transfer-Encoding']) { outgoing.headers.removeAll(name); }
      }
      outgoing.headers.set('MCP-Protocol-Version', version);
      if (_session != null && !modern) {
        outgoing.headers.set('Mcp-Session-Id', _session!);
      }
      if (modern) {
        final method = body['method'] as String;
        final params = jsonObject(body['params']);
        outgoing.headers.set('Mcp-Method', method);
        if (['tools/call', 'resources/read', 'prompts/get'].contains(method)) {
          outgoing.headers.set('Mcp-Name', headerValue(params[method == 'resources/read' ? 'uri' : 'name']));
        }
        if (method == 'tools/call' && schema != null) {
          final headers = schemaHeaders(schema, params['arguments']);
          headers.forEach(outgoing.headers.set);
        }
      }
      if (sendBody) { outgoing.contentLength = encodedBody.length; outgoing.add(encodedBody); }
      response = await traceAsync('mcp.http.headers', () => outgoing!.close().asCancellable(token),
        category: 'http', attributes: {'http.request.method': verb, 'server.address': uri.host, 'url.path': uri.path});
      traceInstant('mcp.http.response', category: 'http', attributes: {'http.response.status_code': response.statusCode});
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        await response.listen((_) {}).cancel();
        if (modern) throw McpFailure('MCP modern HTTP redirect rejected (${response.statusCode})', status: response.statusCode);
        final location = response.headers.value('location');
        if (location == null) throw McpFailure('MCP redirect has no location', status: response.statusCode);
        final next = uri.resolve(location);
        if (!{'http', 'https'}.contains(next.scheme) || next.userInfo.isNotEmpty || next.origin != uri.origin) {
          throw McpFailure('MCP redirect to a different origin was rejected', status: response.statusCode);
        }
        if (redirects >= 10) throw McpFailure('MCP redirect limit exceeded', status: response.statusCode);
        if (const {301, 302, 303}.contains(response.statusCode) && verb == 'POST') { verb = 'GET'; sendBody = false; }
        outgoing.abort(); referer = uri; uri = next.removeFragment(); continue;
      }
      break;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        final headers = response.headers['www-authenticate'] ?? <String>[];
        onAuthChallenge?.call(response.statusCode, headers, sentToken: access != null);
        final challenges = bearerChallenges(headers);
        final insufficient = challenges.where((challenge) => challenge.parameters['error'] == 'insufficient_scope').firstOrNull;
        if (response.statusCode == 403 && insufficient != null) {
          await response.listen((_) {}).cancel();
          throw McpFailure('Insufficient scope', status: 403, data: {
            'required_scope': requiredScope(insufficient), 'www_authenticate': insufficient.header,
          });
        }
        if (response.statusCode == 401 && body['method'] == 'tools/call' && challenges.isNotEmpty) {
          await response.listen((_) {}).cancel();
          return {'content': [{'type': 'text', 'text': 'Authentication required'}], 'isError': true,
            '_meta': {'mcp/www_authenticate': [headers.join(', ')]}};
        }
      }
      if (!modern && body['method'] == 'initialize') {
        _session = response.headers.value('Mcp-Session-Id');
      }
      if (!body.containsKey('id') && response.statusCode == 202) return {};
      if (response.headers.contentType?.mimeType != 'text/event-stream') {
        final bytes = <int>[];
        final input = StreamIterator(traceStream(response, 'mcp.http.body', size: (chunk) => chunk.length, cancellation: token));
        try {
          while (await input.moveNext().asCancellable(
            token,
            onCancel: () => unawaited(input.cancel()),
          )) {
            bytes.addAll(input.current);
            if (messageLimit != null && bytes.length > messageLimit) {
              throw McpFailure('MCP response exceeds $messageLimit bytes');
            }
          }
        } finally {
          unawaited(input.cancel());
        }
        Json message;
        try {
          message = jsonObject(jsonDecode(utf8.decode(bytes)));
        } on FormatException {
          throw McpFailure(
            'MCP endpoint returned an invalid response',
            status: response.statusCode,
            legacyFallback: body['method'] == 'server/discover' && const {404, 405}.contains(response.statusCode),
          );
        }
        final legacyHttp = body['method'] == 'server/discover' && response.statusCode == 400 && message['id'] == null &&
          message['error']?['code'] == -32000 && _legacyPrevalidation(message['error']['message'] as String? ?? '');
        if (message['id'] != body['id'] && !legacyHttp) {
          throw McpFailure('MCP response ID does not match its request', status: response.statusCode, code: -32020);
        }
        return _result(message, status: response.statusCode, discovery: body['method'] == 'server/discover', legacyHttp: legacyHttp);
      }
      if (response.statusCode != 200) {
        throw McpFailure(
          'MCP stream failed (${response.statusCode})',
          status: response.statusCode,
        );
      }
      final input = ownStream(traceStream(response, 'mcp.http.body', size: (chunk) => chunk.length, cancellation: token), token);
      closeBody = input.close;
      messages = StreamIterator(
        decodeSse(input.stream, maxEventBytes: messageLimit),
      );
      while (await messages.moveNext().asCancellable(
        token,
        onCancel: () => unawaited(messages!.cancel()),
      )) {
        final message = messages.current;
        if (message['id'] == body['id']) return _result(message, discovery: body['method'] == 'server/discover');
        if (message.containsKey('id')) {
          throw const McpFailure('Unexpected MCP server request or response');
        }
        final params = jsonObject(message['params'] ?? {});
        final method = message['method'] as String? ?? '';
        if (method.startsWith('notifications/events/') ||
            method.startsWith('notifications/subscriptions/') ||
            method.endsWith('/list_changed') ||
            method == 'notifications/resources/updated') {
          if (params['_meta']?[_subscriptionKey] != body['id']) continue;
        }
        notify?.call(message);
      }
      throw const McpFailure('MCP stream ended without a result');
    } catch (_) {
      token.throwIfCancelled();
      rethrow;
    } finally {
      hook.dispose();
      await closeBody?.call();
      outgoing?.abort();
      if (messages != null) {
        unawaited(messages.cancel().catchError((Object _) {}));
      }
    }
  }

  Future<void> _notify(
    String method,
    Json params,
    CancellationToken token,
  ) async {
    final body = {'jsonrpc': '2.0', 'method': method, 'params': params};
    if (_process != null) {
      _write(body);
    } else {
      await _http(body, token, null, null, protocolVersion: version);
    }
  }

  Future<void> close({McpFailure? reason}) => _closing ??= _close(reason);
  Future<void> _close(McpFailure? reason) async {
    final failure = reason ?? const McpFailure('MCP connection closed; an interrupted call may have taken effect');
    lifetime.cancel(failure);
    for (final pending in _pending.values.toList()) {
      if (!pending.result.isCompleted) {
        pending.result.completeError(failure);
      }
    }
    _pending.clear();
    final process = _process;
    if (process != null) {
      // Queue a bounded drain before yielding. An escaped descendant may hold
      // stderr forever; neither dropping diagnostics nor waiting for EOF is OK.
      final drained = _stderrDone.future.timeout(const Duration(milliseconds: 250), onTimeout: () {});
      await process.stop();
      await drained;
      await process.dispose();
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
    _flushStderr();
    if (!closed.isCompleted) closed.complete();
  }
}

class _Pending {
  _Pending(this.method, this.notify);
  final String method;
  final result = Completer<Json>();
  final void Function(Json)? notify;
}

// Codex rmcp-client/utils.rs and network-proxy/certs.rs. CA paths inherited
// from the host are relative to the host cwd, not the server's configured cwd.
const _caEnvironment = ['CODEX_CA_CERTIFICATE', 'SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE',
  'CURL_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS', 'GIT_SSL_CAINFO', 'CARGO_HTTP_CAINFO',
  'PIP_CERT', 'BUNDLE_SSL_CA_CERT', 'npm_config_cafile', 'NPM_CONFIG_CAFILE'];
const _hostOnlyEnvironment = {'codex_exec_server_noise_auth_token', 'node_repl_auth_token',
  'codex_guardian_decisions_api_key', 'openai_federation_rule_id',
  'openai_identity_token_file', 'openai_workload_identity_context'};

Map<String, String> mcpEnvironment(Json config) {
  final defaults = Platform.isWindows ? ['PATH', 'PATHEXT', 'SHELL', 'COMSPEC', 'SYSTEMROOT', 'WINDIR',
    'SYSTEMDRIVE', 'USERNAME', 'USERDOMAIN', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'PROGRAMFILES',
    'PROGRAMFILES(X86)', 'PROGRAMW6432', 'PROGRAMDATA', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP',
    'TMPDIR', 'POWERSHELL', 'PWSH'] : ['PATH', 'HOME', 'LOGNAME', 'USER', 'SHELL',
    '__CF_USER_TEXT_ENCODING', 'LANG', 'LC_ALL', 'TERM', 'TMPDIR', 'TZ'];
  final environment = <String, String>{
    for (final name in [...defaults, ...(config['inherit_env'] as List? ?? []).cast<String>()])
      if (Platform.environment[name] case final String value) name: value,
  };
  for (final name in _caEnvironment) {
    final value = Platform.environment[name];
    if (value == null || value.isEmpty) { environment.remove(name); continue; }
    environment[name] = File(value).absolute.path;
  }
  for (final entry in jsonObject(config['env'] ?? {}).entries) {
    if (Platform.isWindows || _caEnvironment.any((name) => name.toLowerCase() == entry.key.toLowerCase())) {
      environment.removeWhere((name, _) => name.toLowerCase() == entry.key.toLowerCase());
    }
    environment[entry.key] = entry.value as String;
  }
  environment.removeWhere((name, _) => _hostOnlyEnvironment.contains(name.toLowerCase()));
  return environment;
}

String headerValue(Object? value) {
  final text = value is String ? value : jsonEncode(value);
  if (text.trim() != text ||
      text.codeUnits.any((v) => v < 32 || v > 126) ||
      text.startsWith('=?base64?') && text.endsWith('?=')) {
    return '=?base64?${base64.encode(utf8.encode(text))}?=';
  }
  return text;
}

/// Headers are permitted only at property paths made entirely of properties.
Map<String, String> schemaHeaders(Json schema, Object? arguments) {
  final output = <String, String>{}, names = <String>{};
  void visit(Object? node, Object? value, bool allowed) {
    if (node is! Map) return;
    if (node.containsKey('x-mcp-header')) {
      final name = node['x-mcp-header'];
      if (!allowed ||
          name is! String ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$ ".trim()).hasMatch(name) ||
          !names.add(name.toLowerCase()) ||
          !['string', 'integer', 'boolean'].contains(node['type'])) {
        throw const FormatException('Invalid MCP tool header annotation');
      }
      if (value != null) {
        if (node['type'] == 'integer' &&
            (value is! num ||
                value != value.roundToDouble() ||
                value.abs() > 9007199254740991)) {
          throw const FormatException(
            'MCP integer header must be a safe integer',
          );
        }
        output['Mcp-Param-$name'] = headerValue(value);
      }
    }
    for (final entry in node.entries) {
      if (entry.key == 'properties' && entry.value is Map) {
        for (final property in (entry.value as Map).entries) {
          visit(
            property.value,
            value is Map ? value[property.key] : null,
            allowed,
          );
        }
      } else if (entry.value is Map) {
        visit(entry.value, null, false);
      } else if (entry.value is List) {
        for (final child in entry.value as List) {
          visit(child, null, false);
        }
      }
    }
  }

  if (schema.containsKey('x-mcp-header')) {
    throw const FormatException(
      'MCP header annotation cannot be on the schema root',
    );
  }
  visit(schema, arguments, true);
  return output;
}
