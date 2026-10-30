import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart' show decodeSse;
import 'package:protocol/protocol.dart';

const mcpProtocolVersion = '2026-07-28';
const _versionKey = 'io.modelcontextprotocol/protocolVersion';
const _subscriptionKey = 'io.modelcontextprotocol/subscriptionId';

class McpFailure implements Exception {
  const McpFailure(this.message, {this.code, this.status, this.data});
  final String message;
  final int? code, status;
  final Json? data;
  @override
  String toString() => message;
}

/// One shared transport generation. Requests have independent cancellation.
class McpConnection {
  McpConnection(this.config, this.http, this.onNotification);
  final Json config;
  final HttpClient http;
  final void Function(Json) onNotification;
  final lifetime = CancellationToken();
  final _pending = <Object, _Pending>{};
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  Future<void>? _closing;
  final closed = Completer<void>();
  String version = mcpProtocolVersion;
  String? _session;
  Json discovery = {};
  bool get modern => version == mcpProtocolVersion;
  int? get processId => _process?.pid;

  Future<void> connect(CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    if (config['command'] != null) {
      final process =
          await Process.start(
                requiredString(config, 'command'),
                (config['args'] as List? ?? []).cast<String>(),
                workingDirectory: config['cwd'] as String?,
                environment: _environment(),
                includeParentEnvironment: false,
              )
              .then((value) {
                if (cancellation.isCancelled || lifetime.isCancelled) {
                  value.kill(ProcessSignal.sigkill);
                }
                return value;
              })
              .asCancellable(cancellation);
      cancellation.throwIfCancelled();
      _process = process;
      _stderr = process.stderr.listen((_) {});
      _stdout = boundedLines(process.stdout, maxBytes: maxFrameBytes).listen(
        (line) {
          try {
            _receive(jsonObject(jsonDecode(line)));
          } catch (_) {
            unawaited(close());
          }
        },
        onError: (Object _) => unawaited(close()),
        onDone: () => unawaited(close()),
      );
      unawaited(process.exitCode.then((_) => close()));
    } else {
      final uri = Uri.parse(requiredString(config, 'url'));
      if (!{'https', 'http'}.contains(uri.scheme) || uri.userInfo.isNotEmpty) {
        throw ArgumentError(
          'MCP URL must use HTTP(S) without embedded credentials',
        );
      }
    }
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
        throw const McpFailure(
          'MCP server does not support the requested modern protocol',
          code: -32022,
        );
      }
    } on McpFailure catch (error) {
      // Modern errors identify the era. They must never silently downgrade.
      if (error.code != null &&
          error.code! <= -32020 &&
          error.code! >= -32029) {
        rethrow;
      }
      if (error.status == 401 ||
          error.status == 403 ||
          config['legacy_fallback'] == false) {
        rethrow;
      }
      await _legacy(cancellation);
    } on TimeoutException {
      if (_process == null || config['legacy_fallback'] == false) rethrow;
      await _legacy(cancellation);
    }
  }

  Map<String, String> _environment() {
    final result = <String, String>{};
    for (final name in [
      'PATH',
      'HOME',
      'USER',
      'SHELL',
      'TMPDIR',
      'LANG',
      'LC_ALL',
      ...(config['inherit_env'] as List? ?? []).cast<String>(),
    ]) {
      final value = Platform.environment[name];
      if (value != null) result[name] = value;
    }
    for (final entry in jsonObject(config['env'] ?? {}).entries) {
      result[entry.key] = entry.value as String;
    }
    return result;
  }

  Future<void> _legacy(CancellationToken cancellation) async {
    version = '2025-11-25';
    final result = await request('initialize', {
      'protocolVersion': version,
      'capabilities': {},
      'clientInfo': {'name': 'happen', 'version': '0.1.0'},
    }, cancellation: cancellation);
    final selected = result['protocolVersion'];
    if (!['2025-11-25', '2025-06-18', '2025-03-26'].contains(selected)) {
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
  }) async {
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
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': {
        ...params,
        if (modern)
          '_meta': {
            ...jsonObject(params['_meta'] ?? {}),
            _versionKey: version,
            'io.modelcontextprotocol/clientInfo': {
              'name': 'happen',
              'version': '0.1.0',
            },
            'io.modelcontextprotocol/clientCapabilities': {},
          },
      },
    };
    if (utf8.encode(jsonEncode(body)).length > maxFrameBytes) {
      throw const McpFailure('MCP request too large');
    }
    try {
      if (_process != null) {
        final pending = _Pending(onNotification);
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
      return await _http(body, token, onNotification, inputSchema);
    } finally {
      deadline.cancel();
    }
  }

  void _write(Json message) {
    if (lifetime.isCancelled) return;
    _process?.stdin.writeln(jsonEncode(message));
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
      pending.result.complete(_result(message));
    } catch (error, stack) {
      pending.result.completeError(error, stack);
    }
  }

  Json _result(Json message, {int? status}) {
    if (message['error'] is Map) {
      final error = jsonObject(message['error']);
      throw McpFailure(
        'MCP request failed (code ${error['code']})',
        code: error['code'] as int?,
        status: status,
        data: error['data'] is Map ? jsonObject(error['data']) : null,
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
    Json? schema,
  ) async {
    HttpClientRequest? outgoing;
    StreamIterator<Json>? messages;
    Future<void> Function()? closeBody;
    final hook = CancellationHook(
      token,
      () => outgoing?.abort(token.exception),
    );
    try {
      outgoing = await http
          .postUrl(Uri.parse(requiredString(config, 'url')))
          .then((value) {
            if (token.isCancelled) value.abort(token.exception);
            return value;
          })
          .asCancellable(token);
      token.throwIfCancelled();
      outgoing.followRedirects = false;
      outgoing.headers.contentType = ContentType.json;
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
      outgoing.headers.set('MCP-Protocol-Version', version);
      if (_session != null && !modern) {
        outgoing.headers.set('Mcp-Session-Id', _session!);
      }
      if (modern) {
        final method = body['method'] as String;
        final params = jsonObject(body['params']);
        outgoing.headers.set('Mcp-Method', method);
        if (['tools/call', 'resources/read', 'prompts/get'].contains(method)) {
          outgoing.headers.set(
            'Mcp-Name',
            headerValue(params[method == 'resources/read' ? 'uri' : 'name']),
          );
        }
        if (method == 'tools/call' && schema != null) {
          final headers = schemaHeaders(schema, params['arguments']);
          headers.forEach(outgoing.headers.set);
        }
      }
      outgoing.write(jsonEncode(body));
      final response = await outgoing.close().asCancellable(token);
      if (!modern && body['method'] == 'initialize') {
        _session = response.headers.value('Mcp-Session-Id');
      }
      if (!body.containsKey('id') && response.statusCode == 202) return {};
      if (response.headers.contentType?.mimeType != 'text/event-stream') {
        final bytes = <int>[];
        final input = StreamIterator(response);
        try {
          while (await input.moveNext().asCancellable(
            token,
            onCancel: () => unawaited(input.cancel()),
          )) {
            bytes.addAll(input.current);
            if (bytes.length > maxFrameBytes) {
              throw const McpFailure('MCP response too large');
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
          );
        }
        if (message['id'] != body['id'] &&
            !(response.statusCode >= 400 && message['id'] == null)) {
          throw const McpFailure('MCP response ID does not match its request');
        }
        return _result(message, status: response.statusCode);
      }
      if (response.statusCode != 200) {
        throw McpFailure(
          'MCP stream failed (${response.statusCode})',
          status: response.statusCode,
        );
      }
      final input = ownStream(response, token);
      closeBody = input.close;
      messages = StreamIterator(
        decodeSse(input.stream, maxEventBytes: maxFrameBytes),
      );
      while (await messages.moveNext().asCancellable(
        token,
        onCancel: () => unawaited(messages!.cancel()),
      )) {
        final message = messages.current;
        if (message['id'] == body['id']) return _result(message);
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
      await _http(body, token, null, null);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    lifetime.cancel(
      const McpFailure(
        'MCP connection closed; an interrupted call may have taken effect',
      ),
    );
    for (final pending in _pending.values.toList()) {
      if (!pending.result.isCompleted) {
        pending.result.completeError(
          const McpFailure(
            'MCP connection closed; an interrupted call may have taken effect',
          ),
        );
      }
    }
    _pending.clear();
    final process = _process;
    if (process != null) {
      unawaited(process.stdin.close().catchError((Object _) {}));
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        process.kill(ProcessSignal.sigterm);
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
    if (!closed.isCompleted) closed.complete();
  }
}

class _Pending {
  _Pending(this.notify);
  final result = Completer<Json>();
  final void Function(Json)? notify;
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
