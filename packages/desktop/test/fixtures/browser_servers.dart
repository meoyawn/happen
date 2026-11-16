import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final html = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final empty = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final htmlPort = html.port;
  html.listen((request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write('<title>Dev preview</title><label>Name<input id="name"></label><button id="save">Save</button>');
    await request.response.close();
  });
  redirect.listen((request) async {
    request.response.statusCode = 302;
    request.response.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:$htmlPort');
    await request.response.close();
  });
  api.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write('{"ok":true}');
    await request.response.close();
  });
  empty.listen((request) async {
    request.response.statusCode = 204;
    await request.response.close();
  });
  stdout.writeln(jsonEncode({'html': html.port, 'redirect': redirect.port, 'api': api.port, 'empty': empty.port}));
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line == 'stop-html') {
      await html.close(force: true);
      stdout.writeln('stopped');
    }
  }
  for (final server in [html, redirect, api, empty]) { await server.close(force: true); }
}
