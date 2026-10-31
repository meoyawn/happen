import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:protocol/protocol.dart';

import '../auth.dart';

Future<Json> openCodeFetch(HttpClient http, Json input, CancellationToken cancellation) async {
  final url = Uri.parse(_pageUrl(requiredString(input, 'url')));
  final deadline = TimeoutCancellationToken(Duration(milliseconds: ((input['timeout'] as num? ?? 30) * 1000).round()));
  final token = cancellation.merge(deadline);
  HttpClientRequest? outgoing;
  Future<void> Function()? closeBody;
  final hook = CancellationHook(token, () => outgoing?.abort(token.exception));
  try {
    outgoing = await http.openUrl(input['method'] as String? ?? 'GET', url).then((request) {
      if (token.isCancelled) request.abort(token.exception);
      return request;
    }).asCancellable(token);
    token.throwIfCancelled();
    outgoing.headers.set(HttpHeaders.acceptHeader, input['format'] == 'html' ? 'text/html, */*;q=0.1'
      : 'text/markdown, text/plain, text/html, */*;q=0.1');
    for (final entry in jsonObject(input['headers'] ?? {}).entries) {
      outgoing.headers.set(entry.key, entry.value as String);
    }
    if (input['body'] != null) outgoing.write(input['body'] as String);
    final response = await outgoing.close().asCancellable(token);
    final incoming = ownStream(response, token);
    closeBody = incoming.close;
    final bytes = <int>[];
    await for (final chunk in incoming.stream) {
      token.throwIfCancelled();
      if (bytes.length + chunk.length > 5 * 1024 * 1024) {
        throw const ModelFailure('web_fetch_size', 'Web response exceeded 5 MiB');
      }
      bytes.addAll(chunk);
    }
    final headers = <String, String>{};
    response.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(', '));
    return {'url': url.toString(), 'status': response.statusCode, 'statusText': response.reasonPhrase,
      'headers': headers, 'body': utf8.decode(bytes, allowMalformed: true)};
  } catch (error) {
    cancellation.throwIfCancelled();
    if (deadline.isCancelled) throw const ModelFailure('web_fetch_timeout', 'Web request timed out');
    if (error is ModelFailure) rethrow;
    throw const ModelFailure('web_fetch_transport', 'Web request failed');
  } finally {
    hook.dispose(); outgoing?.abort(); await closeBody?.call(); deadline.cancel();
  }
}

