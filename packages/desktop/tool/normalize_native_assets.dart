import 'dart:convert';
import 'dart:io';

// Work around flutter/flutter#190799 until the SDK includes 295e9f1e553f.
// dyld must load a bundled framework using its LC_ID_DYLIB install name,
// otherwise replacing the file during a rebuild can load a second copy.
void main(List<String> args) {
  final file = File(args.single);
  final manifest = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final targets = manifest['native-assets'] as Map<String, dynamic>;
  final frameworkPath = RegExp(r'^[^/]+\.framework/[^/]+$');
  var changed = false;
  for (final entry in targets.entries) {
    if (!entry.key.startsWith('macos_')) continue;
    for (final value in (entry.value as Map<String, dynamic>).values) {
      if (value case ['absolute', final String path]
          when frameworkPath.hasMatch(path)) {
        value[1] = '@rpath/$path';
        changed = true;
      }
    }
  }
  if (changed) file.writeAsStringSync(jsonEncode(manifest));
}
