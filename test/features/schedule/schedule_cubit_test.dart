import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/schedule/airing_service.dart';
import 'package:watch_app/core/schedule/coming_soon_service.dart';
import 'package:watch_app/core/schedule/schedule_models.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/features/schedule/schedule_cubit.dart';

class _FakeAiring implements AiringService {
  _FakeAiring(this._out, {List<AiringEntry>? month}) : _month = month ?? _out;
  final List<AiringEntry> _out;
  final List<AiringEntry> _month;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<List<AiringEntry>> weekAiring({DateTime? now}) async => _out;
  @override
  Future<List<AiringEntry>> monthAiring(DateTime anchor) async => _month;
}

/// Returns empty for the first [emptyFirst] calls, then [_out] — models a
/// transient failure the retry loop should recover from.
class _FlakyAiring implements AiringService {
  _FlakyAiring(this._out, this.emptyFirst);
  final List<AiringEntry> _out;
  int emptyFirst;
  int calls = 0;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<List<AiringEntry>> weekAiring({DateTime? now}) async =>
      calls++ < emptyFirst ? const [] : _out;
}

class _FakeSoon implements ComingSoonService {
  _FakeSoon(this._out);
  final List<ComingSoonEntry> _out;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<List<ComingSoonEntry>> upcoming() async => _out;
}

class _FakeMyList implements MyListStore {
  _FakeMyList(this._items);
  final List<MediaItem> _items;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<MediaItem> all() => _items;
}

AiringEntry _entry(int? mal) => AiringEntry(
    malId: mal, title: 't$mal', coverUrl: null, episode: 1,
    airsAtLocal: DateTime(2026, 7, 10, 12), format: 'TV');

void main() {
  test('load populates airing (grouped) + comingSoon, clears loading', () async {
    final c = ScheduleCubit(
      _FakeAiring([_entry(1), _entry(2)]),
      _FakeSoon([
        const ComingSoonEntry(tmdbId: 9, isTv: false, title: 'm', posterUrl: null, releaseDate: null)
      ]),
      _FakeMyList(const []),
    );
    await c.load();
    expect(c.state.airingAll.length, 2);
    expect(c.state.airingByDay.values.expand((x) => x).length, 2);
    expect(c.state.comingSoon.length, 1);
    expect(c.state.loadingAiring, isFalse);
    expect(c.state.loadingSoon, isFalse);
    expect(c.state.errorAiring, isFalse);
  });

  test('myListByDay narrows to My List malIds while airingByDay keeps all', () async {
    final c = ScheduleCubit(
      _FakeAiring([_entry(1), _entry(2), _entry(3)]),
      _FakeSoon(const []),
      _FakeMyList([
        const MediaItem(id: 'a', title: 'A', url: '/a', type: ProviderType.anime, sourceId: 's', malId: 2),
      ]),
      retryDelays: const [], // empty soon is intentional here — skip retries
    );
    await c.load();
    // My List tab shows only tracked anime…
    final mine = c.state.myListByDay.values.expand((x) => x).toList();
    expect(mine.map((e) => e.malId).toList(), [2]);
    // …while the Anime tab still shows everything.
    expect(c.state.airingByDay.values.expand((x) => x).length, 3);
  });

  test('retries a transient empty airing result, then populates', () async {
    final c = ScheduleCubit(
      _FlakyAiring([_entry(1), _entry(2)], 2), // empty twice, then real
      _FakeSoon([
        const ComingSoonEntry(tmdbId: 9, isTv: false, title: 'm', posterUrl: null, releaseDate: null)
      ]),
      _FakeMyList(const []),
      retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
    );
    await c.load();
    expect(c.state.airingAll.length, 2); // recovered after 2 empty tries
    expect(c.state.errorAiring, isFalse);
  });

  test('setView(month) lazily loads month airing into monthAiringByDay',
      () async {
    final monthEntry = AiringEntry(
        malId: 5, title: 'M', coverUrl: null, episode: 1,
        airsAtLocal: DateTime(2026, 7, 20, 20), format: 'TV');
    final c = ScheduleCubit(
      _FakeAiring([_entry(1)], month: [monthEntry]),
      _FakeSoon([
        const ComingSoonEntry(tmdbId: 9, isTv: false, title: 'm', posterUrl: null, releaseDate: null)
      ]),
      _FakeMyList(const []),
      retryDelays: const [],
    );
    await c.load();
    expect(c.state.monthAiringByDay, isEmpty); // not loaded until month view
    await c.setView(ScheduleView.month);
    expect(c.state.view, ScheduleView.month);
    expect(c.state.monthAiringByDay.values.expand((x) => x).length, 1);
  });

  test('gives up after exhausting retries → errorAiring', () async {
    final c = ScheduleCubit(
      _FakeAiring(const []), // always empty
      _FakeSoon([
        const ComingSoonEntry(tmdbId: 9, isTv: false, title: 'm', posterUrl: null, releaseDate: null)
      ]),
      _FakeMyList(const []),
      retryDelays: const [Duration.zero, Duration.zero],
    );
    await c.load();
    expect(c.state.airingAll, isEmpty);
    expect(c.state.errorAiring, isTrue);
    expect(c.state.loadingAiring, isFalse);
  });
}
