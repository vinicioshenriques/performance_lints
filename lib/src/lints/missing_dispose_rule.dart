import 'package:custom_lint_builder/custom_lint_builder.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/element.dart';

/// Lint que detecta instâncias de tipos descartáveis (com método `dispose`) que
/// não tiveram `dispose` chamado antes do fim do escopo.
/// Heurística inicial simplificada:
/// - Identifica variáveis locais e campos que recebem instâncias de classes
///   cujo elemento possui um método `dispose()` público sem parâmetros.
/// - Verifica se no corpo do escopo existe uma invocation `ident.dispose()`.
/// - Ignora casos retornados imediatamente ou atribuídos a `_`.
class MissingDisposeRule extends DartLintRule {
  MissingDisposeRule() : super(code: _code);

  static const _code = LintCode(
    name: 'missing_dispose',
    problemMessage: 'Objeto descartável criado mas dispose() não foi chamado neste escopo.',
    correctionMessage: 'Chame dispose() antes de sair do escopo.',
    url: 'https://github.com/your_org/performance_lints#missing_dispose',
  );

  @override
  void run(CustomLintResolver resolver, ErrorReporter reporter, CustomLintContext context) {
    final disposableMethodNames = const {'dispose', 'close', 'cancel'};

    context.registry.addBlockFunctionBody((body) {
      _analyzeLocalBlock(body, reporter, disposableMethodNames);
    });
    context.registry.addConstructorDeclaration((decl) {
      if (decl.body case final BlockFunctionBody block) {
        _analyzeLocalBlock(block, reporter, disposableMethodNames);
      }
    });
    context.registry.addMethodDeclaration((decl) {
      if (decl.body case final BlockFunctionBody block) {
        _analyzeLocalBlock(block, reporter, disposableMethodNames);
      }
    });
    context.registry.addClassDeclaration((clazz) {
      _analyzeClass(clazz, reporter, disposableMethodNames);
    });
  }

  void _analyzeLocalBlock(BlockFunctionBody body, ErrorReporter reporter, Set<String> disposableMethodNames) {
    final collector = _LocalDisposableCollector(disposableMethodNames);
    body.block.visitChildren(collector);
    for (final candidate in collector.candidates) {
      final wasDisposed = collector.disposedIdentifiers.contains(candidate.variableName);
      if (!wasDisposed) {
        reporter.reportErrorForNode(_code, candidate.creationNode);
      }
    }
  }

