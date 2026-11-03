import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart';

const _traceKey = #happenTrace;
final _random = Random.secure();
String traceId([int bytes = 16]) => List.generate(bytes,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
int traceTime() => DateTime.now().toUtc().microsecondsSinceEpoch;

const traceServices = {
  'desktop': 1, 'server': 2, 'storage': 3, 'agent': 4,
  'openai': 5, 'network': 6, 'desktop.storage': 7,
};

/// The carrier is explicit at socket and isolate boundaries. It contains no
/// prompt, model output, SQL bindings, HTTP headers, or credentials.
class TraceContext {
  TraceContext({required this.sink, required this.service, String? trace,
    this.span, this.session}) : trace = trace ?? traceId();
  final SendPort sink;
  final String service, trace;
  final String? span;
  String? session;

  Map<String, dynamic> carrier({bool local = true}) => {
    'trace_id': trace, 'span_id': ?span, 'session_id': ?session,
    if (local) 'sink': sink,
  };
}

TraceContext? get currentTrace => Zone.current[_traceKey] as TraceContext?;

TraceContext? traceContextFrom(Object? carrier, {SendPort? sink, String? service}) {
  if (carrier is! Map) return null;
  final trace = carrier['trace_id'];
  final span = carrier['span_id'];
  if (trace is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(trace) ||
      span != null && (span is! String || !RegExp(r'^[a-f0-9]{16}$').hasMatch(span))) {
    return null;
  }
  final target = sink ?? carrier['sink'];
  if (target is! SendPort) return null;
  return TraceContext(sink: target, service: service ?? 'network', trace: trace,
    span: span as String?, session: carrier['session_id'] is String ? carrier['session_id'] as String : null);
}

T withTrace<T>(TraceContext? context, T Function() action) =>
  runZoned(action, zoneValues: {_traceKey: context});

void bindTraceSession(String session) {
  final context = currentTrace;
  if (context == null) return;
  context.session = session;
  context.sink.send({'bind': context.trace, 'session': session});
}

void _record(TraceContext context, Map<String, dynamic> event) {
  context.sink.send({
    'event': {
      'pid': traceServices[context.service] ?? 6,
      'tid': Isolate.current.hashCode,
      'ts': traceTime(),
      ...event,
      'args': {
        'trace_id': context.trace, 'span_id': ?context.span,
        'session_id': ?context.session, 'service': context.service,
        ...?event['args'] as Map<String, dynamic>?,
      },
    },
    'trace': context.trace, 'session': context.session,
  });
}

void traceInstant(String name, {String category = 'session', Map<String, dynamic> attributes = const {}}) {
  final context = currentTrace;
  if (context != null) _record(context, {'name': name, 'cat': category, 'ph': 'i', 's': 't', 'args': attributes});
}

String traceErrorMessage(Object error) {
  var message = switch (error) {
    FormatException(:final message) => message,
    ArgumentError(:final message) => '$message',
    StateError(:final message) => message,
    _ => error.toString(),
  };
  message = message.replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._~+/-]+=*', caseSensitive: false), 'Bearer [redacted]');
  message = message.replaceAllMapped(RegExp(
    r'(authorization|api[-_]?key|access[-_]?token|refresh[-_]?token|password|secret)["\s:=]+[^\s,;}]+',
    caseSensitive: false), (match) => '${match[1]}=[redacted]');
  message = message.replaceAllMapped(RegExp(r'https?://[^\s)]+'), (match) {
    final uri = Uri.tryParse(match[0]!);
    return uri == null ? '[url]' : uri.replace(userInfo: '', query: '', fragment: '').toString();
  });
  return message.length > 512 ? '${message.substring(0, 512)}…' : message;
}

void traceError(Object error) => traceInstant('operation.error', attributes: {
  'status': error is CancelledException ? 'cancelled' : 'error',
  'error.type': error.runtimeType.toString(), 'error.message': traceErrorMessage(error),
});

/// Flow arrows connect the actual send and receive, including time spent in
/// server backpressure queues. The send timestamp is diagnostic across hosts;
/// span durations always use a monotonic stopwatch.
Map<String, dynamic>? traceSend(String transport, {Map<String, dynamic> attributes = const {}}) {
  final context = currentTrace;
  if (context == null) return null;
  final flow = traceId(8);
  _record(context, {'name': transport, 'cat': transport, 'ph': 's', 'id': flow, 'args': attributes});
  return {...context.carrier(local: false), 'flow_id': flow, 'sent_us': traceTime()};
}

void traceReceive(Object? carrier, String transport, {Map<String, dynamic> attributes = const {}}) {
  final context = currentTrace;
  if (context == null || carrier is! Map || carrier['flow_id'] is! String) return;
  _record(context, {'name': transport, 'cat': transport, 'ph': 'f', 'bp': 'e',
    'id': carrier['flow_id'], 'args': {
      ...attributes, 'sender_time_us': carrier['sent_us'],
      if (carrier['sent_us'] is int) 'transit_us': traceTime() - (carrier['sent_us'] as int),
    }});
}

