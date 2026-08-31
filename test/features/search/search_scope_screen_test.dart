// Task 2: scope chips on the Search screen.
//
// Coverage lives entirely in the widget tests below — the screen-level
// default (SearchPrefs().scope ?? (ZModePrefs.enabled ? library : sources))
// is only meaningful once it decides which chip the real screen renders as
// selected on first build, so it's pinned there rather than against a
// standalone helper.
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
import 'package:watch_app/core/playback/search_scope.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
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
}

class _FakeMetadataRepo implements MetadataRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String get sourceId => 'zm';
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
  Widget harness() => MaterialApp(
    home: BlocProvider<ActiveSourceCubit>.value(
      value: sl<ActiveSourceCubit>(),
      child: const SearchScreen(),
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

  ChoiceChip chipLabelled(WidgetTester t, String label) =>
      t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

  testWidgets(
    'Z Mode on, no stored scope: Library chip is selected on first build',
    (t) async {
      await t.runAsync(() async {
        await ZModePrefs.init();
        await ZModePrefs.setEnabled(true);
      });

      await t.pumpWidget(harness());
      await t.pumpAndSettle();

      expect(chipLabelled(t, 'Library').selected, isTrue);
      expect(chipLabelled(t, 'Sources').selected, isFalse);
    },
  );

  testWidgets(
    'Z Mode off, no stored scope: Sources chip is selected on first build '
    '(byte-identical default for the audience that never opted in)',
    (t) async {
      // ZModePrefs box deliberately left unopened — ZModePrefs.enabled reads
      // false when its box was never touched, matching a real off install.
      await t.pumpWidget(harness());
      await t.pumpAndSettle();

      expect(chipLabelled(t, 'Sources').selected, isTrue);
      expect(chipLabelled(t, 'Library').selected, isFalse);
    },
  );

  testWidgets('picking a scope persists it and rebuilds the bloc', (
    t,
  ) async {
    // A scope change must construct a new SearchBloc — the old one holds
    // results from the other index. Asserting on the persisted pref is the
    // stable proxy; the ValueKey is what actually forces the rebuild. Start
    // from Library (Z Mode on) so tapping Sources is an actual change.
    await t.runAsync(() async {
      await ZModePrefs.init();
      await ZModePrefs.setEnabled(true);
    });

    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    // runAsync: tapping Sources persists the scope via a real Hive write
    // (SearchPrefs.setScope), same drain gotcha as the setup calls above.
    await t.runAsync(() async {
      await t.tap(find.text('Sources'));
    });
    await t.pumpAndSettle();

    expect(sl<SearchPrefs>().scope, SearchScope.sources);
    expect(chipLabelled(t, 'Sources').selected, isTrue);
  });
}
