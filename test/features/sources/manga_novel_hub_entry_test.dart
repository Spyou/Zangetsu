// Task E3 originally gave manga/novel sources their own "Zangetsu Manga" hub
// row and a "Manga & Novel" Settings entry. BOTH were later removed —
// (and the Sozo Read recommended-repo suggestion, tested elsewhere) was
// dropped: that Zangetsu JS reading-source row duplicated the still-live
// Settings entry, and those JS sources are search-only (no popular/latest),
// so selecting one left Home with nothing to render. The Settings entry
// itself is unaffected and still opens the same scoped Zangetsu screen.
//
// What's under test now:
//  - ProvidersHubScreen (phone view) has no "Zangetsu Manga" row / section —
//    the existing three streaming rows stay exactly as they are today, and
//    the ACTIVE-badge exclusivity rule (a reading source must not badge the
//    Zangetsu streaming row) still holds even with the dedicated row gone.
//  - Settings → Sources no longer has a "Manga & Novel" entry.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/features/sources/providers_hub_screen.dart';
import 'package:watch_app/features/sources/zangetsu_sources_screen.dart';

// ---------------------------------------------------------------------------
// Shared fakes
// ---------------------------------------------------------------------------

/// Fixed installed-entries + manifest-type lookup, so reading (manga/novel)
/// vs. video (anime/movie) counts are deterministic without wiring up a real
/// cached repo manifest.
class _FakeProviderRegistry implements ProviderRegistry {
  _FakeProviderRegistry(this._entries, this._types);
  final List<ProviderRegistryEntry> _entries;
  final Map<String, String> _types;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => _entries;

  @override
  ProviderRegistryEntry? entryFor(String sourceId) {
    for (final e in _entries) {
      if (e.name == sourceId) return e;
    }
    return null;
  }

  @override
  Set<String> nsfwSourceIds() => const {};

  @override
  String? typeOf(String sourceId) => _types[sourceId];

  // SourcesBloc (built when ZangetsuSourcesScreen is pushed) subscribes to
  // this on construction.
  @override
  Stream<BoxEvent> watch() => const Stream<BoxEvent>.empty();
}

class _FakeReposRegistry implements ProviderReposRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRepo> getAll() => const [];

  @override
  Stream<BoxEvent> watch() => const Stream<BoxEvent>.empty();
}

