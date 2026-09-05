import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_toast.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';
import 'cubit/home_cubit.dart';
import 'search_screen.dart';

/// A cover to stand behind a genre tile.
typedef GenreArt = ({String url, Map<String, String>? headers});

/// One cover per genre, picked out of rows that are already on screen.
///
/// Every catalogue that can filter also returns `genres` on its media, so a
/// representative image costs nothing — no request per tile, and no hand-kept
/// table of genre artwork to rot. Two rules make it look deliberate rather
/// than arbitrary:
///
/// * first match wins, so the order Home loaded its rows in decides, and the
///   grid does not reshuffle between visits;
/// * an image is used once. One popular cover carries five or six genres, and
///   without this the same poster sits under half the grid.
///
/// Genres nothing on screen happens to carry are simply absent, and their
/// tile falls back to its own tint.
Map<String, GenreArt> genreArtFrom(List<HomeSection> sections) {
  final out = <String, GenreArt>{};
  final used = <String>{};
  for (final s in sections) {
    for (final MediaItem m in s.items) {
      final url = m.cover;
      if (url == null || url.isEmpty || m.genres.isEmpty) continue;
      for (final g in m.genres) {
        if (out.containsKey(g)) continue;
        if (!used.add(url)) break; // this artwork is already spoken for
        out[g] = (url: url, headers: m.coverHeaders);
        break;
      }
    }
  }
  return out;
}

/// The Search filters a genre tile opens with.
///
/// [kAdultGenre] only exists behind `isAdult:false`, so opening it without
/// [MetaFilters.adult] returns an empty grid every time. Every other genre
/// keeps Search's own default, where 18+ stays a toggle the user reaches for
/// rather than something a tap turns on behind their back.
MetaFilters genreFilters(String genre) =>
    MetaFilters(genres: [genre], adult: genre == kAdultGenre);

/// A stable colour for [genre] when there is no cover to show.
///
/// Hashed from the name rather than random, so a genre keeps the same tile
/// between visits and the grid does not reshuffle its palette every build.
/// The adult tile is pinned instead: the hash lands it on hue 323, a hot pink
/// that shouts across the grid — a cool blue lets it sit among the rest
/// rather than advertising itself.
Color genreTint(String genre) {
  if (genre == kAdultGenre) {
    return HSLColor.fromAHSL(1, 212, 0.42, 0.32).toColor();
  }
  var h = 0;
  for (final c in genre.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.42, 0.32).toColor();
}

/// Every genre the current catalogue can filter by, as a way in to Search.
///
/// The genre list is the mode's, not the provider's: [metaGenresFor] already
/// keeps one list for anime/manga/novel and TMDB's own for movie/TV, so this
/// screen never has to know which provider is answering — only that it CAN
/// filter, which Home checks before offering the card at all.
class GenresScreen extends StatefulWidget {
  const GenresScreen({super.key});

  @override
  State<GenresScreen> createState() => _GenresScreenState();
}

class _GenresScreenState extends State<GenresScreen> {
  /// Cover for the adult tile, which cannot come from Home.
  ///
  /// Home never asks for adult titles, so nothing on screen carries that
  /// genre and [genreArtFrom] can never fill it — it was the one permanently
  /// blank tile in the grid. This is the only request the screen makes, it
  /// only runs when the tile is actually shown, and a failure just leaves the
  /// tint behind.
  GenreArt? _adultArt;

  /// One cover per genre, from rows Home has ALREADY loaded.
  ///
  /// Nothing is registered in some shells and Home may not have loaded yet,
  /// and neither is worth failing over — the tiles fall back to their tint.
  static Map<String, GenreArt> _artByGenre() {
    if (!sl.isRegistered<HomeCubit>()) return const {};
    return genreArtFrom(sl<HomeCubit>().state.sections ?? const []);
  }

  bool get _adultAllowed =>
      sl.isRegistered<PlaybackPrefs>() && sl<PlaybackPrefs>().adultMetadata;

  @override
  void initState() {
    super.initState();
    if (_adultAllowed) unawaited(_loadAdultArt());
  }

