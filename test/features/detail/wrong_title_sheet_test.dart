import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/cubit/detail_cubit.dart';
import 'package:watch_app/features/detail/wrong_title_sheet.dart';

class _Src implements SourceRepository {
  _Src(this.bySource);
  final Map<String, List<MediaItem>> bySource;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String baseUrlFor(String id) =>
      id.startsWith('ani:') || id.startsWith('mihon:') || id.startsWith('lnr:')
          ? 'https://example.test'
          : '';
  @override
  List<({String id, String name})> get loadedSources =>
      [for (final id in bySource.keys) (id: id, name: _name(id))];
  // .contains rather than == so a kind-prefixed id (e.g. 'mihon:allanime',
  // for the manga-candidates test) still resolves to a readable name.
  static String _name(String id) => id.contains('allanime') ? 'AllAnime' : 'HiAnime';
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
  @override
  String displayName(String id) => _name(id);
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      bySource[sourceId] ?? const [];
}

class _None implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get loadedSources => const [];
}

/// A minimal [CatalogueRepository] so [MatchLine]'s reading-kind reload path
/// (`context.read<DetailCubit>().refresh()`) has a real DetailCubit to call
/// into. Counts `detail()` calls so a test can prove that path actually fired.
class _Repo implements CatalogueRepository {
  int detailCalls = 0;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<void> clearHttpCache() async {}
  @override
  Future<MediaDetail> detail(String url, {String category = 'sub', String? sourceId}) async {
    detailCalls++;
    return const MediaDetail(
        id: 'x', title: 'x', url: 'zm://manga/mal:777', type: ProviderType.manga, sourceId: 'zm');
  }
}

/// [TitlePrefsStore] touches Hive on construction-adjacent calls; DetailCubit
/// reads `category()` synchronously in its constructor, so a real store isn't
/// needed here. Mirrors detail_cubit_test.dart's identical fake.
class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;
  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

