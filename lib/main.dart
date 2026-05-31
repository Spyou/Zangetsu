import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/app_config.dart';
import 'core/di/injector.dart';
import 'core/theme/app_theme.dart';
import 'features/shell/root_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initDependencies();
  runApp(const WatchApp());
}

class WatchApp extends StatelessWidget {
  const WatchApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: kAppName,
        theme: buildAppTheme(),
        home: const RootShell(),
      );
}
