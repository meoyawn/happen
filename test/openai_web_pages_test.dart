import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openai/src/responses.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

// Observed alpha/search HTTP 200 response for adelnz.com/writing/tool-search/.
String _unavailable(String operation, Json arguments) => 'Internal Error ()\n'
    'citeturn0view0 [wordlim: 200] Source: $operation(${jsonEncode(arguments)}); \n'
    'URL ${arguments['ref_id']} is not accessible via this tool.';

void main() {
  late HttpServer hosted, pages;
  late HttpClient http;
  late ResponsesClient client;
  late String pageUrl, output, pageText;
  late ContentType pageType;
  late int pageStatus, pageRequests;
  late Completer<void> waiting, release;

  setUp(() async {
    hosted = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    pages = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http = HttpClient();
    pageUrl = 'http://127.0.0.1:${pages.port}/article';
    output = '';
    pageText = '<html><head><title>Hidden title</title></head><body><nav>Hidden navigation</nav>'
        '<main><h1>Tool search</h1><p>Read &amp; compose tools.</p><script>Hidden script</script>'
        '<p><a href="/next">Next article</a></p></main></body></html>';
    pageType = ContentType.html;
    pageStatus = 200;
    pageRequests = 0;
    waiting = Completer<void>();
    release = Completer<void>();
    hosted.listen((request) async {
      await request.drain<void>();
      expect(request.uri.path, '/codex/alpha/search');
      expect(request.headers.value('authorization'), 'Bearer fixture-secret');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'output': output}));
      await request.response.close();
    });
    pages.listen((request) async {
      pageRequests++;
      for (final header in ['authorization', 'chatgpt-account-id', 'session-id', 'originator']) {
        expect(request.headers.value(header), isNull, reason: header);
      }
      try {
        request.response.statusCode = pageStatus;
        request.response.headers.contentType = pageType;
        if (request.uri.path == '/redirect') {
          request.response.statusCode = 302;
          request.response.headers.set('location', pageUrl);
        } else if (request.uri.path == '/wait') {
          request.response.write('waiting');
          await request.response.flush();
          waiting.complete();
          await release.future;
        } else {
          request.response.write(pageText);
        }
        await request.response.close();
      } catch (_) {
        // Cancellation and response limits can close the fixture connection.
      }
    });
    client = ResponsesClient(http: http,
      endpoint: Uri.parse('http://127.0.0.1:${hosted.port}/codex/responses'),
      credentials: ({bool refresh = false}) async => {
        'access_token': 'fixture-secret', 'account_id': 'fixture-account',
      });
  });

  tearDown(() async {
    if (!release.isCompleted) release.complete();
    http.close(force: true);
    await hosted.close(force: true);
    await pages.close(force: true);
  });

  Future<String> search(Json commands, [CancellationToken? cancellation]) => client.search(
    model: 'gpt-6.1-sol', sessionId: 'fixture-task', commands: commands, input: [],
    cancellation: cancellation ?? CancellationToken());

  test('recovers the inaccessible page while preserving other hosted results', () async {
    output = 'Hosted search evidence\n\n${_unavailable('open', {'ref_id': pageUrl, 'lineno': null})}\n\nHosted second page';
    final result = await search({'open': [{'ref_id': pageUrl}], 'response_length': 'long'});
    expect(result, startsWith('Hosted search evidence\n\nSource: $pageUrl (direct HTTP retrieval)'));
    expect(result, endsWith('\n\nHosted second page'));
    expect(result, contains('L0: Tool search'));
    expect(result, contains('Read & compose tools.'));
    expect(result, contains('[Next article](http://127.0.0.1:${pages.port}/next)'));
    expect(result, isNot(contains('Internal Error')));
    expect(result, isNot(contains('Hidden')));
    expect(result, isNot(contains('turn0view0')));
    expect(pageRequests, 1);
  });

  test('open offsets and case insensitive find share a fetch and line numbers', () async {
    pageType = ContentType.text;
    pageText = List.generate(300, (i) => i == 220 ? 'Needle at 220' : 'line $i').join('\r\n');
    output = [
      _unavailable('open', {'ref_id': pageUrl, 'lineno': 210}),
      _unavailable('open', {'ref_id': pageUrl, 'lineno': 260}),
      _unavailable('find', {'ref_id': pageUrl, 'pattern': 'NEEDLE'}),
    ].join('\n\n');
    final result = await search({
      'open': [{'ref_id': pageUrl, 'lineno': 210}, {'ref_id': pageUrl, 'lineno': 260}],
      'find': [{'ref_id': pageUrl, 'pattern': 'NEEDLE'}], 'response_length': 'short',
    });
    expect(result, contains('Total lines: 300\nL210: line 210'));
    expect(result, contains('Total lines: 300\nL260: line 260'));
    expect(result, contains('L249: line 249\n\nSource:'));
    expect(result, contains('Total lines: 300\nL218: line 218\nL219: line 219\nL220: Needle at 220'));
    expect(result, isNot(contains('Internal Error')));
    expect(pageRequests, 1);
  });

  test('hosted success, opaque refs, and unrequested URLs never trigger a fetch', () async {
    final commands = {'open': [{'ref_id': pageUrl}]};
    for (final text in ['Hosted page content',
      _unavailable('open', {'ref_id': 'turn0search0', 'lineno': null}),
      _unavailable('open', {'ref_id': '$pageUrl/unrequested', 'lineno': null}),
      _unavailable('open', {'ref_id': pageUrl, 'lineno': 50}),
    ]) {
      output = text;
      expect(await search(commands), text);
    }
    expect(pageRequests, 0);
  });

  test('direct retrieval follows redirects without provider credentials', () async {
    final redirect = 'http://127.0.0.1:${pages.port}/redirect';
    output = _unavailable('open', {'ref_id': redirect, 'lineno': null});
    expect(await search({'open': [{'ref_id': redirect}]}), contains('Tool search'));
    expect(pageRequests, 2);
  });

  test('failed, binary, empty, and oversized pages retain the hosted failure', () async {
    output = _unavailable('open', {'ref_id': pageUrl, 'lineno': null});
    final commands = {'open': [{'ref_id': pageUrl}]};
    pageStatus = 403;
    pageText = 'fixture-secret';
    expect(await search(commands), output);
    pageStatus = 200;
    pageType = ContentType.binary;
    expect(await search(commands), output);
    pageType = ContentType.text;
    pageText = '';
    expect(await search(commands), output);
    pageText = 'x' * (2 * 1024 * 1024 + 1);
    expect(await search(commands), output);
    pageText = 'recovered';
    expect(await search(commands), contains('L0: recovered'));
  });

  test('cancellation aborts direct retrieval and keeps the shared pool usable', () async {
    final url = 'http://127.0.0.1:${pages.port}/wait';
    output = _unavailable('open', {'ref_id': url, 'lineno': null});
    final token = CancellationToken();
    final pending = expectLater(search({'open': [{'ref_id': url}]}, token),
      throwsA(isA<CancelledException>()));
    await waiting.future.timeout(const Duration(seconds: 5));
    token.cancel();
    await pending.timeout(const Duration(seconds: 2));
    output = _unavailable('open', {'ref_id': pageUrl, 'lineno': null});
    expect(await search({'open': [{'ref_id': pageUrl}]}), contains('Tool search'));
  });
}
