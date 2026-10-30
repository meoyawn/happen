import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';

import 'transport.dart';

/// A client-owned subscription. No event automatically starts a model turn.
class McpEventSubscription {
  McpEventSubscription({
    required this.id,
    required this.owner,
    required this.server,
    required this.name,
    required this.arguments,
    required this.mode,
    required this.connection,
    required this.onEvent,
    this.cursor,
    this.maxAgeMs,
    this.ttlMs,
    this.publicUrl,
  }) {
    if (!['push', 'poll', 'webhook'].contains(mode)) {
      throw ArgumentError('Unknown MCP event delivery mode');
    }
    if (maxAgeMs != null && maxAgeMs! < 0 || ttlMs != null && ttlMs! < 1000) {
      throw ArgumentError('Invalid MCP event lifetime');
    }
    if (mode == 'webhook') {
      final base = Uri.parse(publicUrl ?? '');
      if (base.scheme != 'https' ||
          base.host.isEmpty ||
          base.userInfo.isNotEmpty ||
          base.hasQuery ||
          base.hasFragment) {
        throw ArgumentError(
          'Webhook events need an HTTPS public_url for this harness',
        );
      }
      callback =
          '${publicUrl!.replaceFirst(RegExp(r'/+$'), '')}/mcp-events/$id';
      secret = List.generate(32, (_) => Random.secure().nextInt(256));
    }
  }
  final String id, owner, server, name, mode;
  final Json arguments;
  final int? maxAgeMs, ttlMs;
  final String? publicUrl;
  final Future<McpConnection> Function(CancellationToken) connection;
  final void Function(Json) onEvent;
  final lifetime = CancellationToken();
  final ready = Completer<void>();
  final _seen = <String>{};
  String? cursor, callback, upstreamId;
  List<int>? secret;
  Future<void>? _running, _stopping;
  String state = 'starting';
  bool _terminated = false, _webhookAttempted = false;

  Json get _params => {
    'name': name,
    'arguments': arguments,
    'cursor': cursor,
    if (maxAgeMs != null) 'maxAgeMs': maxAgeMs,
  };
  Json toJson() => {
    'subscription_id': id,
    'server': server,
    'name': name,
    'mode': mode,
    'state': state,
    'cursor': cursor,
  };

  Future<void> start(CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    final hook = CancellationHook(cancellation, lifetime.cancel);
    _running = _run();
    try {
      await ready.future.asCancellable(cancellation);
    } finally {
      hook.dispose();
    }
  }

  void _emit(String method, Json params) => onEvent({
    'type': 'mcp.event',
    'subscription_id': id,
    'server': server,
    'notification': {'method': method, 'params': params},
  });

  void _active(Json params) {
    if (params.containsKey('cursor')) cursor = params['cursor'] as String?;
    state = 'active';
    _emit('notifications/events/active', params);
    if (!ready.isCompleted) ready.complete();
  }

  void _event(Json params) {
    if (state != 'active') {
      throw const McpFailure('MCP event arrived before activation');
    }
    final eventId = requiredString(params, 'eventId');
    if (params['name'] != name ||
        params['data'] is! Map ||
        DateTime.tryParse(requiredString(params, 'timestamp')) == null ||
        utf8.encode(jsonEncode(params)).length > 256 * 1024) {
      throw const McpFailure('Invalid or oversized MCP event');
    }
    if (_seen.add(eventId)) {
      if (_seen.length > 2048) _seen.remove(_seen.first);
      _emit('notifications/events/event', params);
    }
    if (params.containsKey('cursor')) cursor = params['cursor'] as String?;
  }

  Future<void> _run() async {
    try {
      switch (mode) {
        case 'push':
          await _push();
        case 'poll':
          await _poll();
        case 'webhook':
          await _webhooks();
      }
      state = 'terminated';
    } catch (error) {
      state = lifetime.isCancelled ? 'stopped' : 'failed';
      if (!ready.isCompleted) {
        ready.completeError(error);
      } else if (!lifetime.isCancelled && !_terminated) {
        _emit('notifications/events/terminated', {
          'error': {
            'message': 'MCP event subscription ended after a transport or protocol failure',
          },
        });
      }
    } finally {
      if (!ready.isCompleted) {
        ready.completeError(
          const McpFailure('MCP event subscription ended before activation'),
        );
      }
    }
  }

