import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:typed_data';
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';
import 'browser_files_web.dart';
import 'connection_web.dart';

String sessionExportName(String title, String sessionID) {
  final clean = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final name = clean.isEmpty ? sessionID : clean;
  return name.substring(0, name.length.clamp(0, 100));
}
class BrowserExportFile {
  const BrowserExportFile(this.path, this.name);
  final String path, name;
  BrowserExportFile get absolute => this;
  Uri get uri => Uri(path: name);
}
Future<BrowserExportFile> _save(Json data, String title, String sessionID, CancellationToken cancellation) async {
  final name = '${sessionExportName(title, sessionID)}.json';
  final bytes = Uint8List.fromList(utf8.encode('${const JsonEncoder.withIndent('  ').convert(data)}\n'));
  final path = await storeBrowserFile(bytes, name, cancellation);
  downloadBrowserFile(bytes, name);
  return BrowserExportFile(path, name);
}
Future<BrowserExportFile> saveSessionExport(Json data, {required String title, required String sessionID,
  Directory? downloadsDirectory, required CancellationToken cancellation}) => _save(data, title, sessionID, cancellation);
Future<BrowserExportFile> saveSessionTrace(AgentClient client, TraceStore desktop, {required String title,
  required String sessionID, Directory? downloadsDirectory, required CancellationToken cancellation}) async {
  final events = <Json>[...traceProcessMetadata()];
  for (final server in [true, false]) {
    var after = 0;
    int? through;
    while (true) {
      final page = server ? await client.tracePage(sessionID, after: after, through: through, cancellation: cancellation)
        : await desktop.page(sessionID, after: after, through: through, cancellation: cancellation);
      through ??= page['through'] as int;
      events.addAll(traceExportEvents((page['events'] as List).map(jsonObject)));
      after = page['after'] as int;
      if (page['done'] == true) break;
    }
  }
  return _save({'displayTimeUnit': 'ms', 'traceEvents': events}, '$title-trace', sessionID, cancellation);
}
