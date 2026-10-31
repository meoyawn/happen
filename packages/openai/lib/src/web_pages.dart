import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:protocol/protocol.dart';

// The hosted reader can reject a publicly reachable URL with HTTP 200. Recover
// only its explicit open/find failure blocks, leaving other results untouched.
Future<String> recoverWebPages(HttpClient http, Json commands, String output, {
  required CancellationToken cancellation,
}) async {
  final failures = RegExp(r'Internal Error[^\n]*\n[^\n]*Source: (open|find)\((\{[^\n]*\})\);[ \t]*\nURL ([^\n]+) is not accessible via this tool\.');
  final pages = <Uri, Future<List<String>>>{};
  final recovered = StringBuffer();
  var end = 0;
  for (final match in failures.allMatches(output)) {
    cancellation.throwIfCancelled();
    recovered.write(output.substring(end, match.start));
    var replacement = match.group(0)!;
    try {
      final operation = match.group(1)!;
      final arguments = jsonObject(jsonDecode(match.group(2)!));
      final ref = requiredString(arguments, 'ref_id');
      final url = Uri.tryParse(ref);
      final requested = (commands[operation] as List? ?? []).any((value) =>
          value['ref_id'] == ref && (operation == 'find' ? value['pattern'] == arguments['pattern']
            : (value['lineno'] ?? 0) == (arguments['lineno'] ?? 0)));
      if (requested && ref == match.group(3) && url != null &&
          {'http', 'https'}.contains(url.scheme) && url.host.isNotEmpty && url.userInfo.isEmpty) {
        final lines = await pages.putIfAbsent(url, () => _pageLines(http, url, cancellation));
        final limit = switch (commands['response_length']) {'short' => 40, 'long' => 160, _ => 80};
        final selected = <int>{};
        if (operation == 'find') {
          final pattern = (arguments['pattern'] as String).toLowerCase();
          for (var i = 0; i < lines.length && selected.length < limit; i++) {
            if (!lines[i].toLowerCase().contains(pattern)) continue;
            for (var j = (i - 2).clamp(0, lines.length); j < lines.length && j <= i + 2 && selected.length < limit; j++) {
              selected.add(j);
            }
          }
        } else {
          final start = (arguments['lineno'] as int? ?? 0).clamp(0, lines.length);
          selected.addAll(List.generate((lines.length - start).clamp(0, limit), (i) => start + i));
        }
        replacement = 'Source: $url (direct HTTP retrieval); Total lines: ${lines.length}\n'
            '${selected.isEmpty ? (operation == 'find' ? 'No matching text found.' : 'No lines at this position.')
              : selected.map((i) => 'L$i: ${lines[i]}').join('\n')}';
      }
    } on ModelFailure {
      // Keep the hosted failure when direct retrieval is unavailable as well.
      cancellation.throwIfCancelled();
    } on FormatException {
      // A changed hosted error format is not a reason to discard its output.
    }
    recovered.write(replacement);
    end = match.end;
  }
  recovered.write(output.substring(end));
  return recovered.toString();
}

Future<List<String>> _pageLines(HttpClient http, Uri url, CancellationToken cancellation) async {
  final response = await webSearchRequest(http, url, cancellation: cancellation);
  if (response.status != 200) {
    throw ModelFailure('web_fetch_http', 'Page retrieval failed (HTTP ${response.status})');
  }
  final type = response.contentType;
  if (type != null && !type.startsWith('text/') && type != 'application/xhtml+xml') {
    throw const ModelFailure('web_fetch_type', 'Direct page retrieval requires text or HTML');
  }
  var text = response.text;
  if (type == 'text/html' || type == 'application/xhtml+xml') {
    final document = html.parse(text);
    for (final element in document.querySelectorAll('script,style,noscript,nav,header,footer,svg')) {
      element.remove();
    }
    String content(dom.Node node) {
      if (node is dom.Text) return node.data;
      final children = node.nodes.map(content).join();
      if (node is! dom.Element) return children;
      if (node.localName == 'br') return '\n';
      if (node.attributes['href'] case final String href when node.localName == 'a') {
        final target = url.resolve(href);
        if ({'http', 'https'}.contains(target.scheme)) return '[$children]($target)';
      }
      return {'p', 'div', 'section', 'article', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'pre', 'tr'}.contains(node.localName)
          ? '\n$children\n' : children;
    }
    text = content(document.querySelector('main') ?? document.querySelector('article') ?? document.body ?? document)
        .replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n+'), '\n\n').trim();
  }
  if (text.trim().isEmpty) throw const ModelFailure('web_fetch_empty', 'Page retrieval returned no text');
  return const LineSplitter().convert(text);
}
