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
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
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

  test('Auto Resolve reports no match when nothing installed has the title',
      () async {
    final c = build(_Src({'allanime': [], 'hianime': []}));
    await c.load();
    expect(c.state.auto, isTrue);
    expect(c.state.selectedId, isNull);
    expect(c.state.match, isNull);
    expect(c.state.loading, isFalse);
  });

  test('Auto Resolve sweeps every candidate and lands on whoever has it',
      () async {
    // allanime doesn't have it, hianime does — Auto Resolve is not locked to
    // the first candidate, it keeps trying until one genuinely matches.
    final c = build(_Src({'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')]}));
    await c.load();
    expect(c.state.auto, isTrue);
    expect(c.state.selectedId, 'hianime');
    expect(c.state.match?.sourceId, 'hianime');
    expect(c.state.loading, isFalse);
  });

  test('switching source pins THIS TITLE only, independently matched', () async {
    final c = build(_Src({
      'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
      'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
    }));
    await c.load();
    expect(c.state.selectedId, 'allanime');
    await c.selectSource('hianime');
    expect(c.state.selectedId, 'hianime');
    expect(c.state.match?.sourceId, 'hianime');
    expect(c.state.auto, isFalse);
    // A per-title pin, not a kind-wide default — no other title of this kind
    // is affected.
    expect(prefs.get(fma.kind), isNull);
    expect(store.pinnedFor(fma)?.sourceId, 'hianime');
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
    // Nothing to pin — the title falls back to Auto Resolve again.
    expect(store.pinnedFor(fma), isNull);
  });

  test('selectAuto clears a title pin and goes back to sweeping', () async {
    final c = build(_Src({
      'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
      'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
    }));
    await c.load();
    await c.selectSource('hianime');
    expect(c.state.auto, isFalse);
    await c.selectAuto();
    expect(c.state.auto, isTrue);
    expect(store.pinnedFor(fma), isNull);
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

  test('a remembered kind default names its source before load() is even called',
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
    expect(c.state.auto, isFalse);
  });

  test('a title never opened before is Auto Resolve, not a fixed source',
      () async {
    // Nothing stored for this title OR this kind, and no load() yet — the
    // true default is Auto Resolve, not silently pinning the first candidate.
    final c = build(_Src({}));
    expect(c.state.auto, isTrue);
    expect(c.state.selectedId, isNull);
    expect(c.state.match, isNull);
  });

  test('an empty candidate list never marks itself loading forever', () async {
    final c = build(_Src({}), sources: const []);
    expect(c.state.loading, isFalse);
    await c.load(); // no-op — nothing to resolve
    // Nothing installed for this kind is the ONLY case with no source to name.
    expect(c.state.selectedId, isNull);
  });
}
