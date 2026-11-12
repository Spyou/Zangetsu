// AniList keeps SEPARATE custom lists for anime and for manga. The names were
// always fetched with the default kind (anime), so a list made on the anime
// side showed up under Manga and Novel, and a manga list never showed at all.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/features/home/cubit/tracker_list_cubit.dart';

class _FakeAniList implements AniListService {
  final asked = <MediaKind>[];
  int fetches = 0;

  @override
  Future<List<TrackerListItem>> fetchList() async {
    fetches++;
    return const [];
  }

  @override
  Future<List<String>> customListNames({
    MediaKind kind = MediaKind.anime,
  }) async {
    asked.add(kind);
    return kind == MediaKind.manga ? ['Manga Shelf'] : ['Anime Shelf'];
  }

  @override
  bool get isConnected => true;

  @override
  String get displayName => 'AniList';

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _DelayedAniList extends _FakeAniList {
  final anime = Completer<List<String>>();
  final manga = Completer<List<String>>();
  @override
  Future<List<String>> customListNames({MediaKind kind = MediaKind.anime}) =>
      kind == MediaKind.manga ? manga.future : anime.future;
}

void main() {
  test(
    'local category changes read the matching lists without refetching entries',
    () async {
      final tracker = _FakeAniList();
      final cubit = TrackerListCubit();
      addTearDown(cubit.close);
      cubit.selectTracker(tracker, kind: ContentMode.anime);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.customListNames, ['Anime Shelf']);
      cubit.selectKind(ContentMode.manga);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.customListNames, ['Manga Shelf']);
      cubit.selectKind(ContentMode.novel);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.customListNames, ['Manga Shelf']);
      cubit.selectKind(ContentMode.anime);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.customListNames, ['Anime Shelf']);
      expect(tracker.asked, [MediaKind.anime, MediaKind.manga]);
      expect(tracker.fetches, 1);
    },
  );

  test(
    'a late anime response cannot replace the selected manga lists',
    () async {
      final tracker = _DelayedAniList();
      final cubit = TrackerListCubit();
      addTearDown(cubit.close);
      cubit.selectTracker(tracker, kind: ContentMode.anime);
      await Future<void>.delayed(Duration.zero);
      cubit.selectKind(ContentMode.manga);
      tracker.manga.complete(['Manga Shelf']);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.customListNames, ['Manga Shelf']);
      tracker.anime.complete(['Anime Shelf']);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.customListNames, ['Manga Shelf']);
    },
  );

  test('a manga screen asks AniList for its manga lists', () async {
    final tracker = _FakeAniList();
    final cubit = TrackerListCubit(pinnedKind: ContentMode.manga);

    await cubit.loadCustomListNamesForTest(tracker);

    expect(tracker.asked, [MediaKind.manga]);
    await cubit.close();
  });

  test('a novel screen reads the manga side too', () async {
    // AniList has no novel lists; novels live under manga there.
    final tracker = _FakeAniList();
    final cubit = TrackerListCubit(pinnedKind: ContentMode.novel);

    await cubit.loadCustomListNamesForTest(tracker);

    expect(tracker.asked, [MediaKind.manga]);
    await cubit.close();
  });

  test('a streaming screen asks for anime lists', () async {
    final tracker = _FakeAniList();
    final cubit = TrackerListCubit(pinnedKind: ContentMode.anime);

    await cubit.loadCustomListNamesForTest(tracker);

    expect(tracker.asked, [MediaKind.anime]);
    await cubit.close();
  });

  test('the cache does not serve one kind to the other', () async {
    // One cache per tracker handed the anime names straight back after a
    // switch to manga, which is what made the wrong tabs so sticky.
    final tracker = _FakeAniList();
    final anime = TrackerListCubit(pinnedKind: ContentMode.anime);
    await anime.loadCustomListNamesForTest(tracker);

    final manga = TrackerListCubit(pinnedKind: ContentMode.manga);
    await manga.loadCustomListNamesForTest(tracker);

    // The second cubit must still ASK, rather than be handed the anime names
    // a per-tracker cache would have kept.
    expect(tracker.asked, [MediaKind.anime, MediaKind.manga]);
    await anime.close();
    await manga.close();
  });
}