  Future<void> _push() async {
    var failures = 0;
    while (!lifetime.isCancelled) {
      final attempt = CancellationToken();
      final token = lifetime.merge(attempt);
      final connected = Stopwatch()..start();
      var active = false;
      Timer? liveness;
      final activation = Timer(
        const Duration(seconds: 15),
        () => attempt.cancel(
          TimeoutException('MCP event stream did not activate'),
        ),
      );
      void heartbeat() {
        liveness?.cancel();
        liveness = Timer(
          const Duration(seconds: 65),
          () => attempt.cancel(
            TimeoutException('MCP event stream heartbeat expired'),
          ),
        );
      }

      try {
        final peer = await connection(token);
        await peer.request(
          'events/stream',
          _params,
          cancellation: token,
          timeout: null,
          onNotification: (notification) {
            try {
              final method = notification['method'];
              final params = jsonObject(notification['params'] ?? {});
              switch (method) {
                case 'notifications/events/active':
                  active = true;
                  activation.cancel();
                  heartbeat();
                  _active(params);
                case 'notifications/events/event':
                  if (!active) {
                    throw const McpFailure(
                      'MCP event arrived before activation',
                    );
                  }
                  heartbeat();
                  _event(params);
                case 'notifications/events/heartbeat':
                  if (!active) {
                    throw const McpFailure(
                      'MCP heartbeat arrived before activation',
                    );
                  }
                  heartbeat();
                  if (params.containsKey('cursor')) {
                    cursor = params['cursor'] as String?;
                  }
                  _emit(method as String, params);
                case 'notifications/events/error':
                  _emit(method as String, params);
                case 'notifications/events/terminated':
                  _terminated = true;
                  _emit(method as String, params);
                  attempt.cancel();
              }
            } catch (error) {
              attempt.cancel(
                error is Exception
                    ? error
                    : const McpFailure('Invalid MCP event notification'),
              );
            }
          },
        );
      } catch (error) {
        if (_terminated) return;
        lifetime.throwIfCancelled();
        if (error is McpFailure &&
            [-32602, -32023, -32024, -32026].contains(error.code)) {
          rethrow;
        }
      } finally {
        activation.cancel();
        liveness?.cancel();
        attempt.cancel();
      }
      if (_terminated) return;
      if (connected.elapsed > const Duration(minutes: 1)) failures = 0;
      if (++failures > 5) {
        throw const McpFailure('MCP event reconnect budget exhausted');
      }
      state = 'reconnecting';
      _emit('connection/reconnecting', {'cursor': cursor, 'attempt': failures});
      await cancellableDelay(
        Duration(milliseconds: 250 * (1 << (failures - 1))),
        lifetime,
      );
    }
  }

  Future<void> _poll() async {
    var failures = 0;
    while (!lifetime.isCancelled) {
      try {
        final peer = await connection(lifetime);
        final result = await peer.request('events/poll', {
          ..._params,
          'maxEvents': 50,
        }, cancellation: lifetime);
        final events = result['events'];
        if (events is! List || events.length > 50) {
          throw const McpFailure('Invalid MCP poll result');
        }
        if (!ready.isCompleted || result['truncated'] == true) {
          _active({'cursor': cursor, 'truncated': result['truncated'] == true});
        }
        state = 'active';
        for (final raw in events) {
          _event(jsonObject(raw));
        }
        cursor = result['cursor'] as String?;
        _emit('notifications/events/heartbeat', {'cursor': cursor});
        failures = 0;
        final delay = result['hasMore'] == true
            ? 0
            : (result['nextPollMs'] as num? ?? 30000).toInt().clamp(
                1000,
                86400000,
              );
        await cancellableDelay(Duration(milliseconds: delay), lifetime);
      } catch (error) {
        lifetime.throwIfCancelled();
        if (error is McpFailure &&
            [-32602, -32023, -32024, -32026].contains(error.code)) {
          rethrow;
        }
        if (++failures > 5) rethrow;
        state = 'reconnecting';
        await cancellableDelay(
          Duration(milliseconds: 250 * (1 << (failures - 1))),
          lifetime,
        );
      }
    }
  }

