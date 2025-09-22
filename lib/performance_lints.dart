library performance_lints;

export 'src/lints/dispose_lint_plugin.dart';

import 'package:custom_lint_builder/custom_lint_builder.dart';
import 'src/lints/dispose_lint_plugin.dart' as internal;

// Ponto de entrada exigido pelo custom_lint
PluginBase createPlugin() => internal.createPlugin();