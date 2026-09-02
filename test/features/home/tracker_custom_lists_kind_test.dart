// AniList keeps SEPARATE custom lists for anime and for manga. The names were
// always fetched with the default kind (anime), so a list made on the anime
// side showed up under Manga and Novel, and a manga list never showed at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/features/home/cubit/tracker_list_cubit.dart';

class _FakeAniList implements AniListService {
  final asked = <MediaKind>[];

  @override
  Future<List<String>> customListNames({MediaKind kind = MediaKind.anime}) async {
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

void main() {
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
