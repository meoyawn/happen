import 'package:protocol/protocol.dart';

import 'model.dart';
import 'images.dart';

typedef ToolInvoker = Future<Object?> Function(String name, Object? arguments, {
  required CancellationToken cancellation,
});

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
  List<ToolDefinition> definitionsFor(List<Json> deferred) => definitions;
  List<Json> hostCatalogFor(List<Json> deferred) => hostCatalog;
  bool get developerContextFirst => false;
  ToolDefinition? get nestedDiscovery => null;
  String? catalogContext(List<Json> current, List<Json>? previous);
  Map<String, String> get services => const {};
  ToolRuntime createRuntime(String cwd, CancellationToken cancellation);
  String formatResult(ToolCall call, Json result);
  ConversationItem resultItem(ToolCall call, Json result, {List<Json> images = const []}) =>
    ConversationItem.toolResult(call, formatResult(call, result), isError: result.containsKey('error'), images: images);
  Future<List<Json>> prepareImages(List<Json> images, {required CancellationToken cancellation}) =>
      prepareInputAttachments(images, cancellation: cancellation);
  List<Json> externalCatalog(List<Json> catalog) => catalog;
  Json search(List<Json> catalog, Json arguments) =>
      throw UnsupportedError('This provider discovers tools inside code mode');
}

abstract class ToolRuntime {
  Future<Json> execute(ToolCall call, ToolExecution context);
  Future<Object?> call(String name, Object? arguments, {
    required CancellationToken cancellation, String? cwd,
  });
  Future<void> close();
  Future<List<String>> notifications({bool wait = false, required CancellationToken cancellation}) async => [];
}

class ToolExecution {
  const ToolExecution({
    required this.call,
    required this.catalog,
    required this.values,
    required this.cancellation,
  });
  final ToolInvoker call;
  final Future<List<Json>> Function(CancellationToken cancellation) catalog;
  final Json values;
  final CancellationToken cancellation;
}
