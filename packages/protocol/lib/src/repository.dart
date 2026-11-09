/// Transport-independent repository identity. Local paths and opaque Git helpers
/// cannot identify the same repository on another machine.
String? canonicalGitRemote(String remote) {
  remote = remote.trim();
  if (remote.isEmpty || RegExp(r'[\x00-\x20]').hasMatch(remote) ||
      remote.startsWith('/') || remote.startsWith('.') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(remote)) return null;
  final scp = RegExp(r'^(?:[^/@:]+@)?([^/:]+):(.+)$').firstMatch(remote);
  if (!remote.contains('://') && scp != null) remote = 'ssh://${scp[1]}/${scp[2]}';
  final uri = Uri.tryParse(remote);
  if (uri == null || !{'ssh', 'http', 'https', 'git'}.contains(uri.scheme) || uri.host.isEmpty) return null;
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '').replaceFirst(RegExp(r'\.git$', caseSensitive: false), '');
  if (path.isEmpty || path == '/') return null;
  final standard = !uri.hasPort || switch (uri.scheme) {
    'ssh' => uri.port == 22, 'git' => uri.port == 9418,
    'http' => uri.port == 80, 'https' => uri.port == 443, _ => false,
  };
  // T3's logical project identity is case-insensitive across transport spellings.
  path = path.toLowerCase();
  return Uri(scheme: standard ? 'https' : uri.scheme, host: uri.host.toLowerCase(),
    port: standard ? null : uri.port, path: path).toString();
}

String? primaryGitRepository(String remoteListing) {
  final remotes = <String, String>{};
  for (final line in remoteListing.split('\n')) {
    final match = RegExp(r'^(\S+)\s+(\S+)\s+\(fetch\)(?:\s+\[[^\]]+\])?\s*$').firstMatch(line.trim());
    if (match == null) continue;
    final identity = canonicalGitRemote(match[2]!);
    if (identity != null) remotes[match[1]!] = identity;
  }
  for (final preferred in ['upstream', 'origin', ...(remotes.keys.toList()..sort())]) {
    if (remotes[preferred] case final identity?) return identity;
  }
  return null;
}
