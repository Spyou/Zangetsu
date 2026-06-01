import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';

import 'core/app_config.dart';
import 'core/di/injector.dart';
import 'core/state/active_source_cubit.dart';
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
  Widget build(BuildContext context) => MultiBlocProvider(
    providers: [
      BlocProvider<ActiveSourceCubit>.value(value: sl<ActiveSourceCubit>()),
    ],
    child: MaterialApp(
      title: kAppName,
      theme: buildAppTheme(),
      home: const RootShell(),
    ),
  );
}
