// Which repository the checker asks. A Z Mode subscription is stored with
// sourceId `zm` and a `zm://` url; asking SourceRepository directly threw
// "Provider not loaded: zm" for every one of them, and the per-show catch
// swallowed it — so the bell stored state and was never checked again.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/notify/subscription_checker.dart';
import 'package:watch_app/core/notify/subscription_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

/// Stands in for the router: records what it was asked, and refuses ids the
/// source registry would also refuse.
class _Router implements CatalogueRepository {
  _Router(this.counts);
  final Map<String, int> counts;
  final asked = <String>[];

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    asked.add('$sourceId|$url');
    final n = counts['$sourceId|$url'];
    // The old wiring threw exactly here for `zm`.
    if (n == null) throw StateError('Provider not loaded: $sourceId');
    return [
      for (var i = 0; i < n; i++)
        Episode(id: '$i', number: i + 1, title: 'Ep $i', url: '$url/ep/$i'),
    ];
  }

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async => const [];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Subscription _sub(String sourceId, String url, {int lastCount = 1}) => Subscription(
  sourceId: sourceId,
  url: url,
  title: 'A Show',
  lastCount: lastCount,
  mode: ContentMode.anime,
);

void main() {
  late Directory dir;
  late SubscriptionStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('subcheck');
    Hive.init(dir.path);
    await SubscriptionStore.init();
    store = SubscriptionStore();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a Z Mode subscription is actually checked', () async {
    const url = 'zm://anime/mal:1735';
    await store.add(_sub(ZmodeIds.sourceId, url));
    final repo = _Router({'${ZmodeIds.sourceId}|$url': 3});

    await SubscriptionChecker(repo, store).checkAll();

    expect(repo.asked, ['${ZmodeIds.sourceId}|$url'],
        reason: 'this is the call that used to throw and be swallowed');
    // The new count was recorded, which only happens on a successful check.
    expect(store.all().single.lastCount, 3);
  });

  test('a source subscription still works exactly as before', () async {
    const url = 'https://example.test/show/1';
    await store.add(_sub('ani:1', url));
    final repo = _Router({'ani:1|$url': 5});

    await SubscriptionChecker(repo, store).checkAll();

    expect(store.all().single.lastCount, 5);
  });

  test('CloudStream is still left to the native worker', () async {
    const url = 'https://example.test/cs/1';
    await store.add(_sub('cs:Some', url));
    final repo = _Router({'cs:Some|$url': 9});

    await SubscriptionChecker(repo, store).checkAll();

    expect(repo.asked, isEmpty, reason: 'double alerts otherwise');
    expect(store.all().single.lastCount, 1);
  });

  test('one dead source does not stop the rest of the sweep', () async {
    await store.add(_sub('ani:dead', 'https://dead.test/1'));
    await store.add(_sub('ani:ok', 'https://ok.test/1'));
    final repo = _Router({'ani:ok|https://ok.test/1': 4});

    await SubscriptionChecker(repo, store).checkAll();

    final ok = store.all().firstWhere((s) => s.sourceId == 'ani:ok');
    expect(ok.lastCount, 4);
  });

  test('a count that has not grown records nothing', () async {
    const url = 'zm://manga/mal:11';
    await store.add(_sub(ZmodeIds.sourceId, url, lastCount: 7));
    final repo = _Router({'${ZmodeIds.sourceId}|$url': 7});

    await SubscriptionChecker(repo, store).checkAll();

    expect(store.all().single.lastCount, 7);
  });
}
