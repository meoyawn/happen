// Modified from Codex rmcp-client/src/www_authenticate.rs. Parse HTTP quoted
// strings, not JSON strings; duplicate parameters invalidate only that value.
typedef BearerChallenge = ({Map<String, String?> parameters, String header});

final _token = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

List<BearerChallenge> bearerChallenges(List<String> headers) {
  final result = <BearerChallenge>[];
  for (final header in headers) {
    final segments = <String>[];
    var quoted = false, escaped = false, start = 0;
    for (var index = 0; index < header.length; index++) {
      final char = header[index];
      if (escaped) { escaped = false; continue; }
      if (quoted && char == r'\') { escaped = true; }
      else if (char == '"') { quoted = !quoted; }
      else if (!quoted && (char == ',' || char == ';')) {
        segments.add(header.substring(start, index).trim()); start = index + 1;
      }
    }
    if (quoted || escaped) continue;
    segments.add(header.substring(start).trim());
    Map<String, String?>? current;
    void parameter(String text) {
      final equal = text.indexOf('=');
      if (equal < 0 || current == null) return;
      final name = text.substring(0, equal).trim().toLowerCase();
      if (!_token.hasMatch(name)) return;
      final raw = text.substring(equal + 1).trim();
      String? value;
      if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
        final decoded = StringBuffer();
        var invalid = false;
        for (var index = 1; index < raw.length - 1; index++) {
          var char = raw[index];
          if (char == r'\') {
            if (++index >= raw.length - 1) { invalid = true; break; }
            char = raw[index];
          } else if (char == '"') { invalid = true; break; }
          decoded.write(char);
        }
        if (!invalid) value = decoded.toString();
      } else if (_token.hasMatch(raw)) { value = raw; }
      current[name] = current.containsKey(name) ? null : value;
    }
    for (final segment in segments) {
      final equal = segment.indexOf('=');
      if (equal >= 0 && _token.hasMatch(segment.substring(0, equal).trim())) {
        parameter(segment); continue;
      }
      if (current != null) result.add((parameters: current, header: header));
      current = null;
      final scheme = RegExp(r'^(\S+)(?:\s+(.*))?$').firstMatch(segment);
      if (scheme == null || !_token.hasMatch(scheme[1]!)) continue;
      if (scheme[1]!.toLowerCase() == 'bearer') {
        current = {}; if (scheme[2] != null) parameter(scheme[2]!);
      }
    }
    if (current != null) result.add((parameters: current, header: header));
  }
  return result;
}

String? requiredScope(BearerChallenge challenge) {
  final value = challenge.parameters['scope'];
  return value != null && value.split(' ').every((part) => part.isNotEmpty &&
    part.codeUnits.every((byte) => byte == 0x21 || byte >= 0x23 && byte <= 0x5b || byte >= 0x5d && byte <= 0x7e)) ? value : null;
}
