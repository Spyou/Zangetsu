import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/di/injector.dart';
import '../../core/metadata/title_logo_service.dart';
import '../../core/models/episode.dart';
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
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/featured_hero.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../auth/auth_cubit.dart';
import '../detail/detail_screen.dart';
import '../player/tv_exo_player_screen.dart';
import '../player/tv_native_player.dart';
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
  /// TV uses the native ExoPlayer player, which takes an episode LIST (not a
  /// resolver), so resolve the episodes first, then open it.
  Future<void> _play(MediaItem item) async {
    final category =
        sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    List<Episode> episodes;
    try {
      episodes = await sl<SourceRepository>().episodes(
        item.url,
        sourceId: item.sourceId,
      );
    } catch (_) {
      episodes = const [];
    }
    if (!mounted || episodes.isEmpty) return;
    resolveSources(String u) => sl<SourceRepository>().sources(
      u,
      sourceId: item.sourceId,
      fast: true,
    );
    // Beta: fully-native TV player (real-window SurfaceView) for TVs that
    // black-screen the Flutter platform-view player. Opt-in; phone unaffected.
    if (sl<PlaybackPrefs>().nativeTvPlayer) {
      await TvNativePlayer.play(
        sourceId: item.sourceId,
        episodes: episodes,
        startIndex: 0,
        resume: sl<ResumeStore>(),
        resolveSources: resolveSources,
        showUrl: item.url,
        showTitle: item.title,
        cover: item.cover,
        coverHeaders: item.coverHeaders,
        category: category,
        availableCategories: [
          if ((item.subCount ?? 0) > 0) 'sub',
          if ((item.dubCount ?? 0) > 0) 'dub',
        ],
        malId: item.malId,
        scrobbleTitle: item.type == ProviderType.anime ? item.title : null,
      );
      if (mounted) setState(() {});
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TvExoPlayerScreen(
          sourceId: item.sourceId,
          episodes: episodes,
          startIndex: 0,
          resume: sl<ResumeStore>(),
          resolveSources: resolveSources,
          showTitle: item.title,
          showUrl: item.url,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          category: category,
          availableCategories: [
            if ((item.subCount ?? 0) > 0) 'sub',
            if ((item.dubCount ?? 0) > 0) 'dub',
          ],
          malId: item.malId,
          scrobbleTitle: item.type == ProviderType.anime ? item.title : null,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Resume a Continue Watching entry — resolve its episodes, then open the
  /// ExoPlayer player at the saved episode (it seeks to the stored position on
  /// load via ResumeStore).
  Future<void> _resume(HistoryEntry e) async {
    List<Episode> episodes;
    try {
      episodes = await sl<SourceRepository>().episodes(
        e.showUrl,
        category: e.category,
        sourceId: e.sourceId,
      );
    } catch (_) {
      episodes = const [];
    }
    if (!mounted || episodes.isEmpty) return;
    var idx = episodes.indexWhere((ep) => ep.id == e.episodeId);
    if (idx < 0) idx = 0;
    resolveSources(String u) => sl<SourceRepository>().sources(
      u,
      sourceId: e.sourceId,
      fast: true,
    );
    if (sl<PlaybackPrefs>().nativeTvPlayer) {
      await TvNativePlayer.play(
        sourceId: e.sourceId,
        episodes: episodes,
        startIndex: idx,
        resume: sl<ResumeStore>(),
        resolveSources: resolveSources,
        showUrl: e.showUrl,
        showTitle: e.showTitle,
        cover: e.cover,
        coverHeaders: e.coverHeaders,
        category: e.category,
        malId: e.malId,
      );
      if (mounted) setState(() {});
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TvExoPlayerScreen(
          sourceId: e.sourceId,
          episodes: episodes,
          startIndex: idx,
          resume: sl<ResumeStore>(),
          resolveSources: resolveSources,
          showTitle: e.showTitle,
          showUrl: e.showUrl,
          cover: e.cover,
          coverHeaders: e.coverHeaders,
          category: e.category,
          malId: e.malId,
          scrobbleTitle: e.malId != null ? e.showTitle : null,
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
    String? semanticLabel,
  }) {
    return TvFocusable(
      autofocus: autofocus,
      variant: TvFocusVariant.float,
      scale: 1.06,
      onTap: onTap,
      semanticLabel: semanticLabel,
      // The button's own label Text is baked into child — exclude it so
      // TalkBack only hears it once (from semanticLabel above).
      child: semanticLabel == null ? child : ExcludeSemantics(child: child),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HomeCubit>().state;
    final sections = state.sections ?? const <HomeSection>[];

    // Use the same heroItems getter the phone uses (first section's items).
    final heroItems = state.heroItems;
    final heroItem = heroItems.isNotEmpty ? heroItems.first : null;

    // Continue Watching — same login-gated local history the phone home uses.
    final loggedIn = context.watch<AuthCubit>().state.isLoggedIn;

    // The scroll view, parameterised by the current history so a single source
    // drives both the Continue Watching rail and the rails' autofocus.
    Widget buildScroll(List<HistoryEntry> history) {
      return CustomScrollView(
        slivers: [
          // ── Hero banner ──────────────────────────────────────────────────
          // TV-only cinematic hero: full-bleed art with left-aligned title +
          // meta + labelled buttons (Apple-TV style). Bespoke so it doesn't look
          // like the phone's centred FeaturedHero card — that widget is left
          // untouched for the phone.
          if (heroItem != null)
            SliverToBoxAdapter(
              child: _TvHero(
                items: heroItems.take(6).toList(),
                inListOf: _inList,
                metaOf: _heroMeta,
                onPlay: _play,
                onInfo: _openDetail,
                onToggleList: (item) => showListStatusSheet(
                  context,
                  item: item,
                  onChanged: () {
                    if (mounted) setState(() {});
                  },
                ),
                wrapButton: _tvWrapButton,
              ),
            ),

          // ── Continue Watching (login-gated, resume on OK) ───────────────
          if (history.isNotEmpty)
            SliverToBoxAdapter(
              child: _TvContinueRail(
                history: history,
                onResume: _resume,
                firstAutofocus: heroItem == null,
              ),
            ),

          // ── Poster rails (one per section) ──────────────────────────────
          for (var i = 0; i < sections.length; i++)
            SliverToBoxAdapter(
              child: TvRail(
                section: sections[i],
                onTap: _openDetail,
                onSeeAll: () => _openSeeAll(sections[i]),
                // Autofocus the first rail's first card only when nothing above
                // it (hero or Continue Watching) can take the initial focus.
                firstAutofocus: heroItem == null && history.isEmpty && i == 0,
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      // Continue Watching is login-gated; when signed in, rebuild on
      // watch_history writes so the rail (and the rails' autofocus, which keys
      // off history.isEmpty) reacts the instant the cloud pull lands — the pull
      // finishes AFTER this build on login / boot-migration. The box is opened
      // at boot; guard for a signed-out render and the test env where it isn't.
      body: (loggedIn && Hive.isBoxOpen(WatchHistory.boxName))
          ? ValueListenableBuilder(
              valueListenable: Hive.box<Map>(WatchHistory.boxName).listenable(),
              builder: (context, _, _) =>
                  buildScroll(sl<WatchHistory>().recent()),
            )
          : buildScroll(const <HistoryEntry>[]),
    );
  }
}

// ── Poster Rail ───────────────────────────────────────────────────────────────

/// One labelled horizontal row of D-pad-focusable poster cards for a [HomeSection].
/// Public (not `_TvRail`) + [visibleForTesting] so tests can pump it directly.
@visibleForTesting
class TvRail extends StatelessWidget {
  const TvRail({
    super.key,
    required this.section,
    required this.onTap,
    this.onSeeAll,
    this.firstAutofocus = false,
  });

  final HomeSection section;
  final ValueChanged<MediaItem> onTap;
  final VoidCallback? onSeeAll;
  final bool firstAutofocus;

  static const double _cardWidth = 150;
  static const double _cardHeight = 225; // 2:3 poster

  @override
  Widget build(BuildContext context) {
    final items = section.items;
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 0),
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
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Card row. Height = poster + title + a little headroom for the
          // focused card's scale-up (the ListView is Clip.none so the growth and
          // its shadow spill past this box rather than being cropped). Kept snug
          // so rows don't float apart — the old +80 left a big dead band under
          // each title.
          SizedBox(
            height: _cardHeight + 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              // Don't clip the focused card's scale-up + accent glow. Combined
              // with the extra row headroom above, the top rail (pinned under
              // the hero) no longer crops the focused poster/title.
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(horizontal: 40),
              // +1 trailing "See all" card (D-pad: navigate right past the last
              // poster to reach it). Only when a handler is supplied.
              itemCount: items.length + (onSeeAll != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= items.length) {
                  // Trailing "See all" card — opens the full paginated grid.
                  return Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Center(
                      child: SizedBox(
                        width: _cardWidth,
                        height: _cardHeight,
                        child: TvFocusable(
                          onTap: onSeeAll!,
                          variant: TvFocusVariant.float,
                          scale: 1.10,
                          semanticLabel: 'See all',
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
                                // Excluded — the focusable above already
                                // announces 'See all' via semanticLabel.
                                ExcludeSemantics(
                                  child: Text(
                                    'See all',
                                    style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
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
                // Only the poster ART gets the float focus (white outline hugs
                // the artwork); the title sits below, outside the outline.
                return Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: _cardWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TvFocusable(
                          autofocus: firstAutofocus && index == 0,
                          variant: TvFocusVariant.float,
                          scale: 1.06,
                          onTap: () => onTap(item),
                          semanticLabel: item.title,
                          child: SizedBox(
                            width: _cardWidth,
                            height: _cardHeight,
                            child: PosterCard(
                              title: item.title,
                              imageUrl: item.cover,
                              headers: item.coverHeaders,
                              cellWidth: _cardWidth,
                              showTitle: false,
                              onTap: null,
                              onLongPress: null,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // The focusable above already announces the title —
                        // exclude this sibling so TalkBack doesn't say it twice.
                        ExcludeSemantics(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
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

// ── Continue Watching Rail ──────────────────────────────────────────────────

/// A labelled row of D-pad-focusable Continue Watching cards (poster + progress
/// bar). OK resumes the episode at its saved position. Mirrors the phone home's
/// Continue Watching row; fed by the same login-gated [WatchHistory.recent].
class _TvContinueRail extends StatelessWidget {
  const _TvContinueRail({
    required this.history,
    required this.onResume,
    this.firstAutofocus = false,
  });

  final List<HistoryEntry> history;
  final void Function(HistoryEntry) onResume;
  final bool firstAutofocus;

  // Landscape (16:9) art reads better than the phone's portrait ContinueCard on
  // a TV row — it's what Netflix/Disney+ TV apps do too.
  static const double _cardWidth = 300;
  static const double _cardHeight = 176; // 16:9 of 300

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              'Continue Watching',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Landscape art + two lines of text below; snug headroom for the
          // focused card's scale-up (Clip.none lets it spill, so no crop).
          SizedBox(
            height: _cardHeight + 60,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(horizontal: 40),
              itemCount: history.length,
              itemBuilder: (context, index) {
                final e = history[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: _cardWidth,
                    child: _TvContinueCard(
                      entry: e,
                      width: _cardWidth,
                      autofocus: firstAutofocus && index == 0,
                      onResume: () => onResume(e),
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

/// TV-only LANDSCAPE Continue Watching card (16:9 art + progress overlay, with
/// the title and "Continue · E{n}" below). Landscape reads better on TV than
/// the shared portrait ContinueCard; that shared widget is left untouched for
/// the phone.
class _TvContinueCard extends StatelessWidget {
  const _TvContinueCard({
    required this.entry,
    required this.width,
    required this.onResume,
    this.autofocus = false,
  });
  final HistoryEntry entry;
  final double width;
  final VoidCallback onResume;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final sub = e.episodeNumber != null
        ? 'Continue · E${e.episodeNumber!.toInt()}'
        : 'Continue';
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Only the 16:9 ART gets the float focus (white outline hugs it).
          TvFocusable(
            autofocus: autofocus,
            variant: TvFocusVariant.float,
            scale: 1.05,
            onTap: onResume,
            semanticLabel: '${e.showTitle}, $sub',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if ((e.cover ?? '').isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: e.cover!,
                        httpHeaders: e.coverHeaders,
                        fit: BoxFit.cover,
                        memCacheWidth: 600,
                        placeholder: (_, _) =>
                            ColoredBox(color: AppColors.surface2),
                        errorWidget: (_, _, _) =>
                            ColoredBox(color: AppColors.surface2),
                      )
                    else
                      ColoredBox(color: AppColors.surface2),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: 5,
                        color: Colors.black.withValues(alpha: 0.55),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: e.progress.clamp(0.0, 1.0),
                          child: Container(color: AppColors.accent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Both excluded — the focusable above already announces title + sub
          // together via semanticLabel.
          ExcludeSemantics(
            child: Text(
              e.showTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 2),
          ExcludeSemantics(
            child: Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── TV Hero ─────────────────────────────────────────────────────────────────

/// Full-bleed cinematic hero for TV: the artwork fills the banner, a left-side
/// scrim keeps the copy readable, and the title logo (or text), a meta line and
/// the Play / My List / Info buttons sit bottom-left — Apple-TV style. The
/// buttons pass through [wrapButton] so they become D-pad focusable.
class _TvHero extends StatefulWidget {
  const _TvHero({
    required this.items,
    required this.inListOf,
    required this.metaOf,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
    required this.wrapButton,
  });

  /// Featured titles the hero rotates through (Apple-TV style).
  final List<MediaItem> items;
  final bool Function(MediaItem) inListOf;
  final Future<HeroMeta?>? Function(MediaItem) metaOf;
  final void Function(MediaItem) onPlay;
  final void Function(MediaItem) onInfo;
  final void Function(MediaItem) onToggleList;
  final Widget Function(
    Widget child,
    VoidCallback onTap, {
    bool autofocus,
    String? semanticLabel,
  })
  wrapButton;

  @override
  State<_TvHero> createState() => _TvHeroState();
}

class _TvHeroState extends State<_TvHero> {
  int _i = 0;
  String? _logoUrl; // TMDB title logo (null → show the text title)
  Timer? _timer;

  MediaItem get _item => widget.items[_i % widget.items.length];

  @override
  void initState() {
    super.initState();
    _loadLogo();
    _startRotation();
  }

  @override
  void didUpdateWidget(_TvHero old) {
    super.didUpdateWidget(old);
    if (old.items.length != widget.items.length) {
      _i = widget.items.isEmpty ? 0 : _i % widget.items.length;
      _startRotation();
      _loadLogo();
    }
  }

  /// Cycle the featured title every few seconds. The Focus nodes persist across
  /// these rebuilds, so rotating never steals focus from the rows below.
  void _startRotation() {
    _timer?.cancel();
    if (widget.items.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 9), (_) {
        if (!mounted) return;
        setState(() {
          _i = (_i + 1) % widget.items.length;
          _logoUrl = null;
        });
        _loadLogo();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadLogo() async {
    if (!sl.isRegistered<TitleLogoService>()) return;
    final idx = _i;
    try {
      final url = await sl<TitleLogoService>().logoFor(_item);
      if (mounted && idx == _i && url != null && url.isNotEmpty) {
        setState(() => _logoUrl = url);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final inList = widget.inListOf(item);
    final cover = item.cover;
    final hasCover = cover != null && cover.isNotEmpty;
    final mq = MediaQuery.of(context);
    final memW = (mq.size.width * mq.devicePixelRatio).round();
    final provider =
        hasCover ? aniyomiCoverProvider(cover, item.coverHeaders) : null;

    return SizedBox(
      height: mq.size.height * 0.72,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: AppColors.bg),
          if (provider != null)
            Image(
              image: ResizeImage(provider, width: memW),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              gaplessPlayback: true,
            )
          else
            ColoredBox(color: AppColors.surface2),
          // Left scrim for copy legibility.
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xE60B0B0F), Color(0x4D0B0B0F), Color(0x000B0B0F)],
                    stops: [0.0, 0.44, 0.72],
                  ),
                ),
              ),
            ),
          ),
          // Bottom fade into the page so the rails below sit seamlessly.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [AppColors.bg, const Color(0x000B0B0F)],
                    stops: const [0.015, 0.5],
                  ),
                ),
              ),
            ),
          ),
          // Copy + actions, bottom-left (aligned with the row titles below).
          Positioned(
            left: 48,
            right: 48,
            bottom: 52,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: mq.size.width * 0.5,
                    maxHeight: 112,
                  ),
                  child: _logoUrl != null
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: CachedNetworkImage(
                            imageUrl: _logoUrl!,
                            fit: BoxFit.contain,
                            alignment: Alignment.centerLeft,
                            memCacheWidth: memW,
                            fadeInDuration: const Duration(milliseconds: 250),
                            errorWidget: (_, _, _) => _titleText(),
                          ),
                        )
                      : _titleText(),
                ),
                const SizedBox(height: 16),
                _metaLine(item),
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    widget.wrapButton(
                      _playBtn(),
                      () => widget.onPlay(item),
                      autofocus: true,
                      semanticLabel: 'Play',
                    ),
                    const SizedBox(width: 14),
                    widget.wrapButton(
                      _glassBtn(
                        inList ? Icons.check_rounded : Icons.add_rounded,
                        'My List',
                        active: inList,
                      ),
                      () => widget.onToggleList(item),
                      semanticLabel: 'My List',
                    ),
                    const SizedBox(width: 14),
                    widget.wrapButton(
                      _glassBtn(Icons.info_outline_rounded, 'Info'),
                      () => widget.onInfo(item),
                      semanticLabel: 'Info',
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Page dots (Apple-TV) — one per featured title, current one widened.
          if (widget.items.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var d = 0; d < widget.items.length; d++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: d == _i ? 20 : 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: d == _i
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _titleText() => Text(
        _item.title,
        style: AppText.largeTitle.copyWith(
          fontSize: 52,
          height: 1.0,
          letterSpacing: -0.8,
          fontWeight: FontWeight.w800,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );

  Widget _metaLine(MediaItem item) {
    return FutureBuilder<HeroMeta?>(
      future: widget.metaOf(item),
      builder: (context, snap) {
        final m = snap.data;
        if (m == null) return const SizedBox(height: 16);
        final parts = <String>[...m.genres.take(3)];
        if (m.episodeCount > 1) {
          parts.add('${m.episodeCount} Episodes');
        } else if ((m.year ?? '').isNotEmpty) {
          parts.add(m.year!);
        }
        if (parts.isEmpty) return const SizedBox(height: 16);
        return Text(
          parts.join('   ·   ').toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(
            color: Colors.white.withValues(alpha: 0.9),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.6,
          ),
        );
      },
    );
  }

  Widget _playBtn() => Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_arrow_rounded, color: AppColors.bg, size: 24),
            const SizedBox(width: 8),
            Text(
              'Play',
              style: TextStyle(
                fontFamily: 'Inter',
                color: AppColors.bg,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );

  Widget _glassBtn(IconData icon, String label, {bool active = false}) =>
      Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: active ? AppColors.accent : Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Inter',
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      );
}
