import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

/// Lint que detecta instâncias de tipos descartáveis (com método `dispose`) que
/// não tiveram `dispose` chamado antes do fim do escopo.
/// Heurística inicial simplificada:
/// - Identifica variáveis locais e campos que recebem instâncias de classes
///   cujo elemento possui um método `dispose()` público sem parâmetros.
/// - Verifica se no corpo do escopo existe uma invocation `ident.dispose()`.
/// - Ignora casos retornados imediatamente ou atribuídos a `_`.
final Set<String> _disposableMethodNames = {'dispose', 'close', 'cancel'};

class MissingDisposeRule extends AnalysisRule {
  static const LintCode _code = LintCode(
    'missing_dispose',
    'Objeto descartável criado mas dispose() não foi chamado neste escopo.',
    correctionMessage: 'Chame dispose() antes de sair do escopo.',
  );

  MissingDisposeRule()
    : super(
        name: 'missing_dispose',
        description:
            'Detecta objetos descartáveis instanciados e não descartados.',
      );

  @override
  LintCode get diagnosticCode => _code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _Visitor(this);
    // Cobre corpos de funções, métodos e construtores (todos são
    // BlockFunctionBody), sem precisar registrar cada declaração separadamente.
    registry.addBlockFunctionBody(this, visitor);
    registry.addClassDeclaration(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  final MissingDisposeRule rule;

  _Visitor(this.rule);

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    final collector = _LocalDisposableCollector();
    node.block.visitChildren(collector);
    for (final candidate in collector.candidates) {
      final wasDisposed = collector.disposedIdentifiers.contains(
        candidate.variableName,
      );
      if (!wasDisposed) {
        rule.reportAtNode(candidate.creationNode);
      }
    }
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _analyzeClass(node, rule);
  }
}

void _analyzeClass(ClassDeclaration clazz, MissingDisposeRule rule) {
  final classElement = clazz.declaredFragment?.element;
  if (classElement == null) return;

  // Classes que possuem ciclo de vida conhecido onde esperamos descarte:
  // - State (StatefulWidget)
  // - ChangeNotifier (ex.: ViewModels)
  // - StatelessWidget (não possui dispose, mas não deve conter controladores)
  final superNames = classElement.allSupertypes
      .map((t) => t.element.name)
      .toSet();
  final isLifecycleOwner =
      superNames.contains('State') ||
      superNames.contains('ChangeNotifier') ||
      superNames.contains('StatelessWidget');

  // Mapear campos potencialmente descartáveis (mesmo sem init direto).
  final disposableFields = <String, VariableDeclaration>{};
  final undecidedFieldNames = <String, VariableDeclaration>{};
  for (final member in clazz.body.members) {
    if (member is FieldDeclaration) {
      for (final variable in member.fields.variables) {
        final name = variable.name.lexeme;
        final init = variable.initializer;
        if (init != null && _isDisposableExpression(init)) {
          disposableFields[name] = variable;
        } else {
          // Pode ser atribuído depois (initState/constructor/didInitState). Registrar para análise posterior.
          undecidedFieldNames[name] = variable;
        }
      }
    }
  }

  // Vasculhar métodos e construtores para atribuições a esses campos.
  // Originalmente verificávamos apenas initState/constructors; estendemos para todos os métodos
  // porque quem usa mixins ou callbacks (ex.: didInitState) pode criar instâncias lá.
  final assignmentScanner = _FieldAssignmentScanner(
    undecidedFieldNames.keys.toSet(),
  );
  for (final member in clazz.body.members) {
    if (member is MethodDeclaration) {
      member.body.visitChildren(assignmentScanner);
    } else if (member is ConstructorDeclaration) {
      member.body.visitChildren(assignmentScanner);
    }
  }
  // Promover campos detectados como descartáveis por atribuições.
  for (final entry in assignmentScanner.disposableAssignedFields.entries) {
    final original = undecidedFieldNames[entry.key];
    if (original != null) {
      disposableFields[entry.key] = original;
    }
  }

  if (disposableFields.isEmpty) return;

  // Procurar método dispose dentro da classe
  MethodDeclaration? disposeMethod;
  for (final member in clazz.body.members) {
    if (member is MethodDeclaration &&
        member.name.lexeme == 'dispose' &&
        member.parameters?.parameters.isEmpty == true) {
      disposeMethod = member;
      break;
    }
  }

  if (disposeMethod == null) {
    // Se for um tipo com ciclo de vida conhecido (State/ChangeNotifier/StatelessWidget)
    // e possui campos descartáveis, reportar ausência de dispose nos próprios campos.
    if (isLifecycleOwner) {
      for (final entry in disposableFields.entries) {
        rule.reportAtOffset(
          entry.value.name.offset,
          entry.value.name.length,
        );
      }
    }
    return; // Sem método dispose para analisar chamadas
  }

  final calledInDispose = <String>{};
  if (disposeMethod.body is BlockFunctionBody) {
    final body = (disposeMethod.body as BlockFunctionBody).block;
    for (final stmt in body.statements) {
      stmt.visitChildren(_FieldDisposeVisitor(calledInDispose));
    }
  }

  // Quais campos não foram descartados?
  for (final entry in disposableFields.entries) {
    if (!calledInDispose.contains(entry.key)) {
      rule.reportAtOffset(entry.value.name.offset, entry.value.name.length);
    }
  }
}

