import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/cubit/source_select_cubit.dart';

MediaItem _hit(String src, String title) => MediaItem(
  id: title.toLowerCase(), title: title, url: 'https://$src/$title',
  type: ProviderType.anime, sourceId: src);

class _Src implements SourceRepository {
  _Src(this.bySource);
  final Map<String, List<MediaItem>> bySource;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  String baseUrlFor(String id) =>
      id.startsWith('ani:') || id.startsWith('mihon:') || id.startsWith('lnr:')
          ? 'https://example.test'
          : '';
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      bySource[sourceId] ?? const [];
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');
  final two = [(id: 'allanime', name: 'AllAnime'), (id: 'hianime', name: 'HiAnime')];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source_select_cubit');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  SourceSelectCubit build(SourceRepository src, {List<({String id, String name})>? sources}) =>
      SourceSelectCubit(
        store: store,
        // The matcher must see the same candidate list the cubit was given —
        // in the app both come from candidatesForKind, and the selection is
        // now read from the matcher, so a disagreement here would be fiction.
        matcher: SourceMatcher(
            sources: src,
            store: store,
            prefs: prefs,
            candidates: (_) => sources ?? two),
        canonical: fma,
        sources: sources ?? two,
        title: 'Fullmetal Alchemist: Brotherhood',
      );

  test('Auto Resolve names no source when nothing anywhere has the title',
      () async {
    final c = build(_Src({'allanime': [], 'hianime': []}));
    await c.load();
    // Under Auto Resolve the source IS the sweep's answer, not a choice made
    // up front — so with no candidate holding the title there is honestly
    // none to name. Naming the first one anyway would point the row's
    // per-source actions (Cloudflare solve, sign in) at a site that never
    // had it. Picking one from the row is how you override this.
    expect(c.state.auto, isTrue);
    expect(c.state.selectedId, isNull);
    expect(c.state.match, isNull);
    expect(c.state.loading, isFalse);
  });

  test('an explicit kind default matches on that source, not whoever has the title',
      () async {
    // hianime has it, allanime does not — but allanime is the firm choice for
    // this kind, so there is no match. A deliberate pick is not silently
    // swapped for the source that happens to have the title; only Auto
    // Resolve sweeps, which is the test below.
    await prefs.set(fma.kind, 'allanime');
    final c = build(_Src({'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')]}));
    await c.load();
    expect(c.state.auto, isFalse);
    expect(c.state.selectedId, 'allanime');
    expect(c.state.match, isNull);
    expect(c.state.loading, isFalse);
  });

  test('Auto Resolve lands on whichever source actually has the title', () async {
    // The same setup with no kind default: sweeping is the point, so the
    // source that has it is the one named, even though it is second in order.
    final c = build(_Src({'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')]}));
    await c.load();
    expect(c.state.auto, isTrue);
    expect(c.state.selectedId, 'hianime');
    expect(c.state.match?.sourceId, 'hianime');
    expect(c.state.loading, isFalse);
  });

  test('switching source updates the state to the new source, independently matched', () async {
    final c = build(_Src({
      'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
      'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
    }));
    await c.load();
    expect(c.state.selectedId, 'allanime');
    await c.selectSource('hianime');
    expect(c.state.selectedId, 'hianime');
    expect(c.state.match?.sourceId, 'hianime');
    // Picking pins THIS title to hianime and deliberately leaves the kind
    // default alone — every other title of this kind still resolves on its own.
    expect(store.get(fma, 'hianime')?.pinned, isTrue);
    expect(prefs.get(fma.kind), isNull);
    // Both sources kept their own match.
    expect(store.get(fma, 'allanime')?.sourceId, 'allanime');
    expect(store.get(fma, 'hianime')?.sourceId, 'hianime');
  });

  test('a source with no match shows the honest empty state after selecting it', () async {
    final c = build(_Src({
      'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
      'hianime': [], // installed, but genuinely doesn't have this title
    }));
    await c.load();
    await c.selectSource('hianime');
    expect(c.state.selectedId, 'hianime');
    expect(c.state.match, isNull);
    expect(c.state.loading, isFalse);
  });

  test('applyPinned reflects a "Wrong title?" correction without a re-search', () async {
    final c = build(_Src({}));
    await c.load();
    const pinned = SourceMatch(sourceId: 'hianime', showUrl: 'u', showId: 'i',
        showTitle: 't', pinned: true);
    c.applyPinned(pinned);
    expect(c.state.selectedId, 'hianime');
    expect(c.state.match, pinned);
    expect(c.state.loading, isFalse);
  });

  test('a remembered title names its source before load() is even called',
      () async {
    // What the Detail screen sees on its first frame. Both reads are on disk
    // already, so holding the row blank until the sweep finished was
    // re-deriving an answer we had.
    prefs.set(fma.kind, 'hianime');
    await store.save(fma, const SourceMatch(
        sourceId: 'hianime', showUrl: 'h', showId: 'h', showTitle: 'FMA',
        pinned: false));

    // A source that would hang if asked — proving nothing here waits on it.
    final c = build(_Src({}));
    expect(c.state.selectedId, 'hianime');
    expect(c.state.match?.showTitle, 'FMA');
  });

  test('a title never opened before names nothing until the sweep lands',
      () async {
    // Nothing stored for this title OR this kind, and no load() yet. The row
    // reads "Auto Resolve" rather than guessing the first candidate — the
    // sweep may well settle on another one, and the row's per-source actions
    // act on whatever id it shows.
    final c = build(_Src({}));
    expect(c.state.auto, isTrue);
    expect(c.state.selectedId, isNull);
    expect(c.state.match, isNull);
  });

  test('an empty candidate list never marks itself loading forever', () async {
    final c = build(_Src({}), sources: const []);
    expect(c.state.loading, isFalse);
    await c.load(); // no-op — nothing to resolve
    expect(c.state.selectedId, isNull);
  });
}
