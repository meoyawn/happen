import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'model.dart';

/// Both backends share the network owner's pool and release only their request.
Future<({int status, String text, String? contentType})> webSearchRequest(
  HttpClient http,
  Uri endpoint, {
  required CancellationToken cancellation,
  Json? body,
  Map<String, String> headers = const {},
}) async {
  cancellation.throwIfCancelled();
  if (!{'http', 'https'}.contains(endpoint.scheme) || endpoint.host.isEmpty || endpoint.userInfo.isNotEmpty) {
    throw const FormatException('Web request requires an HTTP(S) URL without embedded credentials');
  }
  final deadline = TimeoutCancellationToken(const Duration(seconds: 60));
  final token = cancellation.merge(deadline);
  HttpClientRequest? outgoing;
  Future<void> Function()? closeBody;
  final hook = CancellationHook(token, () => outgoing?.abort(token.exception));
  try {
    outgoing = await http.openUrl(body == null ? 'GET' : 'POST', endpoint).then((request) {
      if (token.isCancelled) request.abort(token.exception);
      return request;
    }).asCancellable(token);
    token.throwIfCancelled();
    outgoing.followRedirects = body == null;
    outgoing.headers
      ..set(HttpHeaders.acceptHeader, body == null ? 'text/html, text/plain, text/markdown' : 'application/json')
      ..set(HttpHeaders.userAgentHeader, 'happen/0.1.0 (Dart)');
    headers.forEach(outgoing.headers.set);
    if (body != null) {
      outgoing.headers.contentType = ContentType.json;
      outgoing.write(jsonEncode(body));
    }
    final response = await outgoing.close().asCancellable(token);
    if (response.statusCode != 200) return (status: response.statusCode, text: '', contentType: null);
    final incoming = ownStream(response, token);
    closeBody = incoming.close;
    const maxBytes = 2 * 1024 * 1024;
    final bytes = <int>[];
    final chunks = StreamIterator(incoming.stream);
    try {
      while (await chunks.moveNext().asCancellable(token)) {
        if (bytes.length + chunks.current.length > maxBytes) {
          throw const ModelFailure('web_search_size', 'Web response exceeded 2 MiB');
        }
        bytes.addAll(chunks.current);
      }
    } finally {
      unawaited(chunks.cancel().catchError((Object _) {}));
    }
    return (status: 200, text: utf8.decode(bytes, allowMalformed: true),
        contentType: response.headers.contentType?.mimeType);
  } catch (error) {
    cancellation.throwIfCancelled();
    if (deadline.isCancelled) {
      throw const ModelFailure('web_search_timeout', 'Web request timed out');
    }
    if (error is ModelFailure) rethrow;
    throw const ModelFailure('web_search_transport', 'Web request failed');
  } finally {
    hook.dispose();
    outgoing?.abort();
    await closeBody?.call();
    deadline.cancel();
  }
}

Future<({int status, Json body})> postWebSearch(
  HttpClient http,
  Uri endpoint,
  Json body, {
  required CancellationToken cancellation,
  Map<String, String> headers = const {},
}) async {
  final response = await webSearchRequest(http, endpoint, body: body,
      cancellation: cancellation, headers: headers);
  if (response.status != 200) return (status: response.status, body: <String, dynamic>{});
  try {
    return (status: 200, body: jsonObject(jsonDecode(response.text)));
  } on FormatException {
    throw const ModelFailure('web_search_response', 'Web search returned an invalid response');
  }
}