class _LocalDisposableCandidate {
  final String variableName;
  final Expression creationNode;
  _LocalDisposableCandidate(this.variableName, this.creationNode);
}

class _LocalDisposableCollector extends RecursiveAstVisitor<void> {
  final List<_LocalDisposableCandidate> candidates = [];
  final Set<String> disposedIdentifiers = {};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final init = node.initializer;
    if (init != null &&
        node.name.lexeme != '_' &&
        _isDisposableExpression(init)) {
      candidates.add(_LocalDisposableCandidate(node.name.lexeme, init));
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.realTarget;
    if (_disposableMethodNames.contains(node.methodName.name) &&
        target is Identifier) {
      disposedIdentifiers.add(target.name);
    }
    super.visitMethodInvocation(node);
  }
}

class _FieldDisposeVisitor extends RecursiveAstVisitor<void> {
  final Set<String> called;
  _FieldDisposeVisitor(this.called);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.realTarget;
    if (_disposableMethodNames.contains(node.methodName.name)) {
      if (target is Identifier) {
        called.add(target.name);
      } else if (target is PropertyAccess) {
        // Trata `this.controller.dispose()` e `widget.controller.dispose()`
        final propertyName = target.propertyName.name;
        called.add(propertyName);
      } else if (target is PrefixedIdentifier) {
        called.add(target.identifier.name);
      } else if (target is SuperExpression) {
        // Trata `super.dispose()`
        // Esta é uma chamada ao método da superclasse, que assumimos
        // que descarte corretamente seus próprios recursos. Não precisamos
        // rastrear campos específicos aqui, mas isso evita falsos-positivos
        // se um método dispose chamar apenas super.dispose().
      }
    }
    super.visitMethodInvocation(node);
  }
}

class _FieldAssignmentScanner extends RecursiveAstVisitor<void> {
  final Set<String> candidateFieldNames;
  final Map<String, VariableDeclaration?> disposableAssignedFields = {};

  _FieldAssignmentScanner(this.candidateFieldNames);

  String? _extractAssignedFieldName(Expression left) {
    if (left is Identifier) return left.name;
    if (left is PropertyAccess) return left.propertyName.name;
    if (left is PrefixedIdentifier) return left.identifier.name;
    return null;
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    final right = node.rightHandSide;
    final fieldName = _extractAssignedFieldName(left);
    if (fieldName != null && candidateFieldNames.contains(fieldName)) {
      // Verifica a própria expressão do lado direito e, se não for
      // descartável diretamente (ex.: `widget.x ?? FocusNode()`, ou o
      // resultado de uma chamada de método como `stream.listen(...)`),
      // procura em qualquer subexpressão aninhada.
      final finder = _DisposableExpressionFinder();
      right.accept(finder);
      if (finder.found != null) {
        disposableAssignedFields[fieldName] = null;
      }
    }
    super.visitAssignmentExpression(node);
  }
}

