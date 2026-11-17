import 'package:protocol/protocol.dart';

class ConversationCommandAction {
  const ConversationCommandAction(this.type, {this.path, this.name, this.query});
  final String type;
  final String? path, name, query;
}

Iterable<Map<Object?, Object?>> _parsedActions(Json item) {
  final actions = item['commandActions'];
  return actions is List ? actions.whereType<Map<Object?, Object?>>() : const [];
}

String conversationCommandText(Json item) {
  // Native Happen records keep the script in commandActions and shell argv
  // in command. The former is also the readable version on cold replay.
  final actions = _parsedActions(item);
  final command = actions.length == 1 ? actions.first['command'] ?? item['command'] : item['command'];
  return command is String ? command.trim() : '';
}

final _actionCache = Expando<List<ConversationCommandAction>>();

List<ConversationCommandAction> conversationCommandActions(Json item) =>
  _actionCache[item] ??= _describeActions(item).toList(growable: false);

Iterable<ConversationCommandAction> _describeActions(Json item) sync* {
  final actions = _parsedActions(item);
  if (actions.isEmpty) {
    yield _describeScript(conversationCommandText(item));
    return;
  }
  for (final action in actions) {
    final type = action['type'];
    if (type == 'read' || type == 'search' || type == 'listFiles') {
      yield ConversationCommandAction(type as String,
        path: action['path'] is String ? action['path'] as String : null,
        name: switch (action['displayLabel'] ?? action['name']) {final String name => name, _ => null},
        query: action['query'] is String ? action['query'] as String : null);
    } else {
      yield _describeScript(action['command'] is String ? action['command'] as String : conversationCommandText(item));
    }
  }
}

final _word = RegExp(r'''(?:"(?:\\.|[^"\\])*"|'[^']*'|\\.|[^\s"'\\;&|<>])+|[;&|<>\r\n]''');
final _fileSeparators = RegExp(r'[/\\]');
final _sedRead = RegExp(r'^(?:\d+|\$)(?:,(?:\d+|\$))?p$');
const _unknown = ConversationCommandAction('unknown');
const _shellOperators = {';', '&', '|', '<', '>', '\r', '\n'};
const _searchOptions = {
  '-g', '--glob', '--iglob', '-t', '--type', '-T', '--type-not', '-A', '-B', '-C',
  '--after-context', '--before-context', '--context', '-m', '--max-count',
  '--max-depth', '--sort', '--sortr', '-f', '--file', '--exclude', '--include',
};

String conversationPathName(String path) =>
  path.split(_fileSeparators).where((segment) => segment.isNotEmpty).lastOrNull ?? path;

String _unquote(String token) {
  if (token.length > 1 && (token.startsWith("'") && token.endsWith("'") ||
      token.startsWith('"') && token.endsWith('"'))) {
    return token.substring(1, token.length - 1);
  }
  return token.replaceAllMapped(RegExp(r'\\(\s)'), (match) => match[1]!);
}

ConversationCommandAction _describeScript(String script) {
  if (script.isEmpty || script.length > 8192) return _unknown;
  var tokens = _word.allMatches(script.trim()).map((match) => match[0]!).toList();
  final pipe = tokens.indexOf('|');
  // A display filter after a read or search still describes the same work.
  if (pipe > 0 && pipe + 1 < tokens.length &&
      const {'head', 'tail'}.contains(tokens[pipe + 1]) &&
      tokens.skip(pipe + 2).every((token) => token.startsWith('-') || int.tryParse(token) != null)) {
    tokens = tokens.sublist(0, pipe);
  }
  if (tokens.isEmpty || tokens.any(_shellOperators.contains)) return _unknown;
  final command = conversationPathName(_unquote(tokens.first));
  final args = tokens.skip(1).map(_unquote).toList();
  switch (command) {
    case 'cat':
    case 'head':
    case 'tail':
    case 'bat':
    case 'sed':
      if (args.isEmpty || args.last.startsWith('-') ||
          args.length > 1 && const {'-n', '-c'}.contains(args[args.length - 2])) return _unknown;
      if (command == 'sed' && !(args.contains('-n') && args.length >= 3 && _sedRead.hasMatch(args[args.length - 2]))) {
        return _unknown;
      }
      return ConversationCommandAction('read', path: args.last);
    case 'ls':
      return ConversationCommandAction('listFiles', path: args.where((arg) => !arg.startsWith('-')).lastOrNull);
    case 'rg':
    case 'grep':
      return _describeSearch(args);
    default:
      return _unknown;
  }
}

ConversationCommandAction _describeSearch(List<String> args) {
  final listsFiles = args.contains('--files');
  final operands = <String>[];
  String? query;
  var positional = false;
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (!positional && arg == '--') {
      positional = true;
    } else if (!positional && (arg == '-e' || arg == '--regexp') && index + 1 < args.length) {
      query ??= args[index + 1];
      index++;
    } else if (!positional && _searchOptions.contains(arg) && index + 1 < args.length) {
      index++;
    } else if (positional || !arg.startsWith('-')) {
      operands.add(arg);
    }
  }
  if (listsFiles) return ConversationCommandAction('listFiles', path: operands.firstOrNull);
  if (query == null && operands.isNotEmpty) query = operands.removeAt(0);
  return ConversationCommandAction('search', query: query, path: operands.firstOrNull);
}
