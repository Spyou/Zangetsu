// The sheet lists both settings, and puts the one matching where you are on
// top. The trap is that there is no movies tab: ContentMode.anime is
// "Streaming" and carries anime, movies and series together, so the mode alone
// cannot answer which that is — StreamKind decides between them.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/metadata_switch_sheet.dart';

void main() {
  group('metadataAxisFor', () {
    test('Streaming on anime leads with AniList/MyAnimeList', () {
      expect(
        metadataAxisFor(ContentMode.anime, StreamKind.anime),
        MetadataAxis.anime,
      );
    });

    test('Streaming switched to movies leads with TMDB/Simkl', () {
      expect(
        metadataAxisFor(ContentMode.anime, StreamKind.movie),
        MetadataAxis.video,
      );
    });

    // Reading modes have no movie/TV metadata to switch, so the streaming kind
    // left over from the last video session must not leak into them.
    test('Manga leads with the anime setting whatever the streaming kind is', () {
      expect(
        metadataAxisFor(ContentMode.manga, StreamKind.movie),
        MetadataAxis.anime,
      );
      expect(
        metadataAxisFor(ContentMode.manga, StreamKind.anime),
        MetadataAxis.anime,
      );
    });

    test('so does Novel', () {
      expect(
        metadataAxisFor(ContentMode.novel, StreamKind.movie),
        MetadataAxis.anime,
      );
      expect(
        metadataAxisFor(ContentMode.novel, StreamKind.anime),
        MetadataAxis.anime,
      );
    });
  });

  group('the sheet writes the same setting Settings writes', () {
    test('AnimeProvider and VideoProvider each carry exactly two choices', () {
      // The sheet renders one row per enum value. A third would silently
      // appear in it with no label of its own.
      expect(AnimeProvider.values, [AnimeProvider.anilist, AnimeProvider.mal]);
      expect(VideoProvider.values, [VideoProvider.tmdb, VideoProvider.simkl]);
    });
  });
}
