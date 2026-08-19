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
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/ui/source_switcher.dart';
import '../detail/detail_screen.dart';
import '../player/tv_exo_player_screen.dart';
import '../player/tv_native_player.dart';
import '../sources/providers_hub_screen.dart';
import 'see_all_screen.dart';
import 'cubit/home_cubit.dart';

part 'home_screen_tv_rail.dart';
part 'home_screen_tv_continue.dart';
part 'home_screen_tv_hero.dart';

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

  @override
  void initState() {
    super.initState();
    // Kick the first load ourselves, exactly like the phone home does. main()
    // only calls HomeCubit.load() when isOnboarded() was already true at boot,
    // so someone who just finished onboarding lands here with sections == null
    // and nothing ever fetches them — a permanently empty TV home.
    final cubit = context.read<HomeCubit>();
    if (cubit.state.sections == null && !cubit.state.loading) cubit.load();
  }

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
        tmdbId: item.tmdbId,
        tmdbIsTv: item.tmdbIsTv,
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
          tmdbId: item.tmdbId,
          tmdbIsTv: item.tmdbIsTv,
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
        scrobbleTitle: e.malId != null ? e.showTitle : null,
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

    // Nothing installed for this mode. The phone shows _NoSourcesGuide here;
    // TV used to fall through and render an empty scroll view — a blank pane
    // with no hint, which is what every new user sees now that the app ships
    // no sources of its own. Give it the same guide plus a focusable CTA, so
    // the D-pad has somewhere to land instead of nowhere.
    // Fail open when the cubit isn't wired up (widget tests pump this screen
    // with only Home/Auth registered) — same reasoning as `hasSourcesFor`,
    // which returns true on error so a half-initialised app never shows a
    // false "no sources" screen. Production always has it.
    final mode = sl.isRegistered<ContentModeCubit>()
        ? sl<ContentModeCubit>().state
        : null;
    if (mode != null && !hasSourcesFor(mode)) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: _TvNoSourcesGuide(mode: mode),
      );
    }

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

/// TV twin of the phone's `_NoSourcesGuide` — shown when nothing is installed
/// for the current mode. Same wording, sized for a 10-foot screen, and its
/// button is a [TvFocusable] with autofocus so the D-pad lands on it instead of
/// on an empty screen with nothing to reach.
class _TvNoSourcesGuide extends StatelessWidget {
  const _TvNoSourcesGuide({required this.mode});

  final ContentMode mode;

  @override
  Widget build(BuildContext context) {
    final (icon, noun) = switch (mode) {
      ContentMode.anime => (Icons.live_tv_rounded, 'shows'),
      ContentMode.manga => (Icons.auto_stories_rounded, 'manga'),
      ContentMode.novel => (Icons.menu_book_rounded, 'novels'),
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 54, color: AppColors.accent),
          ),
          const SizedBox(height: 24),
          Text(
            'No ${mode.label} sources yet',
            textAlign: TextAlign.center,
            style: AppText.headline.copyWith(fontSize: 26),
          ),
          const SizedBox(height: 12),
          Text(
            'Add a source from Providers and your $noun will show up here.',
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 30),
          TvFocusable(
            autofocus: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ProvidersHubScreen(),
              ),
            ),
            // ExcludeFocus so the D-pad stops on the TvFocusable itself, not on
            // the button inside it — same reason the TV onboarding buttons do.
            child: ExcludeFocus(
              child: SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ProvidersHubScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 22),
                  label: const Text('Browse sources'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    textStyle: AppText.button.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
