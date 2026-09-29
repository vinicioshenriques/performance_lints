## 2.0.0

- **BREAKING**: Migrado de `custom_lint` (framework descontinuado/arquivado) para o sistema nativo de analyzer plugins do Dart (`package:analysis_server_plugin`), suportado a partir do Dart 3.10 / Flutter 3.38. Compatível com Flutter 3.44 (Dart 3.12).
- **BREAKING**: Consumidores não usam mais `custom_lint` nem `dart run custom_lint`. O plugin agora é habilitado via seção `plugins:` no `analysis_options.yaml`, com a regra `missing_dispose` habilitada explicitamente em `diagnostics:`. Veja o README para o novo passo a passo.
- Ponto de entrada do pacote passou de `lib/performance_lints.dart` para `lib/main.dart`, conforme exigido pelo `analysis_server_plugin`.
- Corrigido bug em que variáveis locais dentro de construtores e métodos eram analisadas múltiplas vezes (uma vez via `addBlockFunctionBody` e novamente via `addConstructorDeclaration`/`addMethodDeclaration`), gerando diagnósticos duplicados para o mesmo objeto não descartado.
- `missing_dispose` agora detecta descartáveis obtidos por qualquer expressão (chamadas de método, getters), não apenas por criação direta de instância (`Foo()`). Isso passa a cobrir, por exemplo, `final sub = stream.listen(...)`, tanto em variáveis locais quanto em campos atribuídos fora do initializer (`initState`/construtor).
- Atualizadas as dependências `analyzer` e removida a dependência de `custom_lint_builder`.

## 1.0.0

- Initial version.
