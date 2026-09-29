import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/lints/missing_dispose_rule.dart';

final plugin = PerformanceLintsPlugin();

class PerformanceLintsPlugin extends Plugin {
  @override
  String get name => 'performance_lints';

  @override
  void register(PluginRegistry registry) {
    registry.registerLintRule(MissingDisposeRule());
  }
}