void main() {
  final sl = GetIt.instance;

  // ── ProvidersHubScreen (phone) ──────────────────────────────────────────
  group('ProvidersHubScreen phone view', () {
    setUp(() {
      final entries = [
        ProviderRegistryEntry(
          name: 'anime1',
          url: 'bundled://anime1',
          displayName: 'Anime One',
        ),
        ProviderRegistryEntry(
          name: 'manga1',
          url: 'bundled://manga1',
          displayName: 'Manga One',
        ),
        ProviderRegistryEntry(
          name: 'novel1',
          url: 'bundled://novel1',
          displayName: 'Novel One',
        ),
      ];
      final types = {'anime1': 'anime', 'manga1': 'manga', 'novel1': 'novel'};

      sl
        ..registerSingleton<AppMode>(const AppMode(isTv: false))
        ..registerSingleton<ProviderRegistry>(
          _FakeProviderRegistry(entries, types),
        )
        ..registerSingleton<ProviderReposRegistry>(_FakeReposRegistry())
        ..registerSingleton<CloudStreamManager>(CloudStreamManager())
        ..registerSingleton<AniyomiManager>(AniyomiManager())
        ..registerSingleton<MihonManager>(MihonManager())
        ..registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: ''));
    });

    tearDown(() async {
      await sl.reset();
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: ProvidersHubScreen()));
      await tester.pumpAndSettle();
    }

    // The dedicated "Zangetsu Manga" hub row and its MANGA & NOVEL section
    // are gone — those JS reading sources are search-only, so selecting one
    // left Home with nothing to render. Reading sources are still reachable
    // through Settings → Manga & Novel (unaffected, tested elsewhere), just
    // not from this hub. Inverse assertion so the row can't silently
    // reappear.
    testWidgets('has no Zangetsu Manga row or MANGA & NOVEL section',
        (tester) async {
      await pump(tester);

      expect(find.text('Zangetsu Manga'), findsNothing);
      expect(find.text('MANGA & NOVEL'), findsNothing);
    });

    testWidgets(
      'the existing Zangetsu row is unchanged — same title, desc and '
      'unfiltered total (reading sources still count toward it, as today)',
      (tester) async {
        await pump(tester);

        expect(find.text('Zangetsu'), findsOneWidget);
        expect(find.text('Built-in JS providers'), findsOneWidget);
        expect(find.text('3 sources'), findsOneWidget); // all 3, unfiltered
      },
    );

    testWidgets(
      'CloudStream and Aniyomi rows are unaffected — still Android-gated, '
      'absent on this (non-Android) test host, same as before',
      (tester) async {
        await pump(tester);

        expect(find.text('CloudStream'), findsNothing);
        expect(find.text('Aniyomi'), findsNothing);
      },
    );

    // ── Fix round 1, finding 1: ACTIVE badge must be exclusive ────────────
    testWidgets(
      'an anime active source badges the Zangetsu row (unchanged today)',
      (tester) async {
        sl.unregister<ActiveSourceCubit>();
        sl.registerSingleton<ActiveSourceCubit>(
          ActiveSourceCubit(fallback: 'anime1'),
        );
        await pump(tester);

        // Only row on screen in this (non-Android) test host is Zangetsu —
        // CS/Aniyomi/Mihon are all Android-gated — so a single ACTIVE badge
        // sitting right on Zangetsu's line is what "badges the Zangetsu row"
        // reduces to here.
        expect(find.text('ACTIVE'), findsOneWidget);
        final activeY = tester.getTopLeft(find.text('ACTIVE')).dy;
        final zangetsuY = tester.getTopLeft(find.text('Zangetsu')).dy;
        expect((activeY - zangetsuY).abs(), lessThan(30));
      },
    );

    // The Zangetsu Manga row this used to compare against is gone, but the
    // rule it guarded is still live: a reading source active under the
    // Zangetsu ecosystem must not badge the Zangetsu *streaming* row.
    // (activeIsReading in providers_hub_screen.dart.)
    testWidgets(
      'a manga active source does not badge the Zangetsu streaming row',
      (tester) async {
        sl.unregister<ActiveSourceCubit>();
        sl.registerSingleton<ActiveSourceCubit>(
          ActiveSourceCubit(fallback: 'manga1'),
        );
        await pump(tester);

        // No dedicated reading row exists any more to carry the badge
        // instead, so with the exclusion working, nothing should show
        // ACTIVE at all.
        expect(find.text('ACTIVE'), findsNothing);
      },
    );

    // scopeToReading is still live production behavior of
    // ZangetsuSourcesScreen — just no longer reachable from this hub. It's
    // still reachable from Settings → Manga & Novel (untouched), so this
    // pins the behavior directly rather than losing coverage of it.
    testWidgets(
      'ZangetsuSourcesScreen(scopeToReading: true) scopes the Installed tab '
      'to reading providers, with a Show all escape hatch back to everything',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: ZangetsuSourcesScreen(scopeToReading: true),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Manga One'), findsOneWidget);
        expect(find.text('Novel One'), findsOneWidget);
        // Anime provider is hidden by default — this is the actual "different
        // from streaming mode" the user asked for, not just a different tile.
        expect(find.text('Anime One'), findsNothing);

        // The user can still always reach everything.
        final showAll = find.text('Show all');
        expect(showAll, findsOneWidget);
        await tester.tap(showAll);
        await tester.pumpAndSettle();

        expect(find.text('Anime One'), findsOneWidget);
        expect(find.text('Manga One'), findsOneWidget);
        expect(find.text('Novel One'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping Zangetsu (unscoped) still shows every provider, no scoping UI',
      (tester) async {
        await pump(tester);

        await tester.tap(find.text('Zangetsu'));
        await tester.pumpAndSettle();

        expect(find.text('Anime One'), findsOneWidget);
        expect(find.text('Manga One'), findsOneWidget);
        expect(find.text('Novel One'), findsOneWidget);
        expect(find.text('Show all'), findsNothing);
      },
    );
  });

  // ── Settings → Sources ──────────────────────────────────────────────────
  group('Settings Sources section', () {
    late ActiveSourceCubit activeCubit;
    late Directory hiveDir;

    setUp(() async {
      hiveDir = await Directory.systemTemp.createTemp();
      Hive.init(hiveDir.path);
      await Hive.openBox(DownloadPrefs.boxName);
      await Hive.openBox(TorrentPrefs.boxName);
      await Hive.openBox(ThemeController.boxName);
      await Hive.openBox(PlaybackPrefs.boxName);
      sl
        ..registerSingleton<AppMode>(const AppMode(isTv: false))
        ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
        ..registerSingleton<ProviderRegistry>(_FakeProviderRegistry(
          [
            ProviderRegistryEntry(name: 'manga1', url: 'bundled://manga1'),
          ],
          {'manga1': 'manga'},
        ))
        ..registerSingleton<AniListService>(_StubAniList())
        ..registerSingleton<MalService>(_StubMal())
        ..registerSingleton<SimklService>(_StubSimkl())
        ..registerSingleton<PlaybackPrefs>(PlaybackPrefs())
        ..registerSingleton<DownloadPrefs>(DownloadPrefs())
        ..registerSingleton<TorrentPrefs>(TorrentPrefs());
      activeCubit = ActiveSourceCubit();
    });

    tearDown(() async {
      await activeCubit.close();
      await GetIt.instance.reset();
      await Hive.deleteFromDisk();
      if (hiveDir.existsSync()) await hiveDir.delete(recursive: true);
    });

    Future<void> pumpSettings(WidgetTester tester) async {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => '/tmp/test',
      );
      await tester.binding.setSurfaceSize(const Size(1000, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final authCubit =
          AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);
      GetIt.instance.registerSingleton<AuthCubit>(authCubit);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<ActiveSourceCubit>.value(value: activeCubit),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the Sources section keeps its entries and has NO Manga & Novel row',
      (tester) async {
        await pumpSettings(tester);

        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();

        // The reading entry was dropped along with the providers-hub row —
        // those JS sources are search-only, so Home had nothing to render.
        // Manga lives under Providers -> Mihon. Asserting its ABSENCE stops it
        // silently returning.
        expect(find.text('Manga & Novel'), findsNothing);

        for (final t in const [
          'Providers',
          'Active source',
          'Source health',
          'Auto-update extensions',
        ]) {
          expect(find.text(t), findsOneWidget, reason: 'tile: $t');
        }

        // The surviving entries keep their original relative order.
        final providersY = tester.getTopLeft(find.text('Providers')).dy;
        final activeSourceY = tester.getTopLeft(find.text('Active source')).dy;
        final healthY = tester.getTopLeft(find.text('Source health')).dy;
        expect(providersY, lessThan(activeSourceY));
        expect(activeSourceY, lessThan(healthY));
      },
    );

    testWidgets('searching "manga" surfaces no reading Settings entry',
        (tester) async {
      await pumpSettings(tester);

      await tester.enterText(find.byType(TextField), 'manga');
      await tester.pumpAndSettle();

      expect(find.text('Manga & Novel'), findsNothing);
    });
  });
}

MigrationBridge _fakeBridge() => MigrationBridge(
      invoke: (_, __) async => const {'ok': false},
      signInPassword: (_, __) async => false,
      verifyOtp: (_, __) async => false,
    );

class _StubSearchPrefs extends SearchPrefs {
  @override
  SearchLayout get layout => SearchLayout.vertical;
}

class _StubAniList implements AniListService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMal implements MalService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubSimkl implements SimklService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
