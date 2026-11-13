typedef DesktopVersion = ({int major, int minor, int patch, int build});

final _versionLine = RegExp(r'^version: ([^\s]+)[ \t]*$', multiLine: true);
final _version = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([1-9][0-9]*)$');
final _tag = RegExp(r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');

DesktopVersion desktopVersion(String manifest) {
  final lines = _versionLine.allMatches(manifest).toList();
  if (lines.length != 1) throw FormatException('Expected one desktop pubspec version');
  final match = _version.firstMatch(lines.single.group(1)!);
  if (match == null) throw FormatException('Expected a stable desktop version with a build number');
  final parts = [for (var index = 1; index <= 4; index++) int.tryParse(match.group(index)!)];
  if (parts.any((part) => part == null)) throw FormatException('Desktop version is too large');
  return (major: parts[0]!, minor: parts[1]!, patch: parts[2]!, build: parts[3]!);
}

DesktopVersion? desktopTagVersion(String tag) {
  final match = _tag.firstMatch(tag);
  if (match == null) return null;
  final parts = [for (var index = 1; index <= 3; index++) int.tryParse(match.group(index)!)];
  if (parts.any((part) => part == null)) return null;
  return (major: parts[0]!, minor: parts[1]!, patch: parts[2]!, build: 0);
}

int compareDesktopVersions(DesktopVersion left, DesktopVersion right) {
  for (final comparison in [
    left.major.compareTo(right.major),
    left.minor.compareTo(right.minor),
    left.patch.compareTo(right.patch),
  ]) {
    if (comparison != 0) return comparison;
  }
  return 0;
}

DesktopVersion nextDesktopVersion(DesktopVersion base, DesktopVersion? latest) {
  if (latest == null || compareDesktopVersions(base, latest) > 0) {
    return (major: base.major, minor: base.minor, patch: base.patch,
      build: latest == null || base.build > latest.build ? base.build : latest.build + 1);
  }
  return (major: latest.major, minor: latest.minor, patch: latest.patch + 1,
    build: base.build > latest.build ? base.build : latest.build + 1);
}

String desktopTag(DesktopVersion version) => 'v${version.major}.${version.minor}.${version.patch}';
String desktopVersionString(DesktopVersion version) =>
  '${version.major}.${version.minor}.${version.patch}+${version.build}';

String withDesktopVersion(String manifest, DesktopVersion version) {
  desktopVersion(manifest);
  return manifest.replaceFirst(_versionLine, 'version: ${desktopVersionString(version)}');
}
