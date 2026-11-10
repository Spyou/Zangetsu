import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/stremio/stremio_provider.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:zangetsu_source_bridge/stremio.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/search_screen.dart';
import 'package:watch_app/features/search/bloc/search_bloc.dart';
import 'package:dio/dio.dart';

import '../../support/picker_deps.dart';

/// Switching the pinned source (A → B) must rebuild the search bloc: the
/// labels read the new widget, but the old bloc keeps answering with the
/// old source's results.
class _FakeSourceRepo implements SourceRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  List<({String id, String name})> get loadedSources => const [];
  @override
  String get sourceId => 'fake-source';
  @override
  String displayName(String id) => 'Source $id';
  @override
  bool hasSource(String id) => true;
  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => const [];
}

class _FakeRouterRepo implements CatalogueRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get loadedSources => const [];
  @override
  String get sourceId => 'zm';
  @override
  String displayName(String id) => 'AniList';
  @override
  bool hasSource(String id) => false;
  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => const [];
}

class _FakeSearchHistory extends SearchHistory {
  @override
  Future<void> add(String query) async {}
}

class _FakeStremioManager extends StremioManager {
  bool firstEnabled = true;

  void disableFirst() {
    firstEnabled = false;
    notifyListeners();
  }

  @override
  StremioInstallation? byId(String id) =>
      enabled.where((item) => item.id == id).firstOrNull;

  @override
  List<StremioInstallation> get enabled => [
    for (final name in ['First addon', 'Second addon'])
      if (name != 'First addon' || firstEnabled)
        StremioInstallation(
          id: name,
          name: name,
          version: '1',
          manifestId: name,
          types: const ['movie', 'series'],
          idPrefixes: const [],
          resources: const [],
          catalogs: const [
            StremioCatalog(
              id: 'movie',
              name: 'Movies',
              type: 'movie',
              extras: [
                StremioExtra(name: 'search'),
                StremioExtra(name: 'genre', options: ['Action', 'Drama']),
              ],
            ),
            StremioCatalog(
              id: 'shows',
              name: 'Series',
              type: 'series',
              extras: [
                StremioExtra(name: 'search'),
                StremioExtra(name: 'genre', options: ['Action', 'Drama']),
              ],
            ),
          ],
          enabled: true,
          revision: 0,
          createdAt: 0,
          urlDigest: name,
        ),
  ];
}

class _FakeStremioProvider extends StremioProvider {
  _FakeStremioProvider() : super(_FakeStremioManager());
  final calls =
      <({String installationId, String type, String? genre, int page})>[];

  @override
  Future<List<MediaItem>> browseCatalog({
    required String installationId,
    required String type,
    required String catalogId,
    required int page,
    String? genre,
  }) async {
    calls.add((
      installationId: installationId,
      type: type,
      genre: genre,
      page: page,
    ));
    return [
      MediaItem(
        id: 'browsed',
        title: 'Browse result',
        url: StremioRef(
          installationId: installationId,
          type: type,
          itemId: 'tt42',
        ).encode(),
        type: ProviderType.movie,
        sourceId: 'stremio',
      ),
    ];
  }

  @override
  Stream<({String id, String name, String category, List<MediaItem> items})>
  searchAddons(String query) async* {
    for (final name in ['First addon', 'Second addon']) {
      for (final category
          in name == 'First addon' ? ['Movies', 'Series'] : ['Movies']) {
        yield (
          id: name,
          name: name,
          category: category,
          items: [
            MediaItem(
              id: '$name-$category',
              title: 'Example',
              url: StremioRef(
                installationId: name,
                type: category == 'Series' ? 'series' : 'movie',
                itemId: 'tt123',
              ).encode(),
              type: ProviderType.movie,
              sourceId: 'stremio',
            ),
          ],
        );
      }
    }
  }
}

class _FakeMyListStore implements MyListStore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<MediaItem> all() => const [];
  @override
  bool contains(MediaItem m) => false;
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

