import 'package:custom_lint_builder/custom_lint_builder.dart';
import 'missing_dispose_rule.dart';

PluginBase createPlugin() => _PerformanceLintsPlugin();

class _PerformanceLintsPlugin extends PluginBase {
	@override
	List<LintRule> getLintRules(CustomLintConfigs configs) => [MissingDisposeRule()];
}
