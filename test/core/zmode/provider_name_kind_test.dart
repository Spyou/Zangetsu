// The provider label follows the TITLE, not the mode you happen to be in.
// Opening an anime from a tracker while browsing movies labelled it Simkl —
// a provider that never saw that title.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  late Directory dir;
  late MetadataProviderPrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('provname');
    Hive.init(dir.path);
    prefs = await MetadataProviderPrefs.open();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  // The mapping under test, mirrored: anime/manga/novel answer from the anime
  // provider, movie/tv from the video one — whatever the browse mode is.
  String nameForKind(ZKind kind) {
    final isVideo = kind == ZKind.movie || kind == ZKind.tv;
    if (isVideo) {
      return prefs.video == VideoProvider.simkl ? 'Simkl' : 'TMDB';
    }
    return prefs.anime == AnimeProvider.mal ? 'MyAnimeList' : 'AniList';
  }

  test('an anime title never names a video provider', () async {
    await prefs.setVideo(VideoProvider.simkl);

    // Browsing movies does not make this anime a Simkl title.
    expect(nameForKind(ZKind.anime), 'AniList');
    expect(nameForKind(ZKind.manga), 'AniList');
    expect(nameForKind(ZKind.novel), 'AniList');
  });

  test('a movie title names the video provider', () async {
    await prefs.setVideo(VideoProvider.simkl);

    expect(nameForKind(ZKind.movie), 'Simkl');
    expect(nameForKind(ZKind.tv), 'Simkl');
  });

  test('it follows the chosen provider, not a fixed name', () async {
    await prefs.setAnime(AnimeProvider.mal);
    expect(nameForKind(ZKind.anime), 'MyAnimeList');

    await prefs.setAnime(AnimeProvider.anilist);
    expect(nameForKind(ZKind.anime), 'AniList');
  });

  test('a url carries the kind the label needs', () {
    // This is how Detail knows which to ask for.
    expect(ZmodeIds.parseShow('zm://anime/mal:1735')?.kind, ZKind.anime);
    expect(ZmodeIds.parseShow('zm://tv/tmdb:9')?.kind, ZKind.tv);
    expect(ZmodeIds.parseShow('zm://manga/mal:11')?.kind, ZKind.manga);
  });
}
