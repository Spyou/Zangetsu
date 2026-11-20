import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/cache/app_image_cache.dart';
import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/series_groups.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/frosted_surface.dart';
import '../../core/ui/series_stacked_cover.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../player/episode_player_route.dart';
import '../player/player_screen.dart';

/// A grouped series: its members in hand order, each still a normal title
/// you can open on its own Detail screen. Rename, reorder, remove a member,
/// pick a cover, or delete the grouping (never the underlying titles) from
/// here. A full-bleed blurred backdrop + glass controls, matching the rest
/// of this app's "hero" detail pages.
class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key, required this.group, required this.members});

  final SeriesGroup group;
  final List<MediaItem> members;

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen>
    with SingleTickerProviderStateMixin {
  SeriesGroupStore get _store => sl<SeriesGroupStore>();
  late final TabController _tabs = TabController(length: 2, vsync: this);

  /// Fetched once per member and cached for the life of this screen —
  /// switching tabs back and forth shouldn't re-hit every source.
  final Map<String, Future<List<Episode>>> _episodesByMember = {};

  SeriesGroup get _live => _store.all().firstWhere(
    (g) => g.id == widget.group.id,
    orElse: () => widget.group,
  );

  Map<String, MediaItem> get _byKey => {
    for (final m in widget.members) '${m.sourceId}::${m.id}': m,
  };

  MediaItem? _heroCover(SeriesGroup group) {
    final byKey = _byKey;
    switch (group.coverMode) {
      case SeriesCoverMode.entry:
        return byKey[group.coverMemberKey] ?? widget.members.firstOrNull;
      case SeriesCoverMode.auto:
      case SeriesCoverMode.custom:
        return widget.members.firstOrNull;
    }
  }

  Future<List<Episode>> _episodesFor(MediaItem item) {
    final key = '${item.sourceId}::${item.id}';
    return _episodesByMember.putIfAbsent(
      key,
      () =>
          sl<CatalogueRepository>().episodes(item.url, sourceId: item.sourceId),
    );
  }

  void _openEpisode(MediaItem item, List<Episode> episodes, int index) {
    Navigator.push(
      context,
      episodePlayerRoute(
        builder: (_) => PlayerScreen(
          sourceId: item.sourceId,
          resume: sl<ResumeStore>(),
          resolveSources: (u) => sl<CatalogueRepository>().sources(
            u,
            sourceId: item.sourceId,
            fast: true,
          ),
          episodes: episodes,
          startIndex: index,
          showTitle: item.title,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          showUrl: item.url,
        ),
      ),
    );
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _live.title);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.rename),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _store.rename(_live.id, name);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.deleteSeries),
        content: Text(context.l10n.deleteSeriesConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _store.delete(_live.id);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _pickCover() async {
    final group = _live;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CoverPickerSheet(
        members: widget.members,
        currentKey: group.coverMode == SeriesCoverMode.entry
            ? group.coverMemberKey
            : null,
      ),
    );
    if (chosen == null) return;
    if (chosen == _CoverPickerSheet.autoSentinel) {
      await _store.setCoverAuto(group.id);
    } else {
      await _store.setCoverEntry(group.id, chosen);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final group = _live;
    final byKey = _byKey;
    final hero = _heroCover(group);
    final statusInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: AppColors.bg,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // RepaintBoundary: the blur behind this is expensive to redraw
          // every frame, and without it the engine tries to redo that work
          // mid-transition, drops frames, and the push/pop slide ends up
          // reading as a hard cut instead of an animation. Caching it as its
          // own layer lets the transition just transform the cached bitmap.
          Positioned.fill(
            child: RepaintBoundary(child: _Backdrop(cover: hero)),
          ),
          SafeArea(
            top: false,
            child: NestedScrollView(
              headerSliverBuilder: (context, _) => [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(top: statusInset),
                    child: _topBar(context, group),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 20, 20),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 76,
                          height: 108,
                          child: SeriesStackedCover(
                            covers: widget.members,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: hero?.cover == null
                                  ? ColoredBox(color: AppColors.surface2)
                                  : CachedNetworkImage(
                                      imageUrl: hero!.cover!,
                                      cacheManager: AppImageCache.manager,
                                      httpHeaders: hero.coverHeaders,
                                      fit: BoxFit.cover,
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                group.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.title.copyWith(fontSize: 22),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                group.memberKeys.length == 1
                                    ? '1 title'
                                    : '${group.memberKeys.length} titles',
                                style: AppText.body.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverLayoutBuilder(
                  builder: (context, constraints) {
                    const fadeDistance = 48.0;
                    final distanceToTop =
                        constraints.viewportMainAxisExtent -
                        constraints.remainingPaintExtent;
                    final backgroundOpacity =
                        (1.0 - distanceToTop / fadeDistance).clamp(0.0, 1.0);
                    return SliverOverlapAbsorber(
                      handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                        context,
                      ),
                      sliver: SliverAppBar(
                        automaticallyImplyLeading: false,
                        primary: true,
                        pinned: true,
                        toolbarHeight: 0,
                        backgroundColor: AppColors.bg.withValues(
                          alpha: backgroundOpacity,
                        ),
                        elevation: 0,
                        scrolledUnderElevation: 0,
                        surfaceTintColor: Colors.transparent,
                        bottom: TabBar(
                          controller: _tabs,
                          isScrollable: false,
                          labelColor: AppColors.textPrimary,
                          unselectedLabelColor: AppColors.textSecondary,
                          indicatorColor: AppColors.accent,
                          indicatorSize: TabBarIndicatorSize.label,
                          dividerColor: Colors.transparent,
                          tabs: const [
                            Tab(text: 'Titles'),
                            Tab(text: 'Episodes'),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
              body: TabBarView(
                controller: _tabs,
                children: [
                  _titlesTab(context, group, byKey),
                  _episodesTab(context, group, byKey),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabScroll(String key, Widget sliver) {
    return Builder(
      builder: (context) => CustomScrollView(
        key: PageStorageKey(key),
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: sliver,
          ),
        ],
      ),
    );
  }

  Widget _titlesTab(
    BuildContext context,
    SeriesGroup group,
    Map<String, MediaItem> byKey,
  ) {
    return _tabScroll(
      'series-titles',
      SliverReorderableList(
        itemCount: group.memberKeys.length,
        onReorder: (oldIndex, newIndex) async {
          var to = newIndex;
          if (oldIndex < newIndex) to -= 1;
          final key = group.memberKeys[oldIndex];
          await _store.moveMember(group.id, key, to);
          if (mounted) setState(() {});
        },
        itemBuilder: (context, i) {
          final key = group.memberKeys[i];
          final item = byKey[key];
          return _MemberRow(
            key: ValueKey(key),
            index: i,
            item: item,
            fallbackTitle: key,
            onTap: item == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
                  ),
            onRemove: () async {
              await _store.removeMember(group.id, key);
              if (mounted) setState(() {});
            },
          );
        },
      ),
    );
  }

  Widget _episodesTab(
    BuildContext context,
    SeriesGroup group,
    Map<String, MediaItem> byKey,
  ) {
    final members = [
      for (final k in group.memberKeys)
        if (byKey[k] != null) byKey[k]!,
    ];
    return _tabScroll(
      'series-episodes',
      SliverList.builder(
        itemCount: members.length,
        itemBuilder: (context, i) {
          final item = members[i];
          return _MemberEpisodes(
            key: ValueKey('${item.sourceId}::${item.id}'),
            item: item,
            episodes: _episodesFor(item),
            onTapEpisode: (episodes, index) =>
                _openEpisode(item, episodes, index),
          );
        },
      ),
    );
  }

  Widget _topBar(BuildContext context, SeriesGroup group) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          _GlassIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            onTap: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          _GlassIconButton(icon: Icons.edit_rounded, onTap: _rename),
          const SizedBox(width: 10),
          _GlassIconButton(icon: Icons.image_outlined, onTap: _pickCover),
          const SizedBox(width: 10),
          _GlassIconButton(
            icon: Icons.delete_outline_rounded,
            iconColor: AppColors.accent,
            onTap: _delete,
          ),
        ],
      ),
    );
  }
}

/// Full-bleed blurred hero backdrop — the group's cover, heavily blurred,
/// under a dark scrim so the floating controls and text stay legible.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.cover});

  final MediaItem? cover;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cover?.cover != null)
          CachedNetworkImage(
            imageUrl: cover!.cover!,
            cacheManager: AppImageCache.manager,
            httpHeaders: cover!.coverHeaders,
            fit: BoxFit.cover,
          )
        else
          Container(color: AppColors.surface),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Container(color: Colors.black.withValues(alpha: 0.1)),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.bg.withValues(alpha: 0.55),
                AppColors.bg.withValues(alpha: 0.85),
                AppColors.bg,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.icon,
    required this.onTap,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FrostedSurface(
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 20,
            color: iconColor ?? AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// "Automatic" + one row per member, radio-style. No custom-image upload —
/// the cover is always one of the grouped titles' own art.
class _CoverPickerSheet extends StatelessWidget {
  const _CoverPickerSheet({required this.members, required this.currentKey});

  static const autoSentinel = '__auto__';

  final List<MediaItem> members;
  final String? currentKey;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text('Choose cover', style: AppText.headline),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                RadioListTile<String>(
                  value: autoSentinel,
                  groupValue: currentKey ?? autoSentinel,
                  activeColor: AppColors.accent,
                  title: Text(
                    'Automatic',
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                  ),
                  onChanged: (_) => Navigator.pop(context, autoSentinel),
                ),
                for (final m in members)
                  RadioListTile<String>(
                    value: '${m.sourceId}::${m.id}',
                    groupValue: currentKey ?? autoSentinel,
                    activeColor: AppColors.accent,
                    secondary: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 36,
                        height: 36 / 0.7,
                        child: m.cover == null
                            ? Container(color: AppColors.surface2)
                            : CachedNetworkImage(
                                imageUrl: m.cover!,
                                cacheManager: AppImageCache.manager,
                                httpHeaders: m.coverHeaders,
                                fit: BoxFit.cover,
                              ),
                      ),
                    ),
                    title: Text(
                      m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    onChanged: (_) =>
                        Navigator.pop(context, '${m.sourceId}::${m.id}'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// One member row — M3-expressive: bold rounded shape, a tonal index pill,
/// and a tinted ripple instead of a plain flat tile.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.index,
    required this.item,
    required this.fallbackTitle,
    required this.onTap,
    required this.onRemove,
  });

  final int index;
  final MediaItem? item;
  final String fallbackTitle;
  final VoidCallback? onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashColor: AppColors.accent.withValues(alpha: 0.2),
            highlightColor: AppColors.accent.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 64,
                      height: 64 / 0.7,
                      child: item?.cover == null
                          ? Container(color: AppColors.surface)
                          : CachedNetworkImage(
                              imageUrl: item!.cover!,
                              cacheManager: AppImageCache.manager,
                              httpHeaders: item!.coverHeaders,
                              fit: BoxFit.cover,
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item?.title ?? fallbackTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Title ${index + 1}',
                            style: AppText.caption.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.drag_indicator_rounded,
                        size: 22,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Material(
                    color: AppColors.surface,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      color: AppColors.textSecondary,
                      onPressed: onRemove,
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
}

/// One member's episode list, grouped under its title. The fetch itself is
/// lazy at the member level — [episodes] is only requested once this widget
/// actually builds, which for the outer [ListView.builder] means only once
/// this member's block scrolls near the viewport. A source that fails shows
/// nothing beyond its header rather than an error block — the other members
/// still render.
///
/// Within one member, rows are revealed in batches ([_batchSize] at a time)
/// instead of all at once: a long-running show can have hundreds of
/// episodes, and building (and starting a thumbnail fetch for) every single
/// one the moment the list loads is wasted work for rows nobody has
/// scrolled to yet.
class _MemberEpisodes extends StatefulWidget {
  const _MemberEpisodes({
    super.key,
    required this.item,
    required this.episodes,
    required this.onTapEpisode,
  });

  final MediaItem item;
  final Future<List<Episode>> episodes;
  final void Function(List<Episode> episodes, int index) onTapEpisode;

  @override
  State<_MemberEpisodes> createState() => _MemberEpisodesState();
}

class _MemberEpisodesState extends State<_MemberEpisodes> {
  static const _batchSize = 20;
  static const _lookahead =
      400.0; // px of slack before the sentinel is on screen
  int _visibleCount = _batchSize;
  int _knownTotal = 0;
  final _sentinelKey = GlobalKey();
  ScrollPosition? _scrollPosition;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // This widget lives inside the Episodes tab's own ListView — ask it
    // (not a notification bubble, just reading the nearest ancestor's
    // position) so a scroll anywhere in that list re-checks this sentinel.
    final position = Scrollable.of(context).position;
    if (position != _scrollPosition) {
      _scrollPosition?.removeListener(_onScroll);
      _scrollPosition = position;
      position.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || _visibleCount >= _knownTotal) return;
    final box = _sentinelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (box.localToGlobal(Offset.zero).dy < screenHeight + _lookahead) {
      setState(() => _visibleCount += _batchSize);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text(
            widget.item.title,
            style: AppText.body.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        FutureBuilder<List<Episode>>(
          future: widget.episodes,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _EpisodeListSkeleton();
            }
            final list = snapshot.data ?? const [];
            if (list.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No episodes found',
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              );
            }
            // Cached from the resolved future, not from a setState — lets
            // the scroll listener know when to stop without another build.
            _knownTotal = list.length;
            final shown = _visibleCount < list.length
                ? _visibleCount
                : list.length;
            return Column(
              children: [
                for (var i = 0; i < shown; i++)
                  _EpisodeRow(
                    episode: list[i],
                    fallbackImage: widget.item.cover,
                    fallbackHeaders: widget.item.coverHeaders,
                    onTap: () => widget.onTapEpisode(list, i),
                  ),
                // Invisible trip wire: once this scrolls near the viewport,
                // the next batch reveals itself — no tap needed.
                if (shown < list.length) SizedBox(key: _sentinelKey, height: 1),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// One episode: a 16:9 thumbnail (the episode's own, falling back to the
/// show's cover), a play glyph over it, the episode number as a chip, title
/// and — when the source reports one — the air date. Filler episodes get a
/// small tag next to the number.
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.fallbackImage,
    required this.fallbackHeaders,
    required this.onTap,
  });

  final Episode episode;
  final String? fallbackImage;
  final Map<String, String>? fallbackHeaders;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumb = episode.thumbnail ?? fallbackImage;
    final headers = episode.thumbnail != null ? null : fallbackHeaders;
    final number = episode.number;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashColor: AppColors.accent.withValues(alpha: 0.2),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 112,
                          height: 112 * 9 / 16,
                          child: thumb == null
                              ? Container(color: AppColors.surface)
                              : CachedNetworkImage(
                                  imageUrl: thumb,
                                  cacheManager: AppImageCache.manager,
                                  httpHeaders: headers,
                                  fit: BoxFit.cover,
                                ),
                        ),
                      ),
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (number != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.accent.withValues(
                                    alpha: 0.18,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  'EP ${number.toStringAsFixed(number.truncateToDouble() == number ? 0 : 1)}',
                                  style: AppText.caption.copyWith(
                                    color: AppColors.accent,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            if (episode.filler)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.orange.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  'FILLER',
                                  style: AppText.caption.copyWith(
                                    color: Colors.orange,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          episode.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (episode.date != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            episode.date!,
                            style: AppText.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
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
}

/// Pulsing shimmer placeholder for episode rows, shown while a member's
/// episode list is being fetched. One shared [AnimationController] for the
/// whole stack of placeholders, same pattern as [RowSkeleton]/[SkeletonGrid].
class _EpisodeListSkeleton extends StatefulWidget {
  const _EpisodeListSkeleton();

  @override
  State<_EpisodeListSkeleton> createState() => _EpisodeListSkeletonState();
}

class _EpisodeListSkeletonState extends State<_EpisodeListSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final color = AppColors.surface2.withValues(
            alpha: 0.3 + 0.25 * _anim.value,
          );
          return Column(
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 112,
                          height: 112 * 9 / 16,
                          child: ColoredBox(color: color),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 60,
                                height: 16,
                                child: ColoredBox(color: color),
                              ),
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: double.infinity,
                                height: 14,
                                child: ColoredBox(color: color),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
