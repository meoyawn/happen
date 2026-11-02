import 'dart:io';

Map<String, String> isolatedEnvironment(String home, String codexHome) => {
  for (final key in ['PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'SystemRoot', 'WINDIR'])
    if (Platform.environment[key] case final String value) key: value,
  'HOME': home, 'USERPROFILE': home, 'CODEX_HOME': codexHome,
  'XDG_CONFIG_HOME': '$home/.config', 'XDG_DATA_HOME': '$home/.local/share',
  'PUB_CACHE': '$home/.pub-cache', 'NO_COLOR': '1',
};