  Future<void> _webhooks() async {
    var failures = 0;
    while (!lifetime.isCancelled && !_terminated) {
      try {
        final peer = await connection(lifetime);
        _webhookAttempted = true;
        final result = await peer.request('events/subscribe', {
          ..._params,
          'delivery': {
            'mode': 'webhook',
            'url': callback,
            'secret': 'whsec_${base64.encode(secret!)}',
          },
          'ttlMs': ttlMs,
        }, cancellation: lifetime);
        final id = requiredString(result, 'id');
        if (upstreamId != null && upstreamId != id) {
          throw const McpFailure('Webhook subscription identity changed');
        }
        upstreamId = id;
        _active({
          'cursor': result['cursor'],
          'truncated': result['truncated'] == true,
        });
        failures = 0;
        final refresh = result['refreshBefore'];
        if (refresh == null) {
          if (ttlMs != null) {
            throw const McpFailure(
              'MCP server granted an unsolicited indefinite subscription',
            );
          }
          await Completer<void>().future.asCancellable(lifetime);
        } else {
          final expires = DateTime.parse(refresh as String);
          final wait = expires.difference(DateTime.now()).inMilliseconds;
          if (wait <= 0) {
            throw const McpFailure('MCP webhook subscription already expired');
          }
          await cancellableDelay(
            Duration(milliseconds: (wait * .8).round().clamp(100, 86400000)),
            lifetime,
          );
        }
      } catch (error) {
        lifetime.throwIfCancelled();
        if (error is McpFailure &&
            [-32602, -32023, -32024, -32026].contains(error.code)) {
          rethrow;
        }
        if (++failures > 5) rethrow;
        await cancellableDelay(
          Duration(milliseconds: 250 * (1 << (failures - 1))),
          lifetime,
        );
      }
    }
  }

  /// Runs only after the HTTP owner has enforced the body bound. Headers and
  /// signing material are never sent to model history or ordinary event output.
  Json webhook(Json headers, List<int> body) {
    if (mode != 'webhook' || lifetime.isCancelled || _terminated) {
      return {'status': 410};
    }
    if (body.length > 256 * 1024) return {'status': 413};
    try {
      final eventId = requiredString(headers, 'webhook-id');
      final stamp = requiredString(headers, 'webhook-timestamp');
      final timestamp = int.parse(stamp);
      if ((DateTime.now().millisecondsSinceEpoch ~/ 1000 - timestamp).abs() >
          300) {
        return {'status': 401};
      }
      final remote = requiredString(headers, 'x-mcp-subscription-id');
      if (upstreamId != null && upstreamId != remote) return {'status': 401};
      final expected = Hmac(
        sha256,
        secret!,
      ).convert([...utf8.encode('$eventId.$stamp.'), ...body]).bytes;
      var valid = false;
      for (final signature in requiredString(
        headers,
        'webhook-signature',
      ).split(' ')) {
        if (!signature.startsWith('v1,')) continue;
        final decoded = base64.decode(signature.substring(3));
        var diff = expected.length ^ decoded.length;
        for (var i = 0; i < expected.length; i++) {
          diff |= expected[i] ^ (i < decoded.length ? decoded[i] : 0);
        }
        valid |= diff == 0;
      }
      if (!valid) return {'status': 401};
      final value = jsonObject(jsonDecode(utf8.decode(body)));
      if (value['type'] == 'verification') {
        upstreamId ??= remote;
        return {
          'status': 200,
          'body': {'challenge': requiredString(value, 'challenge')},
        };
      }
      // A server may deliver before events/subscribe's response arrives. The
      // signed callback has already proved ownership of this subscription.
      upstreamId ??= remote;
      if (state == 'starting') _active({'cursor': cursor});
      switch (value['type']) {
        case 'gap':
          _active({'cursor': value['cursor'], 'truncated': true});
        case 'terminated':
          _terminated = true;
          state = 'terminated';
          _emit('notifications/events/terminated', {'error': value['error']});
        case null:
          if (value['eventId'] != eventId) return {'status': 400};
          _event(value);
        default:
          return {'status': 400};
      }
      return {'status': 200, 'body': {}};
    } catch (_) {
      return {'status': 400};
    }
  }

  Future<void> stop() => _stopping ??= _stop();
  Future<void> _stop() async {
    lifetime.cancel();
    await _running;
    if (mode == 'webhook' && _webhookAttempted && !_terminated) {
      final cancellation = TimeoutCancellationToken(const Duration(seconds: 5));
      try {
        final peer = await connection(cancellation);
        await peer.request('events/unsubscribe', {
          'name': name,
          'arguments': arguments,
          'delivery': {'mode': 'webhook', 'url': callback},
        }, cancellation: cancellation);
      } catch (_) {
        /* Finite subscriptions also expire if cleanup cannot reach the server. */
      } finally {
        cancellation.cancel();
      }
    }
    state = 'stopped';
    secret = null;
  }
}
