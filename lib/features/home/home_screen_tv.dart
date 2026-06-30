import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/poster_card.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';
import 'cubit/home_cubit.dart';

/// TV Home: a full-screen vertically-scrolling layout with a focusable hero
/// banner (first item of the first section) followed by horizontal poster
/// rails (one per section). Every interactive element is wrapped in
/// [TvFocusable] for D-pad + OK navigation. Touch is not used on TV.
class HomeScreenTv extends StatefulWidget {
  const HomeScreenTv({super.key});

  @override
  State<HomeScreenTv> createState() => _HomeScreenTvState();
}

class _HomeScreenTvState extends State<HomeScreenTv> {
  /// Open the Detail screen — mirrors the phone's _HomeViewState._openDetail.
  void _openDetail(MediaItem item) {
    Navigator.push(context, DetailScreen.route(item));
  }

  /// Begin playback from scratch — mirrors the phone's _HomeViewState._playFeatured.
  Future<void> _play(MediaItem item) async {
    final category =
        sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          sourceId: item.sourceId,
          episodesResolver: () =>
              sl<SourceRepository>().episodes(item.url, sourceId: item.sourceId),
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HomeCubit>().state;
    final sections = state.sections ?? const <HomeSection>[];

    // First section's first item drives the hero banner.
    final heroItem =
        sections.isNotEmpty && sections.first.items.isNotEmpty
            ? sections.first.items.first
            : null;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        slivers: [
          // ── Hero banner ──────────────────────────────────────────────────
          if (heroItem != null)
            SliverToBoxAdapter(
              child: _TvHero(
                item: heroItem,
                onPlay: () => _play(heroItem),
                onInfo: () => _openDetail(heroItem),
                // Hero Play is the very first focusable on the page.
                playAutofocus: true,
              ),
            ),

          // ── Poster rails (one per section) ──────────────────────────────
          for (var i = 0; i < sections.length; i++)
            SliverToBoxAdapter(
              child: _TvRail(
                section: sections[i],
                onTap: _openDetail,
                // Autofocus the first card only when there is no hero.
                firstAutofocus: heroItem == null && i == 0,
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}

// ── Hero ──────────────────────────────────────────────────────────────────────

/// Full-width hero banner: poster/backdrop image, dark gradient overlay, title,
/// and D-pad-focusable Play + More Info action buttons.
class _TvHero extends StatelessWidget {
  const _TvHero({
    required this.item,
    required this.onPlay,
    required this.onInfo,
    this.playAutofocus = false,
  });

  final MediaItem item;
  final VoidCallback onPlay;
  final VoidCallback onInfo;
  final bool playAutofocus;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop image (may be a portrait poster — cover + clip).
          if (item.cover != null)
            CachedNetworkImage(
              imageUrl: item.cover!,
              httpHeaders: item.coverHeaders,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 200),
              placeholder: (_, _) => const ColoredBox(color: AppColors.surface),
              errorWidget: (_, _, _) =>
                  const ColoredBox(color: AppColors.surface),
            )
          else
            const ColoredBox(color: AppColors.surface),

          // Side vignette (left) for text readability over the image.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
                colors: [Color(0x000B0B0F), Color(0xCC0B0B0F)],
              ),
            ),
          ),
          // Bottom scrim.
          const DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.scrim),
          ),

          // Title + action buttons, anchored to the bottom-left.
          Positioned(
            left: 48,
            right: 48,
            bottom: 40,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    TvFocusable(
                      autofocus: playAutofocus,
                      onTap: onPlay,
                      child: const _HeroButton(
                        icon: Icons.play_arrow_rounded,
                        label: 'Play',
                        primary: true,
                      ),
                    ),
                    const SizedBox(width: 16),
                    TvFocusable(
                      onTap: onInfo,
                      child: const _HeroButton(
                        icon: Icons.info_outline_rounded,
                        label: 'More Info',
                        primary: false,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroButton extends StatelessWidget {
  const _HeroButton({
    required this.icon,
    required this.label,
    required this.primary,
  });

  final IconData icon;
  final String label;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: primary ? Colors.white : Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: primary ? Colors.black : Colors.white),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: primary ? Colors.black : Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
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
    this.firstAutofocus = false,
  });

  final HomeSection section;
  final ValueChanged<MediaItem> onTap;
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
            height: _cardHeight,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 40),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: _cardWidth,
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
