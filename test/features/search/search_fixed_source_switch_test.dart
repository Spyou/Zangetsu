import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
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

    sl.registerSingleton<SearchHistory>(SearchHistory());
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
    expect(identical(BlocProvider.of<SearchBloc>(t.element(find.byType(TextField))), before), isFalse);
  });
}