Future<String> openCodeWebSearch(
  HttpClient http,
  OpenCodeAuthManager? auth,
  Json commands, {
  required CancellationToken cancellation,
  Uri? endpoint,
}) async {
  cancellation.throwIfCancelled();
  if (commands['fetch'] != null) return jsonEncode(await openCodeFetch(http, jsonObject(commands['fetch']), cancellation));
  if (commands['url'] != null) {
    final response = await openCodeFetch(http, commands, cancellation);
    if ((response['status'] as int) < 200 || (response['status'] as int) >= 300) {
      throw ModelFailure('web_fetch_http', 'Page retrieval failed (HTTP ${response['status']})');
    }
    final text = response['body'] as String;
    final type = (response['headers'] as Map)['content-type'] as String? ?? '';
    return commands['format'] == 'html' || !type.contains('html') ? text
      : _pageText(text, Uri.parse(commands['url'] as String));
  }
  for (final entry in commands.entries) {
    if (!{'query', 'search_query', 'open', 'find', 'response_length'}.contains(entry.key) &&
        (entry.value as List).isNotEmpty) {
      throw ModelFailure('web_search_unsupported',
          'The configured search backend does not support ${entry.key}. Use search_query, open, or find.');
    }
  }
  final length = commands['response_length'] ?? 'medium';
  final characters = length == 'short' ? 800 : length == 'long' ? 4000 : 2000;
  Future<String> search(Json query) async {
    if (auth == null) {
      throw const ModelFailure('web_search_auth', 'Sign in to OpenCode Console for DeepSeek web search');
    }
    final domains = (query['domains'] as List? ?? []).cast<String>();
    final since = query['recency'] == null ? null
        : DateTime.now().toUtc().subtract(Duration(days: query['recency'] as int));
    final question = [
      query['q'] as String,
      if (domains.isNotEmpty) '(${domains.map((domain) => 'site:$domain').join(' OR ')})',
      if (since != null) 'after:${since.toIso8601String().substring(0, 10)}',
    ].join(' ');
    for (var attempt = 0; attempt < 2; attempt++) {
      final credentials = await auth.credentials(refresh: attempt != 0).asCancellable(cancellation);
      final response = await postWebSearch(http, endpoint ?? Uri.parse('${auth.endpoint}/api/websearch'), {
        'query': question, 'providerID': 'opencode',
      }, cancellation: cancellation, headers: {
        HttpHeaders.authorizationHeader: 'Bearer ${requiredString(credentials, 'access_token')}',
        'x-org-id': requiredString(credentials, 'org_id'),
      });
      if (response.status == 401 && attempt == 0) continue;
      if (response.status != 200) {
        throw ModelFailure('web_search_http',
          'OpenCode search failed (HTTP ${response.status}). Enable Hosted Web Search in Console, or use an available configured search tool.');
      }
      final body = response.body;
      if (body['providerID'] != 'opencode' || body['results'] is! List) {
        throw const ModelFailure('web_search_response', 'OpenCode search returned an invalid response');
      }
      final results = <String>[];
      for (final raw in (body['results'] as List).take(8)) {
        final result = jsonObject(raw);
        final url = _pageUrl(requiredString(result, 'url'));
        final host = Uri.parse(url).host.toLowerCase();
        if (domains.isNotEmpty && !domains.any((domain) =>
            host == domain.toLowerCase() || host.endsWith('.${domain.toLowerCase()}'))) {
          continue;
        }
        final time = jsonObject(result['time'] ?? {})['published'];
        final published = time is num && time.isFinite
            ? DateTime.fromMillisecondsSinceEpoch(time.toInt(), isUtc: true) : null;
        if (since != null && (published == null || published.isBefore(since))) {
          continue;
        }
        final title = result['title'] as String? ?? url;
        final content = result['content'] as String? ?? '';
        results.add('## [$title]($url)\nURL: $url'
            '${published == null ? '' : '\nPublished: ${published.toIso8601String()}'}'
            '\n${clippedText(content, characters * 4)}');
      }
      if (commands['query'] != null) {
        return results.isEmpty ? 'No search results found. Please try a different query.' : results.join('\n\n');
      }
      return 'Search via OpenCode: ${query['q']}\n${results.isEmpty ? 'No search results found.' : results.join('\n\n')}';
    }
    throw const ModelFailure('web_search_auth', 'OpenCode search authentication failed');
  }

  Future<String> page(Json operation, bool find) async {
    final url = _pageUrl(requiredString(operation, 'ref_id'));
    final response = await webSearchRequest(http, Uri.parse(url), cancellation: cancellation);
    if (response.status != 200) {
      throw ModelFailure('web_fetch_http', 'Page retrieval failed (HTTP ${response.status})');
    }
    final type = response.contentType ?? 'text/plain';
    if (!type.startsWith('text/') && !{'application/xhtml+xml', 'application/json'}.contains(type)) {
      throw const ModelFailure('web_fetch_type', 'Only text and HTML pages can be opened by this provider');
    }
    final text = type.contains('html') ? _pageText(response.text, Uri.parse(url)) : response.text;
    final lines = const LineSplitter().convert(text);
    final selected = <int>{};
    if (find) {
      final pattern = requiredString(operation, 'pattern');
      for (final match in RegExp(RegExp.escape(pattern), caseSensitive: false).allMatches(text).take(4)) {
        final line = '\n'.allMatches(text.substring(0, match.start)).length;
        for (var i = (line - 3).clamp(0, lines.length); i < (line + 5).clamp(0, lines.length); i++) {
          selected.add(i);
        }
      }
    } else {
      final start = (operation['lineno'] as int? ?? 0).clamp(0, lines.length);
      final window = length == 'short' ? 60 : length == 'long' ? 240 : 120;
      for (var i = start; i < (start + window).clamp(0, lines.length); i++) {
        selected.add(i);
      }
    }
    return 'Source: $url\nTotal lines: ${lines.length}\n'
        '${selected.isEmpty ? (find ? 'No matching text found.' : 'No lines at this position.') : selected.map((i) => 'L$i: ${lines[i]}').join('\n')}';
  }

  if (commands['query'] != null) return search({'q': requiredString(commands, 'query')});
  final results = await Future.wait([
    for (final raw in commands['search_query'] as List? ?? []) search(jsonObject(raw)),
    for (final raw in commands['open'] as List? ?? []) page(jsonObject(raw), false),
    for (final raw in commands['find'] as List? ?? []) page(jsonObject(raw), true),
  ]);
  cancellation.throwIfCancelled();
  return clippedText(results.join('\n\n'));
}

String _pageUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException('OpenCode open/find requires a source HTTP(S) URL');
  }
  return value;
}

String _pageText(String source, Uri url) {
  final document = html.parse(source);
  for (final element in document.querySelectorAll('script,style,noscript,nav,header,footer,svg')) {
    element.remove();
  }
  String text(dom.Node node) {
    if (node is dom.Text) return node.data;
    final content = node.nodes.map(text).join();
    if (node is! dom.Element) return content;
    if (node.localName == 'br') return '\n';
    if (node.attributes['href'] case final String href when node.localName == 'a') {
      final target = url.resolve(href);
      if ({'http', 'https'}.contains(target.scheme)) return '[$content]($target)';
    }
    return {'p', 'div', 'section', 'article', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'pre', 'tr'}.contains(node.localName)
        ? '\n$content\n' : content;
  }
  return text(document.querySelector('main') ?? document.querySelector('article') ?? document.body ?? document)
      .replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n+'), '\n\n').trim();
}