class TraceSpan {
  TraceSpan._(this.context, this.name, this.category, this.started, this.watch);
  final TraceContext context;
  final String name, category;
  final int started;
  final Stopwatch watch;
  bool _ended = false;

  void end({Object? error, Map<String, dynamic> attributes = const {}, int? durationUs}) {
    if (_ended) return;
    _ended = true;
    watch.stop();
    _record(context, {'name': name, 'cat': category, 'ph': 'e', 'id': context.span,
      'ts': started + (durationUs ?? watch.elapsedMicroseconds),
      'args': {
        ...attributes, 'duration_us': durationUs ?? watch.elapsedMicroseconds,
        'status': error == null ? 'ok' : error is CancelledException ? 'cancelled' : 'error',
        if (error != null) 'error.type': error.runtimeType.toString(),
        if (error != null) 'error.message': traceErrorMessage(error),
      }});
  }
}

TraceSpan? startTraceSpan(String name, {String category = 'session',
  Map<String, dynamic> attributes = const {}}) {
  final parent = currentTrace;
  if (parent == null) return null;
  final context = TraceContext(sink: parent.sink, service: parent.service,
    trace: parent.trace, span: traceId(8), session: parent.session);
  final started = traceTime();
  _record(context, {'name': name, 'cat': category, 'ph': 'b', 'id': context.span,
    'ts': started, 'args': {'parent_span_id': ?parent.span, ...attributes}});
  return TraceSpan._(context, name, category, started, Stopwatch()..start());
}

T traceSync<T>(String name, T Function() action, {String category = 'session',
  Map<String, dynamic> attributes = const {}}) {
  final span = startTraceSpan(name, category: category, attributes: attributes);
  if (span == null) return action();
  try {
    final result = withTrace(span.context, action);
    span.end();
    return result;
  } catch (error) { span.end(error: error); rethrow; }
}

Future<T> traceAsync<T>(String name, Future<T> Function() action, {String category = 'session',
  Map<String, dynamic> attributes = const {}}) async {
  final span = startTraceSpan(name, category: category, attributes: attributes);
  if (span == null) return action();
  try {
    final result = await withTrace(span.context, action);
    span.end();
    return result;
  } catch (error) { span.end(error: error); rethrow; }
}

Future<T> traceIncoming<T>(Map<String, dynamic> request, Future<T> Function() action, {required String service}) {
  final context = traceContextFrom(request['_trace'], service: service);
  return withTrace(context, () {
    traceReceive(request['_trace'], 'isolate');
    return traceAsync('$service.${request['method']}', action, category: 'isolate');
  });
}

Map<String, dynamic>? traceIsolateCarrier([String? method]) {
  final context = currentTrace;
  if (context == null) return null;
  return {...?traceSend('isolate', attributes: {'rpc.method': ?method}), 'sink': context.sink};
}

Stream<T> traceStream<T>(Stream<T> source, String name, {String category = 'http',
  int Function(T)? size, CancellationToken? cancellation, Map<String, dynamic> attributes = const {}}) {
  final parent = currentTrace;
  if (parent == null) return source;
  return Stream<T>.multi((controller) {
    final span = withTrace(parent, () => startTraceSpan(name, category: category, attributes: attributes))!;
    var chunks = 0, bytes = 0;
    final subscription = source.listen((value) {
      final length = size?.call(value) ?? 0;
      chunks++;
      bytes += length;
      withTrace(span.context, () => traceInstant('$name.chunk', category: category,
        attributes: {'chunk': chunks, 'bytes': length}));
      controller.addSync(value);
    }, onError: (Object error, StackTrace stack) {
      span.end(error: error, attributes: {'chunks': chunks, 'bytes': bytes});
      controller.addErrorSync(error, stack);
    }, onDone: () {
      span.end(attributes: {'chunks': chunks, 'bytes': bytes, 'stream.end': 'eof'});
      controller.closeSync();
    });
    controller.onPause = subscription.pause;
    controller.onResume = subscription.resume;
    controller.onCancel = () async {
      final cancelled = cancellation?.isCancelled == true;
      await subscription.cancel();
      span.end(error: cancelled ? CancelledException() : null,
        attributes: {'chunks': chunks, 'bytes': bytes, 'stream.end': cancelled ? 'cancelled' : 'consumer_closed'});
    };
  });
}

List<Map<String, dynamic>> traceProcessMetadata() => [
  for (final entry in traceServices.entries)
    {'name': 'process_name', 'ph': 'M', 'pid': entry.value, 'tid': 0, 'args': {'name': entry.key}},
];
