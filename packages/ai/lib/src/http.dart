import 'dart:async';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

/// Response metadata and bytes from Dart's native HTTP client.
class HttpReply extends StreamView<List<int>> {
  HttpReply(super.stream, this.statusCode, this.headers, this.version, {this.reasonPhrase = ''});
  final int statusCode;
  final Map<String, String> headers;
  final String version;
  final String reasonPhrase;
}

Future<HttpReply> _send(HttpClient http, String method, Uri uri,
  CancellationToken cancellation, Map<String, String> headers, List<int> body) async {
  final request = await http.openUrl(method, uri).then((value) {
    if (cancellation.isCancelled) value.abort(cancellation.exception);
    return value;
  }).asCancellable(cancellation);
  try {
    cancellation.throwIfCancelled();
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.contentLength = body.length;
    if (body.isNotEmpty) request.add(body);
    final response = await request.close().then((value) {
      if (cancellation.isCancelled) unawaited(value.listen((_) {}).cancel());
      return value;
    }).asCancellable(cancellation,
      onCancel: () => request.abort(cancellation.exception));
    final fields = <String, String>{};
    response.headers.forEach((name, values) => fields[name.toLowerCase()] = values.join(', '));
    final incoming = ownStream(response, cancellation);
    return HttpReply(incoming.stream, response.statusCode, fields, '1.1', reasonPhrase: response.reasonPhrase);
  } catch (_) {
    request.abort();
    cancellation.throwIfCancelled();
    rethrow;
  }
}

/// The caller owns the HttpClient; Dart manages connection reuse and idle expiry.
Future<HttpReply> httpRequest(HttpClient http, String method, Uri uri, {
  required CancellationToken cancellation,
  Map<String, String> headers = const {},
  List<int> body = const [],
  Duration? headersTimeout,
  bool followRedirects = false,
}) async {
  final deadline = CancellationToken();
  final timer = headersTimeout == null ? null : Timer(headersTimeout,
    () => deadline.cancel(TimeoutException('HTTP response headers timed out')));
  final token = cancellation.merge(deadline);
  try {
    for (var redirects = 0; ; redirects++) {
      token.throwIfCancelled();
      if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
        throw const FormatException('HTTP request requires an HTTP(S) URL without embedded credentials');
      }
      final span = startTraceSpan('http.$method', category: 'http',
        attributes: {'http.request.method': method, 'server.address': uri.host,
          'url.path': uri.path, 'http.request.body.size': body.length});
      late HttpReply response;
      try {
        response = await withTrace(span?.context ?? currentTrace, () async =>
          await _send(http, method, uri, token, headers, body));
        span?.end(attributes: {'http.response.status_code': response.statusCode, 'network.protocol.version': response.version});
      } catch (error) { span?.end(error: error); rethrow; }
      response = HttpReply(withTrace(span?.context ?? currentTrace, () =>
        traceStream(response, 'http.body', size: (chunk) => chunk.length, cancellation: cancellation,
          attributes: {'http.response.status_code': response.statusCode})),
        response.statusCode, response.headers, response.version, reasonPhrase: response.reasonPhrase);
      if (!followRedirects || method != 'GET' || !{301, 302, 303, 307, 308}.contains(response.statusCode) ||
          response.headers['location'] == null) { return response; }
      await response.listen((_) {}).cancel();
      if (redirects >= 5) { throw const HttpException('Too many redirects'); }
      final next = uri.resolve(response.headers['location']!);
      if (next.origin != uri.origin) {
        headers = {
          for (final entry in headers.entries)
            if (!RegExp(r'authorization|cookie|token|api.key', caseSensitive: false).hasMatch(entry.key)) entry.key: entry.value,
        };
      }
      uri = next;
    }
  } finally {
    timer?.cancel();
  }
}
