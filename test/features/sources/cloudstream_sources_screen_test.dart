import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/sources/cloudstream_sources_screen.dart';

class _Manager extends CloudStreamManager {
  final groups = [
    for (final tag in ['first', 'second'])
      CsRepoGroup(
        url: 'https://$tag.example/repo.json',
        name: tag,
        owner: '',
        catalog: const [
          CsPluginMeta(
            internalName: 'Bundle',
            name: 'Bundle',
            url: '',
            version: 1,
          ),
        ],
        sources: [
          CloudStreamProvider(
            name: 'Source $tag',
            lang: 'en',
            types: const ['Movie'],
            sourcePlugin: 'Bundle@1@$tag',
          ),
        ],
      ),
  ];
  String? removedRepo;
  String? removedPlugin;
  bool fail = false;

  @override
  List<CsRepoGroup> get repoGroups => groups;

  @override
  List<CloudStreamProvider> get all => groups.expand((g) => g.sources).toList();

  @override
  Future<void> uninstallPlugin(
    CsPluginMeta plugin, {
    String repoUrl = '',
  }) async {
    if (fail) throw Exception('test failure');
    removedRepo = repoUrl;
    removedPlugin = plugin.internalName;
    groups.removeWhere((g) => g.url == repoUrl);
    notifyListeners();
  }
}

void main() {
  late _Manager manager;
  late ActiveSourceCubit active;

  setUp(() {
    manager = _Manager();
    active = ActiveSourceCubit();
    GetIt.I.registerSingleton<CloudStreamManager>(manager);
    GetIt.I.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    await active.close();
    await GetIt.I.reset();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: active,
          child: const CloudStreamSourcesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('cancel leaves installed sources and active selection alone', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Uninstall').first);
    await tester.pumpAndSettle();
    expect(manager.removedRepo, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Source first'), findsOneWidget);
    expect(active.state, 'allanime');
  });

  testWidgets('uninstall targets only the chosen repository', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Uninstall').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uninstall'));
    await tester.pumpAndSettle();
    expect(manager.removedRepo, 'https://first.example/repo.json');
    expect(manager.removedPlugin, 'Bundle');
    expect(find.text('Source first'), findsNothing);
    expect(find.text('Source second'), findsOneWidget);
  });

  testWidgets('failed uninstall keeps the source and reports the error', (
    tester,
  ) async {
    manager.fail = true;
    await pump(tester);
    await tester.tap(find.byTooltip('Uninstall').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uninstall'));
    await tester.pumpAndSettle();
    expect(find.text('Source first'), findsOneWidget);
    expect(find.textContaining('test failure'), findsOneWidget);
  });

  testWidgets('installed controls fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester);
    expect(find.byTooltip('Uninstall'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