  Future<void> _loadAdultArt() async {
    final kind = browseKindFor(
      sl<ContentModeCubit>().state,
      ZModePrefs.streamKind,
    );
    if (kind == ZKind.movie || kind == ZKind.tv) return; // no such genre there
    if (!sl.isRegistered<MetadataRepository>()) return;
    final repo = sl<MetadataRepository>();
    if (!repo.supportsFilters) return;
    try {
      final res = await repo.searchFiltered(
        '',
        filters: genreFilters(kAdultGenre),
      );
      final withCover = res.where((m) => m.cover?.isNotEmpty ?? false);
      if (withCover.isEmpty || !mounted) return;
      final hit = withCover.first;
      setState(() => _adultArt = (url: hit.cover!, headers: hit.coverHeaders));
    } catch (_) {
      // A blank tile is a fine outcome; the grid must not fail over artwork.
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = browseKindFor(
      sl<ContentModeCubit>().state,
      ZModePrefs.streamKind,
    );
    // Settings → Privacy. Read here only to decide whether the adult tile is
    // OFFERED; the repository re-checks the same switch on every request, so
    // this cannot leak results on its own.
    final genres = metaGenresFor(kind, adult: _adultAllowed);
    final art = {..._artByGenre(), kAdultGenre: ?_adultArt};
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.genres, style: AppText.barTitle),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        itemCount: genres.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          // Wide and short: a genre is one or two words, and taller tiles just
          // push the back half of the list below the fold. "Mahou Shoujo" is
          // the longest label and still sits on one line at this height.
          childAspectRatio: 2.9,
        ),
        itemBuilder: (_, i) {
          final g = genres[i];
          return _GenreTile(genre: g, kind: kind, art: art[g]);
        },
      ),
    );
  }
}

class _GenreTile extends StatelessWidget {
  const _GenreTile({required this.genre, required this.kind, this.art});

  final String genre;
  final ZKind kind;
  final GenreArt? art;

  /// Open Search on this genre.
  ///
  /// Home only shows the Genres card when the catalogue can filter, but the
  /// provider can be switched in Settings while this screen is open — so the
  /// same guard the detail page's genre chips use is repeated here rather than
  /// trusting the state Home saw. MAL answers a `genres` parameter with the
  /// same unfiltered list and Simkl ignores its own `genre`, so without this
  /// the tap would look like it worked and quietly show the wrong titles.
  void _open(BuildContext context) {
    if (!sl<MetadataRepository>().supportsFilters) {
      final needed = (kind == ZKind.movie || kind == ZKind.tv)
          ? 'TMDB'
          : 'AniList';
      showAppToast(context, context.l10n.filtersNeedProvider(needed));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialFilters: genreFilters(genre)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = art;
    return ClipRRect(
      key: ValueKey('genre_$genre'),
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (a != null)
            CachedNetworkImage(
              imageUrl: a.url,
              httpHeaders: a.headers,
              fit: BoxFit.cover,
              // The tint is the placeholder AND the error state: a tile that
              // failed to load should still read as this genre, not as a hole.
              placeholder: (_, _) => ColoredBox(color: genreTint(genre)),
              errorWidget: (_, _, _) => ColoredBox(color: genreTint(genre)),
            )
          else
            ColoredBox(color: genreTint(genre)),
          // Centred text needs the middle darkened, not one edge: a
          // left-weighted scrim left the label sitting on whatever the poster
          // happened to have there. Darkest in the centre, lifting at the
          // corners so the artwork still reads as artwork.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.9,
                colors: [
                  Colors.black.withValues(alpha: 0.72),
                  Colors.black.withValues(alpha: 0.46),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: Text(
                genre,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: 0.2,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
                ),
              ),
            ),
          ),
          // Above the artwork so the whole tile is the target, and so the
          // ripple is not clipped away by the image.
          Material(
            color: Colors.transparent,
            child: InkWell(onTap: () => _open(context)),
          ),
        ],
      ),
    );
  }
}
