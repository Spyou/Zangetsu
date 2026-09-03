import '../../features/home/cubit/home_rows_composer.dart';
import 'anilist_catalogue.dart';
import 'mal_catalogue.dart';
import 'simkl_catalogue.dart';
import 'tmdb_catalogue.dart';
import 'zmode_ids.dart';

/// One way Home can be composed: a metadata provider paired with a browse
/// kind. Each has its own saved row arrangement, because each has its own
/// Discover rows — the row ids are the catalogue's own titles, so an
/// arrangement saved against AniList's rows means nothing to TMDB's.
///
/// [sectionTitles] comes from the catalogue's static row list rather than a
/// fetch: the editor has to describe layouts the app isn't currently in, and
/// asking four catalogues for their home just to read back titles they
/// already declare would be four round trips for nothing.
class HomeLayout {
  const HomeLayout({
    required this.key,
    required this.provider,
    required this.kind,
    required this.sectionTitles,
  });

  /// The [HomeRowsPrefs] key — the same string `layoutKeyFor` builds.
  final String key;

  /// Display name of the catalogue behind it ("AniList", "Simkl").
  final String provider;

  final ZKind kind;

  /// Titles of this catalogue's Discover rows, in catalogue order. Every
  /// metadata section is tagged `zm`, so the phone keeps all of them as rows
  /// (`providerRowSections`) — no first-section drop to mirror here.
  final List<String> sectionTitles;

  /// The row ids those titles persist as.
  List<String> get sectionIds => [for (final t in sectionTitles) 'section:$t'];
}

/// Every arrangement the app can hold, in picker order.
///
/// Anime, manga and novel come from AniList or MyAnimeList; movies and series
/// from TMDB or Simkl. Only one side of each pair is live at a time (the
/// metadata provider setting decides), but all of them are listed: arranging
/// the one you are about to switch to shouldn't require switching first.
List<HomeLayout> allHomeLayouts() => [
  for (final kind in const [ZKind.anime, ZKind.manga, ZKind.novel]) ...[
    HomeLayout(
      key: layoutKeyFor(sourceId: '', zModeOn: true, browseKind: kind),
      provider: 'AniList',
      kind: kind,
      sectionTitles: AniListCatalogue.rowTitles(kind),
    ),
    HomeLayout(
      key: layoutKeyFor(
        sourceId: '',
        zModeOn: true,
        browseKind: kind,
        malPreferred: true,
      ),
      provider: 'MyAnimeList',
      kind: kind,
      sectionTitles: MalCatalogue.rowTitles(kind),
    ),
  ],
  HomeLayout(
    key: layoutKeyFor(sourceId: '', zModeOn: true, browseKind: ZKind.movie),
    provider: 'TMDB',
    kind: ZKind.movie,
    sectionTitles: TmdbCatalogue.rowTitles(),
  ),
  HomeLayout(
    key: layoutKeyFor(
      sourceId: '',
      zModeOn: true,
      browseKind: ZKind.movie,
      simklPreferred: true,
    ),
    provider: 'Simkl',
    kind: ZKind.movie,
    sectionTitles: SimklCatalogue.rowTitles(),
  ),
];

/// The layout stored under [key], or null when it isn't one of the metadata
/// layouts (a source-backed home, which has no fixed row list).
HomeLayout? homeLayoutFor(String key) {
  for (final l in allHomeLayouts()) {
    if (l.key == key) return l;
  }
  return null;
}

/// The tracker that feeds [layoutKey]'s list rows, by display name, or null to
/// let hub order decide.
///
/// A layout's provider IS its tracker: "AniList · Anime" means AniList's
/// browse rows AND AniList's lists, one choice rather than two controls that
/// both named accounts. TMDB is a catalogue with no account behind it, so its
/// name matches no tracker and the pick falls through to whichever one can
/// answer — as it does for any provider you aren't signed into.
String? layoutTrackerName(String layoutKey) => homeLayoutFor(layoutKey)?.provider;
