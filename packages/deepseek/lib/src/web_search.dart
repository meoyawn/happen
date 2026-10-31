import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:protocol/protocol.dart';

import '../opencode.dart';

Future<String> openCodeWebSearch(
  HttpClient http,
  OpenCodeAuthManager? auth,
  Json commands, {
  required CancellationToken cancellation,
  Uri? endpoint,
}) async {
  cancellation.throwIfCancelled();
  webSearchCommands(commands);
  for (final entry in commands.entries) {
    if (!{'search_query', 'open', 'find', 'response_length'}.contains(entry.key) &&
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
