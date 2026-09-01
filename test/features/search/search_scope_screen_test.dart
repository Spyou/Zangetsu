// Search no longer offers its own Library/Sources choice — no chips, no
// persisted pref. The scope is DERIVED from Zangetsu Mode: Sources when Z
// Mode is off, Library when it's on — or Sources regardless, when the
// caller passes forceSources (the sources destination's own search action).
// Coverage lives entirely in the widget tests below, against the real
// screen, since the derivation is only meaningful once it decides what
// actually renders (no chips, and the Sources-only source line shows/hides
// with it).
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/search_screen.dart';

import '../../support/picker_deps.dart';

// ---------------------------------------------------------------------------
// Fakes — `implements` (not `extends`) so the real constructors (which need
// ProviderManager/Dio/AniList-TMDB clients/a SourceMatcher) are never called.
// Same shape as the stubs in search_screen_tv_test.dart and
// wrong_title_sheet_test.dart.
// ---------------------------------------------------------------------------

/// Doubles as the [SourceRepository] AND [CatalogueRepository] registration:
/// `SourceRepository` already implements `CatalogueRepository`, so one
/// instance satisfies both — the widget's own `_repo` field pulls the router
/// type, the Sources scope pulls the concrete type.
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
  String displayName(String id) => id;
  @override
  bool hasSource(String id) => false;
  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => const [];

  /// Drives a filters-only browse (`SearchBloc._browseWithFilters`) so tests
  /// can put the idle screen into `hasFilteredBrowse` without touching Hive.
  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async => (
    items: [
      MediaItem(
        id: '1',
        title: 'Browsed show',
        url: 'https://x/1',
        type: ProviderType.anime,
        sourceId: sourceId ?? '',
      ),
    ],
    outcome: SourceOutcome.ok,
  );
}

class _FakeMetadataRepo implements MetadataRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String get sourceId => 'zm';
  // The pill row asks before rendering: a provider that cannot filter gets a
  // line of text instead of controls that would not work.
  @override
  bool get supportsFilters => true;
  @override
  List<({String id, String name})> get loadedSources => const [];
  @override
  String displayName(String id) => id;
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

  // SearchScreen reads ActiveSourceCubit off the widget tree (same as the
  // real app's root MultiBlocProvider in main.dart), not just off GetIt —
  // see home_source_switcher_slot_test.dart for the same wiring.
  Widget harness({bool forceSources = false}) => MaterialApp(
    home: BlocProvider<ActiveSourceCubit>.value(
      value: sl<ActiveSourceCubit>(),
      child: SearchScreen(forceSources: forceSources),
    ),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('search_scope_screen');
    Hive.init(dir.path);
    await SearchHistory.init();
    await SearchPrefs.init();
    await SearchSourcePrefs.init();
    await registerPickerDeps();

    final repo = _FakeSourceRepo();
    sl.registerSingleton<SearchHistory>(SearchHistory());
    sl.registerSingleton<SearchPrefs>(SearchPrefs());
    sl.registerSingleton<SearchSourcePrefs>(SearchSourcePrefs());
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<CatalogueRepository>(repo);
    sl.registerSingleton<MetadataRepository>(_FakeMetadataRepo());
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<TitleSuggestionService>(TitleSuggestionService(Dio()));
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  // The Sources-only source line ("Searching …") is the visible proxy for
  // which repository the bloc was built against — see `_sourceLine` /
  // `_repoForScope` in search_screen.dart. It shows only in Sources scope.
  Finder sourceLine = find.text('Searching');

  testWidgets('no scope chips render, in any mode', (t) async {
    await t.runAsync(() async {
      await ZModePrefs.init();
      await ZModePrefs.setEnabled(true);
    });

    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets(
    'Z Mode off: Search is source-scoped (the path is still there)',
    (t) async {
      // Has to be asked for now. This used to rely on an unopened box reading
      // false; the mode is on by default since the Settings toggle went, so
      // the source-only path needs saying out loud. No UI reaches it any
      // more — this keeps the code path honest.
      await t.runAsync(() async {
        await ZModePrefs.init();
        await ZModePrefs.setEnabled(false);
      });
      await t.pumpWidget(harness());
      await t.pumpAndSettle();

      expect(find.byType(ChoiceChip), findsNothing);
      expect(sourceLine, findsOneWidget);
    },
  );

  testWidgets('Z Mode on: Search is library-scoped', (t) async {
    await t.runAsync(() async {
      await ZModePrefs.init();
      await ZModePrefs.setEnabled(true);
    });

    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    expect(find.byType(ChoiceChip), findsNothing);
    expect(sourceLine, findsNothing);
  });

  testWidgets(
    'forceSources: Search stays source-scoped even with Z Mode on',
    (t) async {
      await t.runAsync(() async {
        await ZModePrefs.init();
        await ZModePrefs.setEnabled(true);
      });

      await t.pumpWidget(harness(forceSources: true));
      await t.pumpAndSettle();

      expect(find.byType(ChoiceChip), findsNothing);
      expect(sourceLine, findsOneWidget);
    },
  );
}
