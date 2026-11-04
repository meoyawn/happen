import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

final plugin = _HappenLints();

class _HappenLints extends Plugin {
  @override
  String get name => 'Happen async safety';

  @override
  void register(PluginRegistry registry) => registry.registerLintRule(_AwaitBeforeCleanup());
}

/// Returning a Future exits the try immediately. Its finally can cancel the
/// operation or close its resources, and its catch cannot observe async errors.
class _AwaitBeforeCleanup extends AnalysisRule {
  _AwaitBeforeCleanup() : super(name: 'await_before_cleanup',
    description: 'Await returned futures before leaving a try with cleanup or error handlers.');

  static const _code = LintCode('await_before_cleanup',
    'The returned future can outlive this try and its cleanup or error handler.',
    severity: DiagnosticSeverity.ERROR,
    correctionMessage: 'Use return await so the operation finishes before leaving the try.');

  @override
  LintCode get diagnosticCode => _code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) =>
    registry.addReturnStatement(this, _ReturnVisitor(this));
}

class _ReturnVisitor extends SimpleAstVisitor<void> {
  _ReturnVisitor(this.rule);
  final AnalysisRule rule;

  @override
  void visitReturnStatement(ReturnStatement node) {
    final expression = node.expression;
    if (expression == null || !_future(expression.staticType)) return;
    var protected = false;
    for (AstNode child = node; child.parent != null; child = child.parent!) {
      final parent = child.parent!;
      if (parent is FunctionBody) {
        if (parent.isAsynchronous && protected) rule.reportAtNode(expression);
        return;
      }
      if (parent is TryStatement && (parent.finallyBlock != null ||
          identical(child, parent.body) && parent.catchClauses.isNotEmpty)) {
        protected = true;
      }
    }
  }
}

bool _future(DartType? type) {
  if (type == null) return false;
  if (type.isDartAsyncFuture || type.isDartAsyncFutureOr) return true;
  if (type is InterfaceType) return type.allSupertypes.any((type) => type.isDartAsyncFuture);
  if (type is TypeParameterType) return _future(type.bound);
  return false;
}
