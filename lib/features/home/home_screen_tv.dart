import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/featured_carousel.dart';
import '../../core/ui/featured_hero.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';
import 'see_all_screen.dart';
import 'cubit/home_cubit.dart';

/// TV Home: a full-screen vertically-scrolling layout with the phone's real
/// [FeaturedHero] banner followed by horizontal poster rails (one per section).
/// The hero's action buttons are wrapped in [TvFocusable] for D-pad + OK
/// navigation; the phone render of [FeaturedHero] is byte-identical (the
/// [FeaturedHero.wrapButton] param defaults to null on phone).
class HomeScreenTv extends StatefulWidget {
  const HomeScreenTv({super.key});

  @override
  State<HomeScreenTv> createState() => _HomeScreenTvState();
}

class _HomeScreenTvState extends State<HomeScreenTv> {
  /// Per-item hero metadata cache (genres + episode count). Mirrors the phone's
  /// _metaCache; futures are stored so carousel rotation never re-fetches.
  final Map<String, Future<HeroMeta?>> _metaCache = {};

  // ── Navigation helpers ────────────────────────────────────────────────────

  /// Open the Detail screen — mirrors phone's _HomeViewState._openDetail.
  void _openDetail(MediaItem item) {
    Navigator.push(context, DetailScreen.route(item));
  }

