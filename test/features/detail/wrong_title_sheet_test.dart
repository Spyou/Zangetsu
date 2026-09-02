import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/picker_deps.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
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
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  String baseUrlFor(String id) =>
      id.startsWith('ani:') || id.startsWith('mihon:') || id.startsWith('lnr:')
          ? 'https://example.test'
          : '';
  @override
  List<({String id, String name})> get loadedSources =>
      [for (final id in bySource.keys) (id: id, name: _name(id))];
  // .contains rather than == so a kind-prefixed id (e.g. 'mihon:1',
  // for the manga-candidates test) still resolves to a readable name.
  // Source ids are the real `ani:<n>` / `mihon:<n>` shape now, because the
  // picker builds its rows from the app's registries rather than this fake.
  static String _name(String id) =>
      (id == 'ani:1' || id == 'mihon:1') ? 'AllAnime' : 'HiAnime';
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
  List<({String id, String name})> get pickableSources => loadedSources;
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
  Future<MediaDetail> detail(String url, {String category = 'sub', String? sourceId, void Function(MediaDetail partial)? onPartial}) async {
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
  late ZSourcePrefs prefs;
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
    await registerPickerDeps(aniyomi: [
      aniSource(id: 1, name: 'AllAnime'),
      aniSource(id: 2, name: 'HiAnime'),
    ]);
    // Picker rows probe the native side for per-source settings. These tests
    // are about matching, not settings, so answer "none" rather than let an
    // unimplemented channel throw mid-build.
    for (final ch in const ['zangetsu/aniyomi', 'zangetsu/mihon']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(ch),
        (call) async => call.method == 'hasSourceSettings' ? false : null,
      );
    }
    final src = _Src({
      'ani:1': [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.anime, sourceId: 'ani:1')],
      'ani:2': [
        MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
            url: 'https://h/2003', type: ProviderType.anime, sourceId: 'ani:2'),
        MediaItem(id: 'fmab', title: 'Fullmetal Alchemist: Brotherhood',
            url: 'https://h/fmab', type: ProviderType.anime, sourceId: 'ani:2'),
      ],
    });
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));
  });
  tearDown(() async {
    await disposePickerDeps();
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
    // The shared picker has no title row — its tabs identify it.
    expect(find.text('Movies/Series'), findsOneWidget);
    expect(find.textContaining('HiAnime'), findsOneWidget);

    await t.runAsync(() async {
      await t.tap(find.textContaining('HiAnime'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsOneWidget);
    expect(prefs.get(fma.kind), 'ani:2');
    // AllAnime's own match is untouched by switching to HiAnime.
    expect(sl<MatchStore>().get(fma, 'ani:1')?.sourceId, 'ani:1');
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

    expect(sl<MatchStore>().get(fma, 'ani:1')?.pinned, isTrue);
    // HiAnime was never touched by this correction.
    expect(sl<MatchStore>().get(fma, 'ani:2'), isNull);
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

    expect(sl<MatchStore>().get(fma, 'ani:1')?.pinned, isTrue);
    expect(repo.detailCalls, greaterThan(0));
  });

  testWidgets('the row names the title it matched, so a wrong one is visible',
      (t) async {
    // The case this control exists for: the source matched confidently, but to
    // the wrong show. Same source name, a full episode list — indistinguishable
    // from a correct match unless the matched TITLE is on screen.
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final src = _Src({
      'ani:1': [MediaItem(id: 'brother', title: 'Fullmetal Alchemist Brotherhood',
          url: 'https://a/bro', type: ProviderType.anime, sourceId: 'ani:1')],
    });
    await registerPickerDeps(aniyomi: [aniSource(id: 1, name: 'AllAnime')]);
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));

    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist Brotherhood'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist Brotherhood')));
    await t.pumpAndSettle();

    // The source, and what it landed on, both on screen without opening a thing.
    expect(find.textContaining('AllAnime'), findsOneWidget);
    expect(find.text('Fullmetal Alchemist Brotherhood'), findsOneWidget);
    expect(find.text('Wrong title?'), findsOneWidget);
  });

  testWidgets('a source with no match still appears in the picker; choosing it shows the honest empty state',
      (t) async {
    // hianime is installed but genuinely has nothing matching this title —
    // its own bucket is a different show entirely.
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final src = _Src({
      'ani:1': [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.anime, sourceId: 'ani:1')],
      'ani:2': [MediaItem(id: 'op', title: 'One Piece',
          url: 'https://h/op', type: ProviderType.anime, sourceId: 'ani:2')],
    });
    // sl.reset() above dropped the picker's own singletons; the sheet needs
    // them back before it can be opened.
    await registerPickerDeps(aniyomi: [
      aniSource(id: 1, name: 'AllAnime'),
      aniSource(id: 2, name: 'HiAnime'),
    ]);
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));

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
    expect(find.textContaining('HiAnime'), findsOneWidget);

    await t.runAsync(() async {
      await t.tap(find.textContaining('HiAnime'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    // hianime is now selected, honestly with no match — not silently left on
    // allanime, and not crashed/hidden.
    expect(find.textContaining('HiAnime'), findsOneWidget);
    // "Selected but nothing behind it" is said in words, not just signalled by
    // dimming the name: a picked source keeps its normal label (you need to
    // read WHICH source is selected in order to change it) and the pill
    // carries an explicit line underneath saying it has nothing.
    final name = t.widget<Text>(find.textContaining('HiAnime'));
    expect(name.style?.color, AppColors.textPrimary);
    expect(find.text('No episodes available from this source'), findsOneWidget);
    expect(sl<MatchStore>().get(fma, 'ani:2'), isNull);
  });

  testWidgets('switching source on a manga title refreshes the Detail screen chapters', (t) async {
    const manga = ZCanonical(ZKind.manga, 'mal:777');
    await sl.reset();
    Hive.init(dir.path);
    // runAsync: seeding the mode writes to Hive, and a real write never drains
    // under the pump-driven binding.
    await t.runAsync(() => registerPickerDeps(
          mode: ContentMode.manga,
          mihon: [
            mihonSource(id: 1, name: 'AllAnime'),
            mihonSource(id: 2, name: 'HiAnime'),
          ],
        ));
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final src = _Src({
      'mihon:1': [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.manga, sourceId: 'mihon:1')],
      'mihon:2': [MediaItem(id: 'fmab', title: 'Fullmetal Alchemist: Brotherhood',
          url: 'https://h/fmab', type: ProviderType.manga, sourceId: 'mihon:2')],
    });
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));

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
      await t.tap(find.textContaining('HiAnime'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(repo.detailCalls, greaterThan(0));
  });

  testWidgets(
      'a source that has nothing is still named, and Wrong title? still offered',
      (t) async {
    // Neither source has anything resembling this title.
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final src = _Src({'ani:1': [], 'ani:2': []});
    // sl.reset() above dropped the picker's own singletons; the sheet needs
    // them back before it can be opened.
    await registerPickerDeps(aniyomi: [
      aniSource(id: 1, name: 'AllAnime'),
      aniSource(id: 2, name: 'HiAnime'),
    ]);
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));

    // Cached miss from a prior search — no Detail-open lookup needed.
    await store.rememberMiss(fma, 'ani:1');

    await t.pumpWidget(
        harness(const MatchLine(canonical: fma, title: 'nothing like it')));
    await t.pumpAndSettle();

    // The source is a choice, not a search result, so the row names it even
    // though it turned out to have nothing — and says so underneath, with
    // Wrong title? there to correct the match.
    expect(find.textContaining('AllAnime'), findsWidgets);
    expect(find.text('No source has this yet'), findsNothing);
    expect(find.text('Wrong title?'), findsOneWidget);
    expect(find.text('No episodes available from this source'), findsOneWidget);

    await t.tap(find.textContaining('AllAnime').first);
    await t.pumpAndSettle();
    // The shared picker has no title row — its tabs identify it. Both sources
    // are offered; AllAnime appears twice now (the pill names it too).
    expect(find.text('Movies/Series'), findsOneWidget);
    expect(find.textContaining('AllAnime'), findsWidgets);
    expect(find.textContaining('HiAnime'), findsOneWidget);
  });

  testWidgets('no installed source hides the match row', (t) async {
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final none = _None();
    sl.registerSingleton<SourceRepository>(none);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: none, store: store, prefs: prefs, candidates: (_) => const []));
    await t.pumpWidget(harness(const MatchLine(canonical: fma, title: 'x')));
    await t.pumpAndSettle();
    expect(find.text('No source has this yet'), findsNothing);
    expect(find.text('Wrong title?'), findsNothing);
  });
}