/// Percorre uma expressão procurando a primeira que seja "descartável" —
/// seja uma criação de instância de um tipo conhecido, seja qualquer
/// expressão cujo tipo estático exponha `dispose`/`close`/`cancel`. Isso
/// cobre não apenas `Foo()`, mas também retornos de métodos como
/// `stream.listen(...)` (que devolve um `StreamSubscription`) ou getters que
/// exponham um objeto descartável.
///
/// A descida só continua por combinadores "transparentes", que preservam o
/// valor original (`??`, expressão condicional, parênteses, `as`). Não
/// descemos em listas de argumentos de chamadas/construções (`Foo(bar)`),
/// pois ali `bar` está sendo apenas repassado como parâmetro — não se torna
/// o valor atribuído ao campo — o que evitaria falsos positivos como
/// `_owner = _ScrollOwner(_scrollController)`.
class _DisposableExpressionFinder extends GeneralizingAstVisitor<void> {
  Expression? found;

  @override
  void visitExpression(Expression node) {
    if (found != null) return;
    if (_isDisposableExpression(node)) {
      found = node;
      return;
    }
    final isTransparentCombinator =
        (node is BinaryExpression && node.operator.lexeme == '??') ||
        node is ConditionalExpression ||
        node is ParenthesizedExpression ||
        node is AsExpression;
    if (isTransparentCombinator) {
      super.visitExpression(node);
    }
  }
}

/// Decide se [expr] produz um valor descartável. Verifica primeiro o tipo
/// estático da própria expressão (o que cobre criações diretas `Foo()`,
/// chamadas de método como `stream.listen(...)`, e getters), com um
/// fallback específico para construtores conhecidos quando o tipo não pôde
/// ser resolvido.
bool _isDisposableExpression(Expression expr) {
  if (_hasDisposableMethod(expr.staticType)) return true;
  if (expr is InstanceCreationExpression) {
    final resolvedType = _getInterfaceTypeFromInstanceCreation(expr);
    if (_hasDisposableMethod(resolvedType)) return true;
    return _isKnownDisposableCtor(expr);
  }
  return false;
}

InterfaceType? _getInterfaceTypeFromInstanceCreation(
  InstanceCreationExpression expr,
) {
  final t = expr.staticType;
  if (t is InterfaceType) return t;
  final ctorElement = expr.constructorName.element;
  final enclosing = ctorElement?.enclosingElement;
  if (enclosing != null) return enclosing.thisType;
  // Fallback: tentar tipo do TypeName
  final typeName = expr.constructorName.type.type;
  if (typeName is InterfaceType) return typeName;
  return null;
}

bool _isKnownDisposableCtor(InstanceCreationExpression expr) {
  final typeNode = expr.constructorName.type;
  final simpleName = typeNode.name.lexeme;

  // Lista mínima para reduzir falso-positivo; pode ser expandida futuramente.
  const known = {
    'TextEditingController',
    'FocusNode',
    'AnimationController',
    'Animation',
    'StreamController',
    'TabController',
    'PageController',
    'ScrollController',
    'ChangeNotifier',
    'ValueNotifier',
    'StreamSubscription',
    'OverlayEntry',
    'Ticker',
    'Timer',
    'GestureRecognizer',
    'HttpClient',
    'StreamSink',
    'ImageStream',
    'ImageStreamListener',
  };
  return known.contains(simpleName);
}

bool _hasDisposableMethod(DartType? type) {
  final interfaceType = type is InterfaceType ? type : null;
  if (interfaceType == null) return false;

  for (final name in _disposableMethodNames) {
    final method = interfaceType.getMethod(name);
    if (method != null &&
        !method.isStatic &&
        method.formalParameters.isEmpty) {
      return true;
    }
  }
  return false;
}
