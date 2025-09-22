import 'package:custom_lint_builder/custom_lint_builder.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/listener.dart';
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
    problemMessage:
        'Objeto descartável criado mas dispose() não foi chamado neste escopo.',
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

    final isState = classElement.allSupertypes.any((t) => t.element.name == 'State');

    // Mapear campos potencialmente descartáveis (mesmo sem init direto).
    final disposableFields = <String, VariableDeclaration>{};
    final undecidedFieldNames = <String, VariableDeclaration>{};
    for (final member in clazz.members) {
      if (member is FieldDeclaration) {
        for (final variable in member.fields.variables) {
          final name = variable.name.lexeme;
          final init = variable.initializer;
          if (init is InstanceCreationExpression) {
            final element = init.staticType?.element;
            if (element is ClassElement) {
              final hasDisposableMethod = element.methods.any((m) =>
                  disposableMethodNames.contains(m.name) && !m.isStatic && m.parameters.isEmpty);
              if (hasDisposableMethod) {
                disposableFields[name] = variable;
              }
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
      // Se a classe é um State e tem campos descartáveis, exigir dispose
      if (isState) {
        // Reporta no nome da classe
  reporter.reportErrorForOffset(_code, clazz.name.offset, clazz.name.length);
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
      final classElement = init.staticType?.element;
      if (classElement is ClassElement) {
        final hasDisposableMethod = classElement.methods.any((m) =>
            disposableMethodNames.contains(m.name) && !m.isStatic && m.parameters.isEmpty);
        if (hasDisposableMethod && node.name.lexeme != '_') {
          candidates.add(_LocalDisposableCandidate(node.name.lexeme, init));
        }
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
    if (disposableMethodNames.contains(node.methodName.name) && target is Identifier) {
      called.add(target.name);
    }
    super.visitMethodInvocation(node);
  }
}

class _FieldAssignmentScanner extends RecursiveAstVisitor<void> {
  final Set<String> disposableMethodNames;
  final Set<String> candidateFieldNames;
  final Map<String, VariableDeclaration?> disposableAssignedFields = {};

  _FieldAssignmentScanner(this.disposableMethodNames, this.candidateFieldNames);

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    final right = node.rightHandSide;
    if (left is Identifier && candidateFieldNames.contains(left.name)) {
      if (right is InstanceCreationExpression) {
        final element = right.staticType?.element;
        if (element is ClassElement) {
          final hasDisposable = element.methods.any((m) =>
              disposableMethodNames.contains(m.name) && !m.isStatic && m.parameters.isEmpty);
          if (hasDisposable) {
            // Não temos referência ao VariableDeclaration original aqui obrigatoriamente.
            // Mantemos mapa sinalizando que o campo é descartável.
            disposableAssignedFields[left.name] = null;
          }
        }
      }
    }
    super.visitAssignmentExpression(node);
  }
}
