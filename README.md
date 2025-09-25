# performance_lints

Regras de lint focadas em prevenir problemas de performance e uso incorreto de recursos.

## Features

- `missing_dispose`: Detecta objetos descartáveis instanciados e não descartados:
	- Variáveis locais
	- Campos de classes (incluindo subclasses de `State`) que não são liberados em `dispose()`
	- Suporta métodos de descarte: `dispose()`, `close()`, `cancel()`

## Getting started

Adicione no `dev_dependencies` do seu projeto principal:

```yaml
dev_dependencies:
	custom_lint: ^0.6.4
	performance_lints:
		git:
			url: git@github.com:vinicioshenriques/performance_lints.git
			ref: v1.0.0
```

Crie (ou edite) `analysis_options.yaml` no seu app:

```yaml
analyzer:
	plugins:
		- custom_lint
```

e no terminal rode:

```bash
dart run custom_lint
```

Após isso as novas regras estarão ativas, já sendo exibidas na aba dart analysis do seu editor.

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
- Não infere descarte indireto via helpers/DI (ex.: passado para outro objeto que gerencia o ciclo de vida)
- Não analisa descarte em mixins separados ainda
- Métodos sinônimos configurados fixos (`dispose/close/cancel`) – futuramente configurável
