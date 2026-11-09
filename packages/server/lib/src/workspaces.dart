import 'dart:io';

import 'package:protocol/protocol.dart';
import 'git.dart';

Future<Json> inspectWorkspace(String path, CancellationToken cancellation) =>
  runIsolateEffect(_inspect, {'path': path}, cancellation: cancellation);

Future<Json> _inspect(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final path = requiredString(params, 'path');
  final home = Platform.environment['HOME'];
  final requested = path == '~' ? home ?? path : path.startsWith('~/') && home != null ? '$home/${path.substring(2)}' : path;
  final folder = Directory(requested);
  if (!folder.isAbsolute) throw ArgumentError('Provide an absolute project folder path');
  if (!await folder.exists()) return {'available': false};
  final canonical = await folder.resolveSymbolicLinks();
  cancellation.throwIfCancelled();
  final branch = await runGit(canonical, ['symbolic-ref', '--quiet', '--short', 'HEAD'],
    cancellation, accepted: {0, 1, 128});
  return {'available': true, 'path': canonical, 'identity': canonical,
    'branch': branch.code == 0 ? branch.output.trim() : null};
}
