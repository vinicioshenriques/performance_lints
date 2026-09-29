# performance_lints

Regras de lint focadas em prevenir problemas de performance e uso incorreto de recursos.

A partir da versão 2.0.0, este pacote é um **analyzer plugin nativo** (via `package:analysis_server_plugin`), o sistema oficial de plugins do analyzer disponível a partir do Dart 3.10 (Flutter 3.38). O antigo framework `custom_lint`, usado nas versões 1.x, foi descontinuado (repositório arquivado) e por isso o pacote foi migrado.

## Features

- `missing_dispose`: Detecta objetos descartáveis instanciados e não descartados:
	- Variáveis locais
	- Campos de classes (incluindo subclasses de `State`) que não são liberados em `dispose()`
	- Suporta métodos de descarte: `dispose()`, `close()`, `cancel()`

## Getting started

Adicione no `dev_dependencies` do seu projeto principal:

```yaml
dev_dependencies:
  performance_lints:
    git:
      url: git@github.com:vinicioshenriques/performance_lints.git
      ref: v2.0.0
```

Habilite o plugin e a regra no `analysis_options.yaml` da raiz do seu projeto (ou workspace):

```yaml
plugins:
  performance_lints:
    version: ^2.0.0
    diagnostics:
      missing_dispose: true
```

Não é necessário rodar nenhum comando adicional: as diagnósticos aparecem diretamente no `dart analyze` / `flutter analyze` e no seu editor (após reiniciar o Dart Analysis Server ao alterar a seção `plugins`).

## Usage

Exemplo que gera a lint:

```dart
void exemplo() {
	final controller = StreamController(); // LINT: missing_dispose
	controller.add(1);
}
```

Correção esperada:

```dart
void exemplo() {
	final controller = StreamController();
	try {
		controller.add(1);
	} finally {
		controller.close(); // ou controller.dispose() dependendo da API
	}
}
```

Para casos simples:

```dart
void exemplo2() {
	final focus = FocusNode();
	// uso
	focus.dispose();
}
```

## Limitações atuais

- Não segue fluxo de controle complexo (ex.: múltiplos returns condicionais antes do descarte)
- Não infere descarte indireto via helpers/DI (ex.: um controller passado para outro objeto que assume o ciclo de vida gera falso-positivo, pois o lint não enxerga o `dispose()` acontecendo na outra classe)
- Não analisa descarte em mixins separados ainda
- Métodos sinônimos configurados fixos (`dispose/close/cancel`) – futuramente configurável