  void _analyzeClass(ClassDeclaration clazz, ErrorReporter reporter, Set<String> disposableMethodNames) {
    final classElement = clazz.declaredElement;
    if (classElement == null) return;

    // Classes que possuem ciclo de vida conhecido onde esperamos descarte:
    // - State (StatefulWidget)
    // - ChangeNotifier (ex.: ViewModels)
    // - StatelessWidget (não possui dispose, mas não deve conter controladores)
    final superNames = classElement.allSupertypes.map((t) => t.element.name).toSet();
    final isLifecycleOwner = superNames.contains('State') || superNames.contains('ChangeNotifier') || superNames.contains('StatelessWidget');

    // Mapear campos potencialmente descartáveis (mesmo sem init direto).
    final disposableFields = <String, VariableDeclaration>{};
    final undecidedFieldNames = <String, VariableDeclaration>{};
    for (final member in clazz.members) {
      if (member is FieldDeclaration) {
        for (final variable in member.fields.variables) {
          final name = variable.name.lexeme;
          final init = variable.initializer;
          if (init is InstanceCreationExpression) {
            final type = _getInterfaceTypeFromInstanceCreation(init);
            final isDisposable = _hasDisposableMethod(type, disposableMethodNames) || _isKnownDisposableCtor(init);
            if (isDisposable) {
              disposableFields[name] = variable;
            }
          } else {
            // Pode ser atribuído depois (initState/constructor). Registrar para análise posterior.
            undecidedFieldNames[name] = variable;
          }
        }
      }
    }

    // Vasculhar initState/constructor para atribuições a esses campos.
    final assignmentScanner = _FieldAssignmentScanner(disposableMethodNames, undecidedFieldNames.keys.toSet());
    for (final member in clazz.members) {
      if (member is MethodDeclaration && member.name.lexeme == 'initState') {
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
    for (final member in clazz.members) {
      if (member is MethodDeclaration && member.name.lexeme == 'dispose' && member.parameters?.parameters.isEmpty == true) {
        disposeMethod = member;
        break;
      }
    }

    if (disposeMethod == null) {
      // Se for um tipo com ciclo de vida conhecido (State/ChangeNotifier/StatelessWidget)
      // e possui campos descartáveis, reportar ausência de dispose nos próprios campos.
      if (isLifecycleOwner) {
        for (final entry in disposableFields.entries) {
          reporter.reportErrorForOffset(_code, entry.value.name.offset, entry.value.name.length);
        }
      }
      return; // Sem método dispose para analisar chamadas
    }

    final calledInDispose = <String>{};
    if (disposeMethod.body is BlockFunctionBody) {
      final body = (disposeMethod.body as BlockFunctionBody).block;
      for (final stmt in body.statements) {
        stmt.visitChildren(_FieldDisposeVisitor(disposableMethodNames, calledInDispose));
      }
    }

    // Quais campos não foram descartados?
    for (final entry in disposableFields.entries) {
      if (!calledInDispose.contains(entry.key)) {
        reporter.reportErrorForOffset(_code, entry.value.name.offset, entry.value.name.length);
      }
    }
  }
}

class _LocalDisposableCandidate {
  final String variableName;
  final InstanceCreationExpression creationNode;
  _LocalDisposableCandidate(this.variableName, this.creationNode);
}

class _LocalDisposableCollector extends RecursiveAstVisitor<void> {
  final Set<String> disposableMethodNames;
  final List<_LocalDisposableCandidate> candidates = [];
  final Set<String> disposedIdentifiers = {};

  _LocalDisposableCollector(this.disposableMethodNames);

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final init = node.initializer;
    if (init is InstanceCreationExpression) {
      final type = _getInterfaceTypeFromInstanceCreation(init);
      final isDisposable = _hasDisposableMethod(type, disposableMethodNames) || _isKnownDisposableCtor(init);
      if (isDisposable && node.name.lexeme != '_') {
        candidates.add(_LocalDisposableCandidate(node.name.lexeme, init));
      }
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.realTarget;
    if (disposableMethodNames.contains(node.methodName.name) && target is Identifier) {
      disposedIdentifiers.add(target.name);
    }
    super.visitMethodInvocation(node);
  }
}

class _FieldDisposeVisitor extends RecursiveAstVisitor<void> {
  final Set<String> disposableMethodNames;
  final Set<String> called;
  _FieldDisposeVisitor(this.disposableMethodNames, this.called);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.realTarget;
    if (disposableMethodNames.contains(node.methodName.name)) {
      if (target is Identifier) {
        called.add(target.name);
      } else if (target is PropertyAccess) {
        // Handles `this.controller.dispose()` and `widget.controller.dispose()`
        final propertyName = target.propertyName.name;
        called.add(propertyName);
      } else if (target is PrefixedIdentifier) {
        called.add(target.identifier.name);
      } else if (target is SuperExpression) {
        // Handles `super.dispose()`
        // This is a call to the superclass's method, which we assume
        // correctly disposes of its own resources. We don't need to track
        // specific fields here, but this prevents false positives if a dispose
        // method *only* calls super.dispose().
        // We can consider adding a special value to 'called' if we need to
        // distinguish this case, e.g., called.add('super.dispose');
      }
    }
    super.visitMethodInvocation(node);
  }
}

class _FieldAssignmentScanner extends RecursiveAstVisitor<void> {
  final Set<String> disposableMethodNames;
  final Set<String> candidateFieldNames;
  final Map<String, VariableDeclaration?> disposableAssignedFields = {};

  _FieldAssignmentScanner(this.disposableMethodNames, this.candidateFieldNames);

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
      if (right is InstanceCreationExpression) {
        final type = _getInterfaceTypeFromInstanceCreation(right);
        final isDisposable = _hasDisposableMethod(type, disposableMethodNames) || _isKnownDisposableCtor(right);
        if (isDisposable) {
          // Não temos referência ao VariableDeclaration original aqui obrigatoriamente.
          // Mantemos mapa sinalizando que o campo é descartável.
          disposableAssignedFields[fieldName] = null;
        }
      }
    }
    super.visitAssignmentExpression(node);
  }
}

InterfaceType? _getInterfaceTypeFromInstanceCreation(InstanceCreationExpression expr) {
  final t = expr.staticType;
  if (t is InterfaceType) return t;
  final ctor = expr.constructorName.staticElement;
  if (ctor != null) {
    final enclosing3 = (ctor as dynamic).enclosingElement3; // compat com analyzer >=6
    if (enclosing3 is ClassElement) return enclosing3.thisType;
    final enclosing = ctor.enclosingElement;
    if (enclosing is ClassElement) return enclosing.thisType;
  }
  // Fallback: tentar tipo do TypeName
  final typeName = expr.constructorName.type.type;
  if (typeName is InterfaceType) return typeName;
  return null;
}

bool _isKnownDisposableCtor(InstanceCreationExpression expr) {
  final typeNode = expr.constructorName.type;
  final name = typeNode.name2;

  final simpleName = name.lexeme;

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
  };
  return known.contains(simpleName);
}

bool _hasDisposableMethod(DartType? type, Set<String> disposableMethodNames) {
  final interfaceType = type is InterfaceType ? type : null;
  if (interfaceType == null) return false;

  for (final name in disposableMethodNames) {
    final method = interfaceType.getMethod(name);
    if (method != null && !method.isStatic && method.parameters.isEmpty) {
      return true;
    }
  }
  return false;
}
