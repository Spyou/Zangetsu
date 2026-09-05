import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/zmode/anilist_catalogue.dart';
import '../../core/zmode/genre_catalog.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';
import 'cubit/home_cubit.dart';
import 'genres_screen.dart';
import '../../core/models/media_item.dart';
import '../detail/detail_screen.dart';
import 'see_all_screen.dart';

/// The genre grid, D-pad shaped.
///
/// Shares every decision with the phone screen — [GenreCatalog] for the list,
/// [genreArtFrom] for the artwork, [genreFilters] for what a tap searches —
/// so the two cannot drift on the things that matter. Only the chrome differs:
/// focusable tiles, a wider grid, and no [Navigator] chrome, because this is a
/// rail destination rather than a pushed page.
class GenresScreenTv extends StatefulWidget {
  const GenresScreenTv({super.key});

  @override
  State<GenresScreenTv> createState() => _GenresScreenTvState();
}

class _GenresScreenTvState extends State<GenresScreenTv> {
  GenreArt? _adultArt;

  /// The genre whose first page is in flight, so its tile can say so.
  String? _opening;

  bool get _adultAllowed =>
      sl.isRegistered<PlaybackPrefs>() && sl<PlaybackPrefs>().adultMetadata;

  bool get _canFilter =>
      sl.isRegistered<MetadataRepository>() &&
      sl<MetadataRepository>().supportsFilters;

  ZKind get _kind =>
      browseKindFor(sl<ContentModeCubit>().state, ZModePrefs.streamKind);

  @override
  void initState() {
    super.initState();
    unawaited(_refreshGenres());
    if (_adultAllowed) unawaited(_loadAdultArt());
  }

  Future<void> _refreshGenres() async {
    if (!GenreCatalog.isStale || !sl.isRegistered<Dio>()) return;
    final fetched = await AniListCatalogue(
      AniListCatalogue.dioGql(sl<Dio>()),
    ).genreCollection();
    if (fetched.isEmpty || !mounted) return;
    await GenreCatalog.save(fetched);
    if (mounted) setState(() {});
  }

  Future<void> _loadAdultArt() async {
    final kind = _kind;
    if (kind == ZKind.movie || kind == ZKind.tv) return;
    if (!_canFilter) return;
    try {
      final res = await sl<MetadataRepository>().searchFiltered(
        '',
        filters: genreFilters(kAdultGenre),
      );
      final withCover = res.where((m) => m.cover?.isNotEmpty ?? false);
      if (withCover.isEmpty || !mounted) return;
      final hit = withCover.first;
      setState(() => _adultArt = (url: hit.cover!, headers: hit.coverHeaders));
    } catch (_) {
      // Decoration only — never fail the screen over it.
    }
  }

  Map<String, GenreArt> get _art => {
    if (sl.isRegistered<HomeCubit>())
      ...genreArtFrom(sl<HomeCubit>().state.sections ?? const []),
    kAdultGenre: ?_adultArt,
  };

  /// Open a paginated grid of everything in [genre].
  ///
  /// TV search takes no metadata filters, so routing a genre through it would
  /// silently drop the filter. [SeeAllScreen] already picks the TV grid when
  /// on TV and paginates through [SeeAllScreen.onLoadMore], which is exactly
  /// the shape `searchFiltered` answers in.
  Future<void> _open(String genre) async {
    final filters = genreFilters(genre);
    final repo = sl<MetadataRepository>();
    setState(() => _opening = genre);
    List<MediaItem> first;
    try {
      first = await repo.searchFiltered('', filters: filters);
    } catch (_) {
      first = const [];
    }
    if (!mounted) return;
    setState(() => _opening = null);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SeeAllScreen(
          title: genre,
          items: first,
          onTap: (m) => Navigator.push(context, DetailScreen.route(m)),
          onLoadMore: (page) =>
              repo.searchFiltered('', filters: filters, page: page),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    final genres = GenreCatalog.genresFor(kind, adult: _adultAllowed);
    final art = _art;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 24, 40, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.genres, style: AppText.headline),
              const SizedBox(height: 18),
              // Said plainly rather than left as a grid of tiles that all
              // refuse: MAL and Simkl answer a genre parameter with the same
              // unfiltered list, so there is nothing honest to show here.
              if (!_canFilter)
                Expanded(
                  child: Center(
                    child: Text(
                      context.l10n.filtersNeedProvider(
                        (kind == ZKind.movie || kind == ZKind.tv)
                            ? 'TMDB'
                            : 'AniList',
                      ),
                      textAlign: TextAlign.center,
                      style: AppText.body.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: GridView.builder(
                    itemCount: genres.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          // Wider than the phone's two: a TV is a long way
                          // away, and four across still leaves the label
                          // readable at this height.
                          crossAxisCount: 4,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 2.6,
                        ),
                    itemBuilder: (_, i) => _TvGenreTile(
                      genre: genres[i],
                      art: art[genres[i]],
                      autofocus: i == 0,
                      busy: _opening == genres[i],
                      onTap: _opening != null ? null : () => _open(genres[i]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvGenreTile extends StatelessWidget {
  const _TvGenreTile({
    required this.genre,
    required this.onTap,
    this.art,
    this.autofocus = false,
    this.busy = false,
  });

  final String genre;
  final GenreArt? art;
  final bool autofocus;

  /// This genre's first page is being fetched. Null [onTap] while any tile is
  /// busy, so a second Enter cannot stack two grids.
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final a = art;
    return TvFocusable(
      autofocus: autofocus,
      semanticLabel: genre,
      onTap: onTap ?? () {},
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (a != null)
              CachedNetworkImage(
                imageUrl: a.url,
                httpHeaders: a.headers,
                fit: BoxFit.cover,
                placeholder: (_, _) => ColoredBox(color: AppColors.surface2),
                errorWidget: (_, _, _) => ColoredBox(color: genreTint(genre)),
              )
            else
              ColoredBox(color: genreTint(genre)),
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
            if (busy)
              const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text(
                    genre,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      shadows: const [
                        Shadow(color: Colors.black, blurRadius: 8),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
