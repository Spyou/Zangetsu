import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

/// A source that answers a QUERY, not a source id — which is the whole point
/// here. The shared `_FakeSources` in `source_matcher_test.dart` returns the
/// same list whatever you ask for, so it cannot tell one name from the other.
class _ByQuery implements SourceRepository {
  _ByQuery(this.byQuery);

  /// query → what the source returns for it. Anything not listed returns [].
  final Map<String, List<MediaItem>> byQuery;

  /// Every query asked, in order.
  final asked = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool hasSource(String sourceId) => true;
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  String displayName(String sourceId) => sourceId;
  @override
  List<({String id, String name})> get loadedSources =>
      [(id: 'src', name: 'src')];
  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async {
    asked.add(query);
    return byQuery[query] ?? const [];
  }
}

MediaItem _item(String title) => MediaItem(
  id: title.toLowerCase(),
  title: title,
  url: 'https://src/$title',
  type: ProviderType.anime,
  sourceId: 'src',
);

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  const show = ZCanonical(ZKind.anime, 'mal:63150');
  const romaji = 'Otome Kaijuu Caraméliser';
  const english = 'Kaiju Girl Caramelise';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('alt-title');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  SourceMatcher matcher(_ByQuery repo) => SourceMatcher(
    sources: repo,
    store: store,
    prefs: prefs,
    candidates: (_) => [(id: 'src', name: 'src')],
  );

  // The measured bug: `animecube -> 0 results for "Otome Kaijuu Caraméliser"`
  // on a source that lists the show as "Kaiju Girl Caramelise". One name was
  // asked, so a source that HAD it was recorded as not having it.
  test('a source indexing by the English name is now found', () async {
    final repo = _ByQuery({english: [_item(english)]});
    final r = await matcher(repo).resolveOn(
      show,
      'src',
      title: romaji,
      altTitle: english,
    );
    expect(r?.showTitle, english);
    expect(repo.asked, [romaji, english], reason: 'romaji first, then English');
  });

  // The cost has to land only where the alternative was a guaranteed miss.
  test('a title the first name finds never pays for a second search', () async {
    final repo = _ByQuery({romaji: [_item(romaji)]});
    final r = await matcher(repo).resolveOn(
      show,
      'src',
      title: romaji,
      altTitle: english,
    );
    expect(r?.showTitle, romaji);
    expect(repo.asked, [romaji], reason: 'the second name was never needed');
  });

  // Two round trips for one answer is just a slower miss.
  test('the same name twice is asked once', () async {
    final repo = _ByQuery(const {});
    await matcher(repo).resolveOn(
      show,
      'src',
      title: 'One Piece',
      // Same name, different punctuation and case — normalizeTitle sees
      // through that, and so must this.
      altTitle: 'one piece',
    );
    expect(repo.asked, ['One Piece']);
  });

  test('no alt title means one search, exactly as before', () async {
    final repo = _ByQuery(const {});
    await matcher(repo).resolveOn(show, 'src', title: romaji);
    expect(repo.asked, [romaji]);
  });

  // Finding something under the other name must not mean accepting anything:
  // the acceptance rule is unchanged, so a different show is still rejected.
  test('a wrong show returned for the English name is still rejected',
      () async {
    final repo = _ByQuery({
      english: [_item('Some Entirely Different Show')],
    });
    final r = await matcher(repo).resolveOn(
      show,
      'src',
      title: romaji,
      altTitle: english,
    );
    expect(r, isNull);
    expect(repo.asked, [romaji, english], reason: 'it looked, and said no');
  });
}