  /// Begin playback from scratch — mirrors phone's _HomeViewState._playFeatured.
  Future<void> _play(MediaItem item) async {
    final category =
        sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          sourceId: item.sourceId,
          episodesResolver: () => sl<SourceRepository>().episodes(
            item.url,
            sourceId: item.sourceId,
          ),
          resume: sl<ResumeStore>(),
          resolveSources: (u) => sl<SourceRepository>().sources(
            u,
            sourceId: item.sourceId,
            fast: true,
          ),
          history: sl<WatchHistory>(),
          showTitle: item.title,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          showUrl: item.url,
          category: category,
          malId: item.malId,
          scrobbleTitle: item.type == ProviderType.anime ? item.title : null,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  // ── Hero helpers ──────────────────────────────────────────────────────────

  /// True if [m] is in the user's My List. Returns false when the store is
  /// unavailable (e.g. test environments where sl is not configured).
  bool _inList(MediaItem m) {
    try {
      return sl<MyListStore>().contains(m);
    } catch (_) {
      return false;
    }
  }

  /// Genres + episode count for the hero banner, lazily fetched and cached.
  /// Mirrors the phone's _HomeViewState._heroMeta.  Swallows any error
  /// (missing sl registration in tests, network failure) and returns null so
  /// the hero meta line gracefully stays empty.
  Future<HeroMeta?> _heroMeta(MediaItem m) =>
      _metaCache.putIfAbsent('${m.sourceId}:${m.id}', () async {
        try {
          final d = await sl<SourceRepository>().detail(
            m.url,
            sourceId: m.sourceId,
          );
          return HeroMeta(
            genres: d.genres,
            episodeCount: d.episodes.length,
            year: d.year,
          );
        } catch (_) {
          return null;
        }
      });

  /// Open the full-grid "See All" view of a browse row. [SeeAllScreen] forwards
  /// to the TV variant when [AppMode.isTv]; a paginable row (Aniyomi
  /// popular/latest, CloudStream mainPage) carries a `more` descriptor that
  /// drives infinite scroll, everything else stays a fixed list.
  void _openSeeAll(HomeSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeeAllScreen(
          title: section.title,
          items: section.items,
          onTap: _openDetail,
          onLoadMore: section.more == null
              ? null
              : (page) =>
                    sl<SourceRepository>().browseMore(section.more!, page),
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Button decorator injected into [FeaturedHero.wrapButton]: wraps each hero
  /// action button with [TvFocusable] so it is D-pad focusable and OK-selectable.
  /// [autofocus] is true only for the primary Play button.
  Widget _tvWrapButton(
    Widget child,
    VoidCallback onTap, {
    bool autofocus = false,
  }) {
    return TvFocusable(autofocus: autofocus, onTap: onTap, child: child);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HomeCubit>().state;
    final sections = state.sections ?? const <HomeSection>[];

    // Use the same heroItems getter the phone uses (first section's items).
    final heroItems = state.heroItems;
    final heroItem = heroItems.isNotEmpty ? heroItems.first : null;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        slivers: [
          // ── Hero banner ──────────────────────────────────────────────────
          // Uses the REAL phone FeaturedHero so the TV banner is visually
          // identical to the phone.  The wrapButton hook injects TvFocusable
          // around Play / My List / Info without touching the widget's own code.
          if (heroItem != null)
            SliverToBoxAdapter(
              child: SizedBox(
                height: kHeroHeight,
                child: FeaturedHero(
                  item: heroItem,
                  inList: _inList(heroItem),
                  onPlay: () => _play(heroItem),
                  onInfo: () => _openDetail(heroItem),
                  onToggleList: () => showListStatusSheet(
                    context,
                    item: heroItem,
                    onChanged: () {
                      if (mounted) setState(() {});
                    },
                  ),
                  metaFuture: _heroMeta(heroItem),
                  // Inject TvFocusable around each button so Play / My List /
                  // Info are all reachable via D-pad.  Play gets autofocus so
                  // it is selected when the screen first appears.
                  wrapButton: _tvWrapButton,
                ),
              ),
            ),

          // ── Poster rails (one per section) ──────────────────────────────
          for (var i = 0; i < sections.length; i++)
            SliverToBoxAdapter(
              child: _TvRail(
                section: sections[i],
                onTap: _openDetail,
                onSeeAll: () => _openSeeAll(sections[i]),
                // Autofocus the first card in the first rail only when there
                // is no hero (e.g. source still loading).
                firstAutofocus: heroItem == null && i == 0,
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}

// ── Poster Rail ───────────────────────────────────────────────────────────────

/// One labelled horizontal row of D-pad-focusable poster cards for a [HomeSection].
class _TvRail extends StatelessWidget {
  const _TvRail({
    required this.section,
    required this.onTap,
    this.onSeeAll,
    this.firstAutofocus = false,
  });

  final HomeSection section;
  final ValueChanged<MediaItem> onTap;
  final VoidCallback? onSeeAll;
  final bool firstAutofocus;

  static const double _cardWidth = 140;
  static const double _cardHeight = 210;

  @override
  Widget build(BuildContext context) {
    final items = section.items;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              section.title,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Card row
          SizedBox(
            // Extra vertical headroom so a focused card's 1.08 scale-up has room
            // to grow instead of being clipped by the row: without it the taller
            // focused card overflowed and the ListView cropped its title/poster
            // (tester report). The card itself stays [_cardHeight] and is centred
            // in the taller row, so unfocused cards look unchanged.
            height: _cardHeight + 24,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 40),
              // +1 trailing "See all" card (D-pad: navigate right past the last
              // poster to reach it). Only when a handler is supplied.
              itemCount: items.length + (onSeeAll != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= items.length) {
                  // Trailing "See all" card — opens the full paginated grid.
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Center(
                      child: SizedBox(
                        width: _cardWidth,
                        height: _cardHeight,
                        child: TvFocusable(
                          onTap: onSeeAll!,
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.surface2,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.arrow_forward_rounded,
                                  color: AppColors.textPrimary,
                                  size: 28,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'See all',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }
                final item = items[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: SizedBox(
                      width: _cardWidth,
                      height: _cardHeight,
                      child: TvFocusable(
                        autofocus: firstAutofocus && index == 0,
                        onTap: () => onTap(item),
                        child: PosterCard(
                          title: item.title,
                          imageUrl: item.cover,
                          headers: item.coverHeaders,
                          cellWidth: _cardWidth,
                          // Touch gestures are disabled on TV; TvFocusable
                          // handles OK-key selection.
                          onTap: null,
                          onLongPress: null,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
