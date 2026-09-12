// Reading does not sweep. A sweep is only safe where something can recover
// from a bad pick — video re-resolves per episode at tap time, reading does
// not: the matched source owns the chapter list outright. So reading picks a
// source once and stays there, and a miss is reported as a miss rather than
// quietly answered by whichever other source happens to have something.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

class _Src implements SourceRepository {
  _Src(this.bySource);
  final Map<String, List<MediaItem>> bySource;
  final searched = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  /// Installed is not the same as "has results" — a source with nothing for
  /// this title is still installed, and still costs a search to find that out.
  @override
  bool hasSource(String sourceId) => true;
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async {
    searched.add(sourceId ?? '');
    return bySource[sourceId] ?? const [];
  }
}

MediaItem _hit(String src, String title) => MediaItem(
  id: '$src-id',
  title: title,
  url: 'https://$src/x',
  type: ProviderType.manga,
  sourceId: src,
);

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late _Src src;

  const one = ZCanonical(ZKind.manga, 'mal:1');
  const two = ZCanonical(ZKind.manga, 'mal:2');
  const anime = ZCanonical(ZKind.anime, 'mal:3');
  const a = 'Solo Leveling';
  const b = 'Omniscient Reader';

  const all = [
    (id: 'mihon:dex', name: 'MangaDex'),
    (id: 'mihon:asura', name: 'Asura'),
  ];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reading_no_sweep');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  SourceMatcher build() => SourceMatcher(
    sources: src,
    store: store,
    prefs: prefs,
    candidates: (_) => all,
    sweepCandidates: (_) => all,
  );

  test('the first reading title sweeps, and that source is kept', () async {
    // Bootstrap: nothing is remembered on a fresh install, so it sweeps once
    // rather than leaving a new user staring at an empty page.
    src = _Src({'mihon:asura': [_hit('mihon:asura', a)]});
    await build().resolve(one, title: a);

    expect(src.searched, ['mihon:dex', 'mihon:asura']);
    expect(prefs.lastGood(ZKind.manga), 'mihon:asura');
  });

  test('every reading title after that is ONE search', () async {
    src = _Src({
      'mihon:dex': [_hit('mihon:dex', b)],
      'mihon:asura': [_hit('mihon:asura', a), _hit('mihon:asura', b)],
    });
    final m = build();
    await m.resolve(one, title: a); // bootstraps to asura
    src.searched.clear();

    await m.resolve(two, title: b);

    expect(src.searched, ['mihon:asura']);
  });

  test('a title the reading source lacks is a miss, not another source',
      () async {
    // The honest answer. Reaching for MangaDex here would hand the reader a
    // different numbering under the source name they picked.
    src = _Src({
      'mihon:asura': [_hit('mihon:asura', a)],
      'mihon:dex': [_hit('mihon:dex', b)],
    });
    final m = build();
    await m.resolve(one, title: a); // remembers asura
    src.searched.clear();

    expect(await m.resolve(two, title: b), isNull);
    expect(src.searched, ['mihon:asura']);
  });

  group('novel keeps its own memory', () {
    const novel = ZCanonical(ZKind.novel, 'mal:9');
    const bothPools = [
      (id: 'mihon:asura', name: 'Asura'),
      (id: 'lnr:one', name: 'Novel One'),
    ];

    SourceMatcher both() => SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => bothPools,
      sweepCandidates: (_) => bothPools,
    );

    test('a manga source is never handed to a novel', () async {
      // Separate pools entirely — an LNReader plugin cannot serve manga and a
      // Mihon extension cannot serve a novel. One shared memory would point
      // each at the other's source and neither would ever resolve.
      src = _Src({
        'mihon:asura': [_hit('mihon:asura', a)],
        'lnr:one': [_hit('lnr:one', b)],
      });
      final m = both();

      await m.resolve(one, title: a); // manga
      await m.resolve(novel, title: b); // novel

      expect(prefs.lastGood(ZKind.manga), 'mihon:asura');
      expect(prefs.lastGood(ZKind.novel), 'lnr:one');
    });

    test('novel stops sweeping too, once it has one', () async {
      src = _Src({'lnr:one': [_hit('lnr:one', a), _hit('lnr:one', b)]});
      final m = both();
      await m.resolve(novel, title: a);
      src.searched.clear();

      await m.resolve(const ZCanonical(ZKind.novel, 'mal:10'), title: b);

      expect(src.searched, ['lnr:one']);
    });
  });

  group('the row names what actually serves the chapters', () {
    test('a reading title reads as its source, not "Auto Resolve"', () async {
      // sourceForTitle is what the Detail row shows, what the Cloudflare
      // shield acts on, and what "Wrong title?" compares against. Leaving the
      // remembered source out of it labelled every manga "Auto Resolve" while
      // a fixed source quietly served it.
      src = _Src({'mihon:asura': [_hit('mihon:asura', a)]});
      final m = build();
      expect(m.sourceForTitle(one), isNull, reason: 'nothing chosen yet');

      await m.resolve(one, title: a);

      expect(m.sourceForTitle(two), 'mihon:asura');
    });

    test('video still reads as Auto Resolve', () async {
      src = _Src({'mihon:asura': [_hit('mihon:asura', a)]});
      final m = build();
      await m.resolve(anime, title: a);

      expect(m.sourceForTitle(anime), isNull);
    });

    test('video ignores the memory even if something writes it', () async {
      // Only reading writes this today, so the read-side guard is unreachable
      // by normal use. Both sides still have to agree: the day video starts
      // remembering a source, that must be a deliberate change with its own
      // decision about the label, not one that happens silently here.
      src = _Src({'mihon:asura': [_hit('mihon:asura', a)]});
      await prefs.rememberLastGood(ZKind.anime, 'mihon:asura');

      expect(build().sourceForTitle(anime), isNull);
    });

    test('a remembered source that is gone falls back to Auto Resolve', () {
      // Uninstalled, or switched off in source priority. Naming it would point
      // the row — and its Cloudflare solve — at a source that cannot answer.
      final m = SourceMatcher(
        sources: src = _Src({}),
        store: store,
        prefs: prefs,
        candidates: (_) => all,
        sweepCandidates: (_) => const [],
      );
      prefs.rememberLastGood(ZKind.manga, 'mihon:gone');

      expect(m.sourceForTitle(one), isNull);
    });
  });

  test('picking Auto Resolve makes it sweep again', () async {
    src = _Src({'mihon:asura': [_hit('mihon:asura', a)]});
    final m = build();
    await m.resolve(one, title: a);
    expect(prefs.lastGood(ZKind.manga), 'mihon:asura');

    await m.clearAuto(one);

    expect(prefs.lastGood(ZKind.manga), isNull);
  });

  group('a Cloudflare wall only for the source reading actually uses', () {
    // It used to fire on ANY flagged source of the kind. With reading down to
    // one source that meant a manga simply absent from your source threw a
    // Cloudflare wall over the whole page, naming an extension you have never
    // opened. Video never did this — it keeps the page and raises Cloudflare
    // at playback, where you actually tapped.
    tearDown(() {
      CfSolveNeeded.clear('blocked.test');
    });

    test('a flag on some OTHER source is not this title\'s problem', () {
      CfSolveNeeded.needsSolve(
        'blocked.test',
        'https://blocked.test/x',
        sourceId: 'mihon:dex',
      );

      expect(CfSolveNeeded.urlFor('mihon:asura'), isNull);
      // The old behaviour, kept here so the difference is visible: ANY
      // flagged candidate answered, which is what put the wall up.
      expect(
        CfSolveNeeded.urlForAny(['mihon:asura', 'mihon:dex']),
        'https://blocked.test/x',
      );
    });

    test('a flag on the reading source itself still surfaces', () {
      CfSolveNeeded.needsSolve(
        'blocked.test',
        'https://blocked.test/x',
        sourceId: 'mihon:asura',
      );

      expect(CfSolveNeeded.urlFor('mihon:asura'), 'https://blocked.test/x');
    });
  });

  test('video still sweeps every time — it can recover per episode', () async {
    src = _Src({'mihon:asura': [_hit('mihon:asura', a)]});
    await build().resolve(anime, title: a);

    expect(prefs.lastGood(ZKind.anime), isNull);
    expect(src.searched, ['mihon:dex', 'mihon:asura']);
  });
}
