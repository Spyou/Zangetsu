// Task M8b: Mihon (manga extensions) gets a 4th hub row, mirroring how
// CloudStream/Aniyomi already work — Android-gated, live-updating counts.
//
// Platform.isAndroid can't be faked in `flutter test` (it reports false on
// the host running these tests — the same observation
// `lib/core/mihon/mihon_provider.dart`'s doc comment makes about the channel
// calls), so, like the existing CloudStream/Aniyomi row assertions in
// `manga_novel_hub_entry_test.dart`, this file can't directly exercise the
// row's on-Android appearance. What it CAN and does prove:
//  - the row stays fully absent off-Android, same as CloudStream/Aniyomi;
//  - a Mihon source's count/updates do NOT leak into the header total when
//    the row itself is gated off — the exact place a broken
//    `showMihon ? x : 0` guard would silently show up;
//  - a `mihon:` active source id is excluded from `activeIsZangetsu`, so it
//    no longer misbadges the Zangetsu row as ACTIVE (the bug the task
//    specifically flagged as a risk);
//  - the existing Zangetsu/CloudStream/Aniyomi rows and their counts are
//    completely unaffected by the new row.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';
import 'package:watch_app/core/mihon/mihon_update.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/sources/providers_hub_screen.dart';

// ---------------------------------------------------------------------------
// Fakes — same shape as manga_novel_hub_entry_test.dart's (private to that
// file, so re-declared here rather than shared).
// ---------------------------------------------------------------------------

class _FakeProviderRegistry implements ProviderRegistry {
  _FakeProviderRegistry(this._entries);
  final List<ProviderRegistryEntry> _entries;

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
  String? typeOf(String sourceId) => null;

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

MihonProvider _mihonSrc(int id, String name) => MihonProvider(
      info: MihonSourceInfo(
        id: id,
        name: name,
        lang: 'en',
        baseUrl: '',
        pkg: 'p.$id',
        nsfw: false,
      ),
    );

void main() {
  final sl = GetIt.instance;

  setUp(() {
    final entries = [
      ProviderRegistryEntry(
        name: 'anime1',
        url: 'bundled://anime1',
        displayName: 'Anime One',
      ),
      ProviderRegistryEntry(
        name: 'anime2',
        url: 'bundled://anime2',
        displayName: 'Anime Two',
      ),
    ];
    sl
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<ProviderRegistry>(_FakeProviderRegistry(entries))
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

  testWidgets(
    'Mihon row stays absent off-Android, same as CloudStream/Aniyomi',
    (tester) async {
      await pump(tester);

      expect(find.text('Mihon'), findsNothing);
      expect(find.text('CloudStream'), findsNothing);
      expect(find.text('Aniyomi'), findsNothing);
    },
  );

  testWidgets(
    'the TV hub view never renders a Mihon row — the hub row is phone-only '
    'by spec, and _HubTvView was not touched by this task',
    (tester) async {
      sl.unregister<AppMode>();
      sl.registerSingleton<AppMode>(const AppMode(isTv: true));
      sl<MihonManager>().register(_mihonSrc(1, 'Manga One'));

      await pump(tester);

      expect(find.text('Mihon'), findsNothing);
      // Sanity: this really did render the TV view, not silently fall back
      // to the phone view.
      expect(find.text('Providers'), findsOneWidget);
    },
  );

  testWidgets(
    'the existing Zangetsu row count is unaffected by a registered Mihon '
    'source',
    (tester) async {
      sl<MihonManager>().register(_mihonSrc(1, 'Manga One'));
      await pump(tester);

      // Only the 2 Zangetsu entries — the Mihon source must not leak into
      // the Zangetsu row's count.
      expect(find.text('2 sources'), findsOneWidget);
    },
  );

  testWidgets(
    "a registered Mihon source and its pending update don't leak into the "
    'header total (the guard this task added: showMihon ? x : 0)',
    (tester) async {
      final mihon = sl<MihonManager>()..register(_mihonSrc(1, 'Manga One'));
      mihon.checkerOverride = (url, codes) async => [
            MihonUpdate(
              pkg: 'p.1',
              name: 'Manga One',
              installedCode: 1,
              availableCode: 2,
              availableVersion: '2.0',
              entry: AniyomiRepoEntry(
                name: 'Manga One',
                pkg: 'p.1',
                apk: 'p.1.apk',
                lang: 'en',
                version: '2.0',
                code: 2,
                nsfw: false,
                sources: const [],
                repoBaseUrl: 'https://r/x',
              ),
            ),
          ];
      await mihon.checkRepoUpdates('https://r/x');
      expect(mihon.updateCount, 1, reason: 'sanity: the update is real');

      await pump(tester);

      // Header total stays at 2 (the Zangetsu entries only) and no updates
      // pill is shown — both would fail if the count/updates guard were
      // ever made unconditional.
      expect(find.text('2 sources ready'), findsOneWidget);
      expect(find.textContaining('update'), findsNothing);
    },
  );

  testWidgets(
    'a mihon: active id does not badge the Zangetsu row as ACTIVE',
    (tester) async {
      sl.unregister<ActiveSourceCubit>();
      sl.registerSingleton<ActiveSourceCubit>(
        ActiveSourceCubit(fallback: 'mihon:1'),
      );
      await pump(tester);

      // Before this task, activeIsZangetsu didn't exclude mihon: ids, so the
      // Zangetsu row would have shown ACTIVE here. Off-Android the Mihon row
      // itself is hidden, so correctly nothing should show ACTIVE at all.
      expect(find.text('ACTIVE'), findsNothing);
    },
  );

  testWidgets(
    '_activeSourceLabel resolves a registered mihon: id to its display name',
    (tester) async {
      sl<MihonManager>().register(_mihonSrc(1, 'Manga One'));
      sl.unregister<ActiveSourceCubit>();
      sl.registerSingleton<ActiveSourceCubit>(
        ActiveSourceCubit(fallback: 'mihon:1'),
      );
      await pump(tester);

      expect(find.textContaining('Active: Manga One'), findsOneWidget);
    },
  );
}
