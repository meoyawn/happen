import 'package:protocol/protocol.dart';

typedef RemoteMachine = ({String alias, String name, String host, String? user, int? port,
  String? identityFile, List<String> projects});

RemoteMachine remoteMachine(Json value) {
  final alias = requiredString(value, 'alias'), host = requiredString(value, 'host').trim();
  final name = requiredString(value, 'name').trim();
  final user = (value['user'] as String?)?.trim(), identity = (value['identityFile'] as String?)?.trim();
  final port = value['port'] as int?;
  if (alias == 'local' || !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(alias)) throw const FormatException('Invalid server ID');
  if (name.isEmpty || name.length > 200) throw const FormatException('Enter a server name');
  if (host.length > 253 || !RegExp(r'^[a-zA-Z0-9:][a-zA-Z0-9_.:-]*$').hasMatch(host)) throw const FormatException('Enter a hostname or SSH config alias');
  if (user != null && user.isNotEmpty && !RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$').hasMatch(user)) throw const FormatException('Invalid SSH username');
  if (port != null && (port < 1 || port > 65535)) throw const FormatException('SSH port must be between 1 and 65535');
  if (identity != null && (identity.length > 4096 || RegExp(r'[\x00\r\n]').hasMatch(identity))) throw const FormatException('Invalid SSH key path');
  final projects = (value['projects'] as List? ?? []).cast<String>().map((path) => path.trim()).where((path) => path.isNotEmpty).toSet().toList();
  if (projects.length > 100 || projects.any((path) => path.length > 4096 || RegExp(r'[\x00\r\n]').hasMatch(path))) throw const FormatException('Invalid workspace directory');
  return (alias: alias, name: name, host: host, user: user == null || user.isEmpty ? null : user,
    port: port, identityFile: identity == null || identity.isEmpty ? null : identity,
    projects: List.unmodifiable(projects));
}

Json remoteMachineJson(RemoteMachine value) => {'alias': value.alias, 'name': value.name, 'host': value.host,
  'user': value.user, 'port': value.port, 'identityFile': value.identityFile, 'projects': value.projects};