void main() {
  late Directory dir;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');

  Widget harness(Widget child, {CatalogueRepository? repo, String? url}) => MaterialApp(
    home: Scaffold(
      body: BlocProvider(
        create: (_) => DetailCubit(
          repo: repo ?? _Repo(),
          url: url ?? 'zm://anime/mal:5114',
          prefs: _FakeTitlePrefs(),
        ),
        child: child,
      ),
    ),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wrongshow');
    Hive.init(dir.path);
    final src = _Src({
      'allanime': [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.anime, sourceId: 'allanime')],
      'hianime': [
        MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
            url: 'https://h/2003', type: ProviderType.anime, sourceId: 'hianime'),
        MediaItem(id: 'fmab', title: 'Fullmetal Alchemist: Brotherhood',
            url: 'https://h/fmab', type: ProviderType.anime, sourceId: 'hianime'),
      ],
    });
    final store = await MatchStore.open();
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, candidates: (_) => src.loadedSources));
  });
  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('shows the auto-picked source and Wrong title?', (t) async {
    // MatchLine resolves on first build via a real Hive write, which never
    // drains under the pump-driven testWidgets binding without runAsync —
    // same class of issue as mode_switcher_test.dart's setMode. Pre-resolving
    // here means the write happens inside runAsync, and MatchLine's own
    // build-time resolve() just hits the already-saved fast path.
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();
    expect(find.textContaining('AllAnime'), findsOneWidget);
    expect(find.text('Wrong title?'), findsOneWidget);
  });

  testWidgets('switching source in the picker updates the line', (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();
    expect(find.textContaining('AllAnime'), findsOneWidget);

    await t.tap(find.textContaining('AllAnime'));
    await t.pumpAndSettle();
    expect(find.text('Choose a source'), findsOneWidget);
    expect(find.text('HiAnime'), findsOneWidget);

    await t.runAsync(() async {
      await t.tap(find.text('HiAnime'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsOneWidget);
    expect(sl<MatchStore>().selectedSource(fma), 'hianime');
    // AllAnime's own match is untouched by switching to HiAnime.
    expect(sl<MatchStore>().get(fma, 'allanime')?.sourceId, 'allanime');
  });

  testWidgets('Wrong title? corrects the match for the selected source only', (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();
    // Selected source is allanime (the first candidate to genuinely match).
    await t.tap(find.text('Wrong title?'));
    await t.pumpAndSettle();
    // The sheet only ever searches the selected source (allanime) — its
    // one result is the (2003) title already resolved above.
    expect(find.text('Fullmetal Alchemist (2003)'), findsWidgets);
    expect(find.text('Fullmetal Alchemist: Brotherhood'), findsNothing);

    await t.runAsync(() async {
      await t.tap(find.text('Fullmetal Alchemist (2003)').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(sl<MatchStore>().get(fma, 'allanime')?.pinned, isTrue);
    // HiAnime was never touched by this correction.
    expect(sl<MatchStore>().get(fma, 'hianime'), isNull);
  });

  testWidgets('Wrong title? correction on a video (anime) kind refreshes the Detail screen', (t) async {
    // Anime is a VIDEO kind — the store write is correct either way, but this
    // proves the Detail screen actually re-fetches for it too, not only for
    // manga/novel (see MetadataRepository.detail: video kinds now take their
    // episode list from the matched source as well).
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    final repo = _Repo();
    await t.pumpWidget(harness(
      const MatchLine(canonical: fma, title: 'Fullmetal Alchemist (2003)'),
      repo: repo,
    ));
    await t.pumpAndSettle();
    expect(repo.detailCalls, 0); // nothing corrected yet — no reload

    await t.tap(find.text('Wrong title?'));
    await t.pumpAndSettle();
    // The sheet only ever searches the selected source (allanime) — its one
    // result is the (2003) title already resolved above.
    expect(find.text('Fullmetal Alchemist (2003)'), findsWidgets);

    await t.runAsync(() async {
      await t.tap(find.text('Fullmetal Alchemist (2003)').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(sl<MatchStore>().get(fma, 'allanime')?.pinned, isTrue);
    expect(repo.detailCalls, greaterThan(0));
  });

  testWidgets('a source with no match still appears in the picker; choosing it shows the honest empty state',
      (t) async {
    // hianime is installed but genuinely has nothing matching this title —
    // its own bucket is a different show entirely.
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    final src = _Src({
      'allanime': [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.anime, sourceId: 'allanime')],
      'hianime': [MediaItem(id: 'op', title: 'One Piece',
          url: 'https://h/op', type: ProviderType.anime, sourceId: 'hianime')],
    });
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, candidates: (_) => src.loadedSources));

    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();
    expect(find.textContaining('AllAnime'), findsOneWidget); // auto-picked

    await t.tap(find.textContaining('AllAnime'));
    await t.pumpAndSettle();
    // hianime is offered even though it can't possibly match — not filtered
    // out of the picker for lacking one.
    expect(find.text('HiAnime'), findsOneWidget);

    await t.runAsync(() async {
      await t.tap(find.text('HiAnime'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    // hianime is now selected, honestly with no match — not silently left on
    // allanime, and not crashed/hidden.
    expect(find.textContaining('HiAnime'), findsOneWidget);
    final icon = t.widget<Icon>(find.byIcon(Icons.hub_outlined));
    expect(icon.color, AppColors.textTertiary);
    expect(sl<MatchStore>().get(fma, 'hianime'), isNull);
  });

  testWidgets('switching source on a manga title refreshes the Detail screen chapters', (t) async {
    const manga = ZCanonical(ZKind.manga, 'mal:777');
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    final src = _Src({
      'mihon:allanime': [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.manga, sourceId: 'mihon:allanime')],
      'mihon:hianime': [MediaItem(id: 'fmab', title: 'Fullmetal Alchemist: Brotherhood',
          url: 'https://h/fmab', type: ProviderType.manga, sourceId: 'mihon:hianime')],
    });
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, candidates: (_) => src.loadedSources));

    await t.runAsync(
      () => sl<SourceMatcher>().resolve(manga, title: 'Fullmetal Alchemist (2003)'),
    );
    final repo = _Repo();
    await t.pumpWidget(harness(
      const MatchLine(canonical: manga, title: 'Fullmetal Alchemist (2003)'),
      repo: repo,
      url: 'zm://manga/mal:777',
    ));
    await t.pumpAndSettle();
    expect(repo.detailCalls, 0); // nothing switched yet — no reload

    await t.tap(find.textContaining('AllAnime'));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      await t.tap(find.text('HiAnime'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(repo.detailCalls, greaterThan(0));
  });

  testWidgets(
      'candidates exist but nothing matches anywhere: still says so, still opens '
      'the picker, but there is nothing yet for Wrong title? to correct',
      (t) async {
    // Neither source has anything resembling this title.
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    final src = _Src({'allanime': [], 'hianime': []});
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, candidates: (_) => src.loadedSources));

    await t.pumpWidget(harness(const MatchLine(canonical: fma, title: 'nothing like it')));
    await t.pumpAndSettle();

    expect(find.text('No source has this yet'), findsOneWidget);
    expect(find.text('Wrong title?'), findsNothing);

    // Still tappable — there ARE candidates, the user can still pick one.
    await t.tap(find.text('No source has this yet'));
    await t.pumpAndSettle();
    expect(find.text('Choose a source'), findsOneWidget);
    expect(find.text('AllAnime'), findsOneWidget);
    expect(find.text('HiAnime'), findsOneWidget);
  });

  testWidgets('no installed source at all says so, with nothing to switch or fix', (t) async {
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    final none = _None();
    sl.registerSingleton<SourceRepository>(none);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: none, store: store, candidates: (_) => const []));
    await t.pumpWidget(harness(const MatchLine(canonical: fma, title: 'x')));
    await t.pumpAndSettle();
    expect(find.text('No source has this yet'), findsOneWidget);
    expect(find.text('Wrong title?'), findsNothing);
  });
}
