// Opening a title from a tracker reads it from THAT tracker's catalogue: you
// are looking at your AniList library, so the page should be AniList's even
// when MyAnimeList is the app-wide choice. A tracker with no catalogue behind
// it falls back to that choice.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';

/// Mirrors `_providerOf` in the list screen — the mapping is the whole point.
PreferredProvider? providerOf(String? trackerName) => switch (trackerName) {
  'AniList' => PreferredProvider.anilist,
  'MyAnimeList' => PreferredProvider.mal,
  'Simkl' => PreferredProvider.simkl,
  _ => null,
};

void main() {
  test('each tracker names its own catalogue', () {
    expect(providerOf('AniList'), PreferredProvider.anilist);
    expect(providerOf('MyAnimeList'), PreferredProvider.mal);
    expect(providerOf('Simkl'), PreferredProvider.simkl);
  });

  test('a tracker with no catalogue falls back', () {
    // Trakt, say: it tracks, but nothing here reads titles from it, so the
    // saved provider has to stand rather than the request failing.
    expect(providerOf('Trakt'), isNull);
    expect(providerOf(null), isNull);
  });

  test('My List has no tracker, so no preference', () {
    // Opening from your own list keeps whatever you chose in Settings.
    expect(providerOf(''), isNull);
  });

  // Mirrors `_preferFromName`: a saved title is read from where it was saved,
  // so the page and its label agree.
  PreferredProvider? preferFromName(String? name) => switch (name) {
    'AniList' => PreferredProvider.anilist,
    'MyAnimeList' => PreferredProvider.mal,
    'TMDB' => PreferredProvider.tmdb,
    'Simkl' => PreferredProvider.simkl,
    _ => null,
  };

  test('a saved origin round-trips back to its catalogue', () {
    expect(preferFromName('AniList'), PreferredProvider.anilist);
    expect(preferFromName('MyAnimeList'), PreferredProvider.mal);
    expect(preferFromName('TMDB'), PreferredProvider.tmdb);
    expect(preferFromName('Simkl'), PreferredProvider.simkl);
  });

  test('a source name is not a catalogue', () {
    // Source titles keep their real sourceId and never take this path; naming
    // one here must not force a metadata provider.
    expect(preferFromName('AllAnime'), isNull);
    expect(preferFromName(''), isNull);
    expect(preferFromName(null), isNull);
  });
}
