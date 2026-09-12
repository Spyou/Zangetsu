// Auto Resolve was searching every installed source, including languages the
// user had turned off. With the usual multi-language Mihon extensions that is
// 123 sources at up to 3s each, sequentially, with the chapter list on a
// skeleton the whole time.
//
// The pin lookup is the opposite case and must keep seeing everything: a
// source chosen by hand has to stay findable even if its language is off.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_module.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

class _Src implements SourceRepository {
  _Src(this.bySource);
  final Map<String, List<MediaItem>> bySource;
  final searched = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
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

MediaItem _hit(String src) => MediaItem(
  id: '$src-id',
  title: 'Solo Leveling',
  url: 'https://$src/x',
  type: ProviderType.manga,
  sourceId: src,
);

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late _Src src;

  const manga = ZCanonical(ZKind.manga, 'mal:99');
  const title = 'Solo Leveling';

  // The enabled one sits LAST on purpose: a sweep of the full list would
  // search the other two first, which is exactly what the narrowing prevents.
  // With it first, both behaviours stop after one search and the test proves
  // nothing.
  const every = [
    (id: 'mihon:ko', name: 'KO source'),
    (id: 'mihon:ja', name: 'JA source'),
    (id: 'mihon:en', name: 'EN source'),
  ];
  // What the language preference leaves visible.
  const enabled = [(id: 'mihon:en', name: 'EN source')];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sweep_lang');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    src = _Src({for (final s in every) s.id: [_hit(s.id)]});
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  SourceMatcher build() => SourceMatcher(
    sources: src,
    store: store,
    prefs: prefs,
    candidates: (_) => every,
    sweepCandidates: (_) => enabled,
  );

  test('a sweep only searches the languages that are on', () async {
    await build().resolve(manga, title: title);

    expect(src.searched, ['mihon:en']);
  });

  test('a pin on a switched-off language still resolves', () async {
    // The user chose this one by hand. Hiding it would silently move them to
    // a different source without saying so.
    final m = build();
    await m.pinTitleToSource(manga, 'mihon:ko', title: title);

    expect((await m.resolve(manga, title: title))?.sourceId, 'mihon:ko');
  });

  test('a kind default outside the enabled languages is still honoured',
      () async {
    await prefs.set(ZKind.manga, 'mihon:ja');

    expect(
      (await build().resolve(manga, title: title))?.sourceId,
      'mihon:ja',
      reason: 'an explicit default is a choice, not a sweep',
    );
  });

  test('with no sweep list given, it sweeps the full one', () async {
    // Back-compat: every existing caller passes only `candidates`.
    final m = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => every,
    );
    await m.resolve(manga, title: title);

    expect(src.searched, ['mihon:ko']);
  });

  group('narrowing the list', () {
    List<({String id, String name})> narrow(
      List<({String id, String name})> ordered,
      List<String> allowedIds,
    ) => languageNarrowedCandidates(ordered, allowedIds.toSet());

    test('keeps the enabled ones, in the order given', () {
      expect(
        narrow(every, ['mihon:ja', 'mihon:en']).map((s) => s.id),
        ['mihon:ja', 'mihon:en'],
      );
    });

    test('falls back to everything when the filter empties it', () {
      // A language preference that happens to exclude every installed source
      // would otherwise turn "slow" into "nothing ever resolves".
      expect(narrow(every, []).map((s) => s.id), every.map((s) => s.id));
    });
  });
}