void main() {
  late Directory dir;

  Widget harness(String sourceId) => MaterialApp(
    home: BlocProvider<ActiveSourceCubit>.value(
      value: sl<ActiveSourceCubit>(),
      child: SearchScreen(fixedSourceId: sourceId),
    ),
  );

  SearchBloc blocOf(WidgetTester t) =>
      BlocProvider.of<SearchBloc>(t.element(find.byType(TextField)));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('search_source_switch');
    Hive.init(dir.path);
    await SearchHistory.init();
    await SearchPrefs.init();
    await SearchSourcePrefs.init();
    await registerPickerDeps();

    sl.registerSingleton<SearchHistory>(_FakeSearchHistory());
    sl.registerSingleton<SearchPrefs>(SearchPrefs());
    sl.registerSingleton<SearchSourcePrefs>(SearchSourcePrefs());
    sl.registerSingleton<SourceRepository>(_FakeSourceRepo());
    sl.registerSingleton<CatalogueRepository>(_FakeRouterRepo());
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<TitleSuggestionService>(TitleSuggestionService(Dio()));
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('Stremio uses the rounded search field and addon rows', (
    t,
  ) async {
    await t.runAsync(() async {
      await ZModePrefs.init();
      await ZModePrefs.setEnabled(true);
    });
    sl.registerSingleton<StremioProvider>(_FakeStremioProvider());
    await t.pumpWidget(harness('stremio'));
    await t.pump(const Duration(milliseconds: 300));

    final fieldDecorations = t.widgetList<DecoratedBox>(
      find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      fieldDecorations.any(
        (box) =>
            box.decoration is BoxDecoration &&
            (box.decoration as BoxDecoration).borderRadius ==
                BorderRadius.circular(26),
      ),
      isTrue,
    );
    expect(find.text('Source stremio'), findsNothing);
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

    await t.enterText(find.byType(TextField), 'Example');
    t.widget<TextField>(find.byType(TextField)).onSubmitted!('Example');
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    expect(find.text('First addon · Movies'), findsNothing);
    expect(
      blocOf(t).state.groups.where((g) => g.addonName == 'Second addon'),
      hasLength(1),
    );
    await t.tap(find.text('First addon').first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    expect(find.text('SERIES'), findsNothing);
    expect(find.text('2 results'), findsNothing);
    t.widget<TextField>(find.byType(TextField)).onSubmitted!('Another query');
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(blocOf(t).state.sourceFilter, 'stremio-addon:First addon');
    expect(
      blocOf(
        t,
      ).state.sortedVisibleGroups.every((g) => g.addonName == 'First addon'),
      isTrue,
    );
    await t.tap(find.text('All'));
    await t.pump();
    expect(
      blocOf(
        t,
      ).state.sortedVisibleGroups.any((g) => g.addonName == 'Second addon'),
      isTrue,
    );
    await t.pump(const Duration(seconds: 1));
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('Stremio filters browse a catalogue without typing', (t) async {
    await t.runAsync(() async {
      await ZModePrefs.init();
      await ZModePrefs.setEnabled(true);
    });
    final provider = _FakeStremioProvider();
    sl.registerSingleton<StremioProvider>(provider);
    await t.pumpWidget(harness('stremio'));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byIcon(Icons.tune_rounded));
    await t.pumpAndSettle();
    expect(find.text('Browse catalogues'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Catalogue'), findsOneWidget);
    expect(find.text('Genre'), findsOneWidget);
    expect(find.text('All genres'), findsOneWidget);
    await t.tap(find.text('Movies').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Series').last);
    await t.pumpAndSettle();
    expect(find.text('First addon · Series'), findsOneWidget);
    await t.tap(find.text('All genres'));
    await t.pumpAndSettle();
    await t.tap(find.text('Action').last);
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Browse'));
    await t.pumpAndSettle();
    await t.tap(find.text('Browse'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Browse result'), findsOneWidget);
    expect(provider.calls.single.type, 'series');
    expect(provider.calls.single.genre, 'Action');
    expect(find.text('First addon · Series · Action'), findsOneWidget);
    (provider.manager as _FakeStremioManager).disableFirst();
    await t.pump();
    expect(find.text('Browse result'), findsNothing);
    expect(find.text('Could not load this catalogue'), findsOneWidget);
    expect(
      t.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('switching the pinned source rebuilds the search bloc', (
    t,
  ) async {
    await t.runAsync(() async {
      await ZModePrefs.init();
      await ZModePrefs.setEnabled(true);
    });

    await t.pumpWidget(harness('source:a'));
    await t.pumpAndSettle();
    final before = blocOf(t);

    // Same page, new source — what the dock tab does when Home's catalogue
    // pick changes underneath it.
    await t.pumpWidget(harness('source:b'));
    await t.pumpAndSettle();

    expect(find.text('Source source:b'), findsOneWidget);
    expect(
      identical(
        BlocProvider.of<SearchBloc>(t.element(find.byType(TextField))),
        before,
      ),
      isFalse,
    );
  });
}
