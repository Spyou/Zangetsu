// Pins the fix for `_SearchViewState._repo` in search_screen.dart: in Sources
// scope (forceSources, or Z Mode off) the view must read the SAME repository
// the bloc is actually searching — SourceRepository directly — not the
// CatalogueRepository router. With Z Mode on, the router can resolve a call
// to the metadata catalogue, so before the fix the source line rendered the
// metadata pseudo-source name (e.g. "AniList") for a search that was, in
// reality, running against installed sources. See the bug report attached to
// this fix for the full story.
//
// Unlike search_scope_screen_test.dart (which registers ONE instance for
// both SourceRepository and CatalogueRepository, so it can't tell the two
// apart), this file registers two DISTINCT fakes with different displayName
// answers — that's the only way to catch the view reading the wrong one.
import 'dart:io';

import 'package:dio/dio.dart';
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

import '../../support/picker_deps.dart';

/// The repository actually being searched — `SourceRepository` — with a
/// display name distinctive enough that it can't be confused for the
/// metadata pseudo-source name below.
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
  String displayName(String id) => 'Real Source';
  @override
  bool hasSource(String id) => true;
  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => const [];
}

/// Stands in for the `CatalogueRepository` router the way it behaves once Z
/// Mode is on: `displayName` answers with the metadata pseudo-source name
/// regardless of id. That's exactly what `_repo` used to be, unconditionally,
/// before the fix — the wrong repository for a forceSources search.
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

/// Empty local list, no Hive box or Supabase client.
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

  // Same wiring as search_scope_screen_test.dart: SearchScreen reads
  // ActiveSourceCubit off the widget tree, not just off GetIt.
  Widget harness() => MaterialApp(
    home: BlocProvider<ActiveSourceCubit>.value(
      value: sl<ActiveSourceCubit>(),
      child: const SearchScreen(forceSources: true),
    ),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('search_forced_scope_repo');
    Hive.init(dir.path);
    await SearchHistory.init();
    await SearchPrefs.init();
    await SearchSourcePrefs.init();
    await registerPickerDeps();

    sl.registerSingleton<SearchHistory>(SearchHistory());
    sl.registerSingleton<SearchPrefs>(SearchPrefs());
    sl.registerSingleton<SearchSourcePrefs>(SearchSourcePrefs());
    // Distinct instances — the whole point of this file. MetadataRepository
    // is never registered: forceSources pins the scope to Sources, so
    // `_repoForScope`'s Library branch (the only thing that reads it) is
    // never reached.
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

  testWidgets(
    'forceSources with Z Mode on: source line names the real source, never '
    'the metadata pseudo-source name',
    (t) async {
      await t.runAsync(() async {
        await ZModePrefs.init();
        await ZModePrefs.setEnabled(true);
      });

      await t.pumpWidget(harness());
      await t.pumpAndSettle();

      expect(find.text('Real Source'), findsOneWidget);
      expect(find.text('AniList'), findsNothing);
    },
  );
}
