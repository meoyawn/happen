import 'package:protocol/protocol.dart';

import 'model.dart';

typedef ToolInvoker = Future<Object?> Function(String name, Object? arguments);

/// Provider-owned model and code-mode contracts. The agent supplies execution
/// services without interpreting a provider's tool names or argument encoding.
abstract class ToolInterface {
  const ToolInterface();
  String get id;
  String baseInstructions(String model, String supplied) => supplied;
  ConversationItem instructionContext(Json current, Json? previous);
  ConversationItem environmentContext(String cwd, {bool replacement = false});
  List<ToolDefinition> get definitions;
  List<Json> get hostCatalog;
  ToolDefinition? get discovery => null;
  bool get replacesLegacyCatalog => false;
  String? catalogContext(List<Json> current, List<Json>? previous);
  Map<String, String> get services => const {};
  ToolRuntime createRuntime(String cwd, CancellationToken cancellation);
  String formatResult(ToolCall call, Json result);
  List<Json> externalCatalog(List<Json> catalog) => catalog;
  ToolDiscovery search(List<Json> catalog, Json arguments, {bool nested = false}) =>
      throw UnsupportedError('This provider discovers tools inside code mode');
}

class ToolDiscovery {
  const ToolDiscovery(this.tools, this.output);
  final List<Json> tools;
  final Json output;
}

abstract class ToolRuntime {
  Future<Json> execute(ToolCall call, ToolExecution context);
  Future<Object?> call(String name, Object? arguments);
  void close();
  Future<List<String>> notifications({bool wait = false}) async => [];
}

class ToolExecution {
  const ToolExecution({
    required this.call,
    required this.catalog,
    required this.values,
    required this.cancellation,
  });
  final ToolInvoker call;
  final Future<List<Json>> Function() catalog;
  final Json values;
  final CancellationToken cancellation;
}
