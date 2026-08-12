import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/page_content.dart';
import '../../core/models/provider_info.dart';
import '../../core/reading/read_history.dart';
import '../../core/reading/read_store.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/reading/reader_settings.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import 'reader_comfort.dart';

/// Image reader for manga chapters — the paged/webtoon counterpart of
/// [package:watch_app/features/reader/novel_reader_screen.dart]'s text
/// reader. Phone-only (no TV twin, no TV focus handling needed).
class MangaReaderScreen extends StatefulWidget {
  const MangaReaderScreen({
    super.key,
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    required this.cover,
    required this.chapters, // sorted ascending
    required this.startIndex,
    this.malId,
  });

  final String sourceId;
  final String showId;
  final String showTitle;
  final String? cover;
  final List<Episode> chapters;
  final int startIndex;

  /// MAL id, when known — identifies the title for tracker chapter scrobble
  /// (AniList/MAL manga list). Falls back to [showTitle] when null/unmatched.
  final int? malId;

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends State<MangaReaderScreen>
    with ReaderComfortMixin<MangaReaderScreen> {
  late int _index; // chapter index
  late final PageController _pageController;
  late final ScrollController _verticalController;

  bool _loading = true;
  String? _error;
  List<PageImage>? _pages;

  // Current page, as a ValueNotifier rather than plain state: the top-bar
  // label and the bottom slider listen to it directly (ValueListenableBuilder
  // below), so a page turn/scroll tick no longer has to setState() the whole
  // screen — the PageView/ListView, chrome, etc. don't get rebuilt just to
  // update a page counter. `_pageIndex` stays as a getter/setter so every
  // existing read/write in this file (there are many) is unchanged.
  final ValueNotifier<int> _pageIndexVN = ValueNotifier<int>(0);
  int get _pageIndex => _pageIndexVN.value;
  set _pageIndex(int value) => _pageIndexVN.value = value;

  bool _chromeVisible = false;
  int _lastScrollSaveMs = 0;
  Offset? _lastDoubleTapPos;
  final Map<int, TransformationController> _zoomControllers = {};

  // Chapter ids already scrobbled this session — dedupes a repeated
  // "finished" save (page turns, throttled scroll ticks, and the flush on
  // chapter change/dispose can all observe the same finished chapter).
  final Set<String> _scrobbled = {};

  /// True while the bottom-bar page slider is being dragged. `_seekToPage`
  /// jumps the real `PageController`/`ScrollController` on every drag tick
  /// (so the page/list stays visually in sync with the thumb) — but a
  /// `PageController.jumpToPage`/`ScrollController.jumpTo` synchronously
  /// re-fires `onPageChanged`/the scroll listener, which would otherwise
  /// call `_preload`/`_saveProgress` on every tick too. This flag makes
  /// those two listeners skip that work while a drag is live; `_commitSeek`
  /// (`onChangeEnd`) does it exactly once, when the drag settles.
  bool _seeking = false;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    _pageController = PageController();
    _verticalController = ScrollController()..addListener(_onVerticalScroll);
    // Wakelock/brightness/orientation — see ReaderComfortMixin. Best-effort:
    // a plugin-channel failure (e.g. an unusual device, or — in widget tests
    // — no host handler at all) must not crash the reader; the mixin itself
    // swallows that.
    applyReaderComfort();
    _load();
  }

  @override
  void dispose() {
    // Same ordering as NovelReaderScreen: capture the final position before
    // any controller it depends on is disposed. Paged mode's _pageIndex is
    // already current (set on every settled onPageChanged); vertical mode's
    // is only updated on scroll events, so re-derive it from the live
    // ScrollController one last time before that controller goes away.
    _captureFinalVerticalIndex();
    _flushProgress(); // reader close: don't lose the last-read position
    restoreReaderComfort();
    _verticalController.removeListener(_onVerticalScroll);
    _verticalController.dispose();
    _pageController.dispose();
    for (final c in _zoomControllers.values) {
      c.dispose();
    }
    _pageIndexVN.dispose();
    super.dispose();
  }

  Episode get _chapter => widget.chapters[_index];

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pages = await sl<SourceRepository>().pages(
        _chapter.url,
        sourceId: widget.sourceId,
      );
      if (!mounted) return;
      final saved = sl<ReadStore>().get(
        widget.sourceId,
        widget.showId,
        _chapter.id,
      );
      final start = clampPageIndex(saved?.pos ?? 0, pages.length);
      setState(() {
        _pages = pages;
        _pageIndex = start;
        _loading = false;
      });
      _preload(start, pages);
      _restoreControllerPositions(start, pages.length);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = "Couldn't load this chapter.";
        _loading = false;
      });
    }
  }

  /// Jumps whichever controller is actually mounted (paged xor vertical) to
  /// [start] once the freshly-loaded chapter has laid out. No-op for a
  /// never-read chapter (start == 0, both jumps are then harmless no-ops).
  void _restoreControllerPositions(int start, int pageCount) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) _pageController.jumpToPage(start);
      if (_verticalController.hasClients && pageCount > 1) {
        final max = _verticalController.position.maxScrollExtent;
        if (max > 0) {
          _verticalController.jumpTo(start / (pageCount - 1) * max);
        }
      }
    });
  }

  /// Decode width for the current device — see `readerDecodeWidth`'s doc.
  /// Computed from `context` rather than cached: it's cheap, and re-reading
  /// it picks up an orientation/window change for free.
  int _decodeWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    return readerDecodeWidth((mq.size.width * mq.devicePixelRatio).round());
  }

  void _preload(int index, List<PageImage> pages) {
    final width = _decodeWidth(context);
    final window = preloadWindow(
      index,
      pages.length,
      count: sl<ReaderPrefs>().preloadCount,
    );
    for (final i in window) {
      final p = pages[i];
      precacheImage(
        // Mirrors exactly what CachedNetworkImage(memCacheWidth: width,
        // maxWidthDiskCache: width) builds internally (cached_network_image
        // wraps its provider in the same ResizeImage), so this precache
        // lands under the same cache key the visible page will later
        // resolve to instead of warming a full-res entry nothing reads.
        ResizeImage.resizeIfNeeded(
          width,
          null,
          CachedNetworkImageProvider(p.url, headers: p.headers, maxWidth: width),
        ),
        context,
        onError: (_, _) {}, // best-effort — a failed prefetch is not fatal
      );
    }
  }

  void _onPageChanged(int index) {
    // Just the notifier, not setState — see the field comment on
    // _pageIndexVN. The next-chapter overlay and chrome's page counter each
    // listen for this themselves.
    _pageIndex = index;
    // A slider drag drives this too (jumpToPage fires onPageChanged) —
    // _commitSeek does the preload/save exactly once when the drag ends.
    if (_seeking) return;
    final pages = _pages;
    if (pages != null) _preload(index, pages);
    _saveProgress(flush: false);
  }

  void _onVerticalScroll() {
    final pages = _pages;
    if (pages == null || pages.isEmpty || !_verticalController.hasClients) {
      return;
    }
    final pos = _verticalController.position;
    final estimated = estimateIndexFromScroll(
      pos.pixels,
      pos.maxScrollExtent,
      pages.length,
    );
    if (estimated != _pageIndex) {
      _pageIndex = estimated; // notifier only — see _onPageChanged
      if (!_seeking) _preload(estimated, pages);
    }
    // Same reasoning as _onPageChanged: a slider drag also drives this via
    // ScrollController.jumpTo, and _commitSeek is the single source of
    // truth for the preload/save once the drag ends.
    if (_seeking) return;

    // Throttle routine in-chapter saves to ~once/second, same as the novel
    // reader's scroll listener.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollSaveMs < 1000) return;
    _lastScrollSaveMs = now;
    _saveProgress(flush: false);
  }

  /// Re-derives `_pageIndex` from the live ScrollController — called from
  /// [dispose] only, and only meaningful in vertical mode (paged mode keeps
  /// `_pageIndex` current via [_onPageChanged] on every settled page turn).
  /// MUST run before `_verticalController.dispose()`.
  void _captureFinalVerticalIndex() {
    final pages = _pages;
    if (pages == null || pages.isEmpty || !_verticalController.hasClients) {
      return;
    }
    final pos = _verticalController.position;
    _pageIndex = estimateIndexFromScroll(
      pos.pixels,
      pos.maxScrollExtent,
      pages.length,
    );
  }

  /// Persists the current chapter's position. `ReadStore.save`/
  /// `ReadHistory.save` both already start with `if (IncognitoMode.on)
  /// return;` internally, so no extra guard belongs here — adding one would
  /// duplicate that check for no behavioral change.
  /// [complete] forces the mark to the last page regardless of where the user
  /// actually scrolled — used when they explicitly move ON to the next chapter,
  /// which is a "done with this one" signal even if they skipped the tail.
  void _saveProgress({required bool flush, bool complete = false}) {
    final pages = _pages;
    if (pages == null || pages.isEmpty) return; // nothing loaded yet
    final ep = _chapter;
    final pos = complete ? pages.length - 1 : _pageIndex;
    sl<ReadStore>().save(
      widget.sourceId,
      widget.showId,
      ep.id,
      pos: pos,
      total: pages.length,
    );
    sl<ReadHistory>().save(
      ReadEntry(
        sourceId: widget.sourceId,
        showId: widget.showId,
        title: widget.showTitle,
        cover: widget.cover,
        chapterId: ep.id,
        chapterNumber: ep.number,
        chapterUrl: ep.url,
        pos: pos,
        total: pages.length,
        updatedMs: DateTime.now().millisecondsSinceEpoch,
        type: ProviderType.manga,
      ),
      flush: flush,
    );
    if (sl<ReadStore>().finished(widget.sourceId, widget.showId, ep.id)) {
      _maybeScrobble(ep);
    }
  }

  /// Chapter scrobble on completion — mirrors player_controller.dart's
  /// _maybeScrobble guard structure exactly (TrackerHub registration check,
  /// a dedupe set, then TrackerHub.scrobble). TrackerHub already gates
  /// incognito internally, so no extra check belongs here.
  void _maybeScrobble(Episode ep) {
    if (_scrobbled.contains(ep.id)) return;
    final n = ep.number;
    if (n == null || n <= 0 || n != n.truncateToDouble()) return;
    if (!sl.isRegistered<TrackerHub>()) return;
    _scrobbled.add(ep.id);
    sl<TrackerHub>().scrobble(
      malId: widget.malId,
      title: widget.showTitle,
      episode: n.toInt(),
      kind: MediaKind.manga,
    );
  }

  void _flushProgress() => _saveProgress(flush: true);

  void _goToChapter(int newIndex) {
    if (newIndex < 0 || newIndex >= widget.chapters.length) return;
    if (newIndex == _index) return;
    // Moving ON to a later chapter means the user is done with this one — mark
    // it read and let it scrobble even if they never scrolled the tail (the
    // "Next chapter →" footer button is the common path). Going BACKWARDS is
    // not completion, so it just saves the real position.
    _saveProgress(flush: true, complete: newIndex > _index);
    for (final c in _zoomControllers.values) {
      c.dispose();
    }
    _zoomControllers.clear();
    setState(() {
      _index = newIndex;
      _pages = null;
      _error = null;
      _pageIndex = 0;
      _lastScrollSaveMs = 0;
    });
    _load();
  }

  /// Slider drag tick — just moves the visible page and updates the label.
  /// Preloading and progress-saving are deferred to [_commitSeek]
  /// (`onChangeEnd`): dragging across a long chapter fires this on every
  /// tick, and doing the image-fetch/Hive-write work there would queue
  /// hundreds of preload requests for one drag.
  void _seekToPage(int page) {
    final pages = _pages;
    if (pages == null || pages.isEmpty) return;
    final clamped = clampPageIndex(page, pages.length);
    setState(() => _pageIndex = clamped);
    if (_pageController.hasClients) _pageController.jumpToPage(clamped);
    if (_verticalController.hasClients && pages.length > 1) {
      final max = _verticalController.position.maxScrollExtent;
      if (max > 0) {
        _verticalController.jumpTo(clamped / (pages.length - 1) * max);
      }
    }
  }

  /// Slider drag settled — preload around the page it landed on and persist
  /// it, exactly once per drag. Clears [_seeking] first so this is the only
  /// preload/save that fires for the whole drag.
  void _commitSeek(int page) {
    _seeking = false;
    final pages = _pages;
    if (pages == null || pages.isEmpty) return;
    final clamped = clampPageIndex(page, pages.length);
    _preload(clamped, pages);
    _saveProgress(flush: false);
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  /// Best-effort continuity when the direction pref changes mid-chapter from
  /// the settings sheet: jumps whichever view becomes active to the page the
  /// reader was already on, instead of snapping back to the top.
  void _syncControllersAfterDirectionChange() {
    final pages = _pages;
    if (pages == null || pages.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) _pageController.jumpToPage(_pageIndex);
      if (_verticalController.hasClients && pages.length > 1) {
        final max = _verticalController.position.maxScrollExtent;
        if (max > 0) {
          _verticalController.jumpTo(_pageIndex / (pages.length - 1) * max);
        }
      }
    });
  }

  void _handleTap(double dx, double width) {
    switch (zoneFor(dx, width, sl<ReaderPrefs>().direction)) {
      case ReaderTapZone.previous:
        _pageController.previousPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      case ReaderTapZone.next:
        _pageController.nextPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      case ReaderTapZone.chrome:
        _toggleChrome();
    }
  }

  void _toggleZoom(TransformationController ctrl) {
    if (ctrl.value != Matrix4.identity()) {
      ctrl.value = Matrix4.identity();
      return;
    }
    final pos = _lastDoubleTapPos;
    if (pos == null) {
      ctrl.value = Matrix4.identity()..scaleByDouble(2.0, 2.0, 2.0, 1.0);
      return;
    }
    ctrl.value = Matrix4.identity()
      ..translateByDouble(-pos.dx, -pos.dy, 0, 1.0)
      ..scaleByDouble(2.0, 2.0, 2.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = sl<ReaderPrefs>();
    return Scaffold(
      backgroundColor: _readerBackground(prefs.background),
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody(prefs)),
          if (_chromeVisible) _buildTopBar(),
          if (_chromeVisible) _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildBody(ReaderPrefs prefs) {
    if (_loading) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleChrome,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white70),
        ),
      );
    }
    if (_error != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleChrome,
        child: _buildError(),
      );
    }
    final pages = _pages;
    if (pages == null || pages.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleChrome,
        child: const SizedBox.expand(),
      );
    }
    final direction = prefs.direction;
    final content = direction == 'vertical'
        ? _buildVertical(pages)
        : _buildPaged(pages, direction);
    final hasNext = _index < widget.chapters.length - 1;
    return Stack(
      children: [
        Positioned.fill(child: content),
        // _pageIndex no longer setState()s on every page/scroll tick (see
        // _pageIndexVN), so the overlay has to watch it directly to still
        // appear/disappear exactly at the last page, same as before.
        if (hasNext)
          ValueListenableBuilder<int>(
            valueListenable: _pageIndexVN,
            builder: (context, pageIndex, _) => pageIndex == pages.length - 1
                ? _buildNextChapterOverlay()
                : const SizedBox.shrink(),
          ),
      ],
    );
  }

  Widget _buildPaged(List<PageImage> pages, String direction) {
    return PageView.builder(
      key: const ValueKey('manga-pageview'),
      controller: _pageController,
      reverse: direction == 'rtl',
      itemCount: pages.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) => _pagedItem(pages[index], index),
    );
  }

  Widget _buildVertical(List<PageImage> pages) {
    return ListView.builder(
      key: const ValueKey('manga-listview'),
      controller: _verticalController,
      itemCount: pages.length,
      itemBuilder: (context, index) => _verticalItem(context, pages[index]),
    );
  }

  /// Bounds `_zoomControllers` so a long chapter doesn't retain one
  /// `TransformationController` per page ever visited (they're only ever
  /// added via `_pagedItem`'s `putIfAbsent`, never removed on their own) —
  /// disposes/drops any controller more than 3 pages from wherever the
  /// reader actually is right now. A page revisited after being evicted just
  /// gets a fresh, non-zoomed controller via `putIfAbsent`, same as a page
  /// that was never visited.
  void _evictFarZoomControllers(int current) {
    final stale = _zoomControllers.keys
        .where((k) => (k - current).abs() > 3)
        .toList();
    for (final k in stale) {
      _zoomControllers.remove(k)?.dispose();
    }
  }

  Widget _pagedItem(PageImage page, int index) {
    final ctrl = _zoomControllers.putIfAbsent(
      index,
      () => TransformationController(),
    );
    _evictFarZoomControllers(_pageIndex);
    // RepaintBoundary: a page's own raster is expensive (a decoded bitmap up
    // to readerDecodeWidth), and without this it can get swept into the same
    // repaint as chrome/slider changes above it in the Stack — this pins it
    // to its own compositor layer so those don't re-raster the page. Purely
    // a compositing boundary: it sizes to its child exactly, no layout
    // change.
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = _decodeWidth(context);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) =>
                _handleTap(d.localPosition.dx, constraints.maxWidth),
            onDoubleTapDown: (d) => _lastDoubleTapPos = d.localPosition,
            onDoubleTap: () => _toggleZoom(ctrl),
            child: InteractiveViewer(
              transformationController: ctrl,
              minScale: 1.0,
              maxScale: 4.0,
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: page.url,
                  httpHeaders: page.headers,
                  memCacheWidth: width,
                  maxWidthDiskCache: width,
                  fit: BoxFit.contain,
                  // Static, not an animated spinner — see ColoredBox usage in
                  // poster_card.dart/continue_card.dart for the same convention.
                  placeholder: (_, _) => SizedBox.expand(
                    child: ColoredBox(color: AppColors.surface2),
                  ),
                  errorWidget: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white38,
                    size: 48,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Vertical (webtoon) mode has no left/right paging — the whole chapter is
  /// one continuous scroll, so there is nothing for a left/right tap zone to
  /// mean. Every tap here just toggles chrome, matching `zoneFor`'s own
  /// vertical branch (kept in sync there; this widget doesn't call `zoneFor`
  /// since there's only one outcome to reach).
  Widget _verticalItem(BuildContext context, PageImage page) {
    final width = _decodeWidth(context);
    // See the comment on _pagedItem's RepaintBoundary — same reasoning here.
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleChrome,
        child: CachedNetworkImage(
          imageUrl: page.url,
          httpHeaders: page.headers,
          width: double.infinity,
          memCacheWidth: width,
          maxWidthDiskCache: width,
          fit: BoxFit.fitWidth,
          // Fixed-height static placeholder (not a spinner) — avoids a
          // zero-height flash in the list while still not perpetually
          // animating; same ColoredBox convention as poster_card.dart.
          placeholder: (_, _) => SizedBox(
            height: 200,
            width: double.infinity,
            child: ColoredBox(color: AppColors.surface2),
          ),
          errorWidget: (_, _, _) => const SizedBox(
            height: 200,
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.white38,
              size: 48,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNextChapterOverlay() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 24,
      child: SafeArea(
        top: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(24),
            ),
            child: TextButton(
              onPressed: () => _goToChapter(_index + 1),
              child: Text(
                'Next chapter →',
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 40,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: AppText.body.copyWith(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _load,
              child: Text(
                'Retry',
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final pages = _pages;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Container(
          color: Colors.black.withValues(alpha: 0.85),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.showTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                    ValueListenableBuilder<int>(
                      valueListenable: _pageIndexVN,
                      builder: (context, pageIndex, _) => Text(
                        pages == null || pages.isEmpty
                            ? 'Chapter ${_index + 1} / ${widget.chapters.length}'
                            : 'ch ${_index + 1} · pg ${pageIndex + 1}/${pages.length}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final pages = _pages;
    final pageCount = pages?.length ?? 0;
    final hasPrev = _index > 0;
    final hasNext = _index < widget.chapters.length - 1;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          color: Colors.black.withValues(alpha: 0.85),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pageCount > 1)
                ValueListenableBuilder<int>(
                  valueListenable: _pageIndexVN,
                  builder: (context, pageIndex, _) => Row(
                    children: [
                      Text('${pageIndex + 1}', style: AppText.caption),
                      Expanded(
                        child: Slider(
                          value: pageIndex.toDouble().clamp(
                            0,
                            (pageCount - 1).toDouble(),
                          ),
                          min: 0,
                          max: (pageCount - 1).toDouble(),
                          divisions: pageCount - 1,
                          activeColor: AppColors.accent,
                          onChangeStart: (_) => _seeking = true,
                          onChanged: (v) => _seekToPage(v.round()),
                          onChangeEnd: (v) => _commitSeek(v.round()),
                        ),
                      ),
                      Text('$pageCount', style: AppText.caption),
                    ],
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.skip_previous_rounded,
                      color: Colors.white,
                    ),
                    onPressed: hasPrev ? () => _goToChapter(_index - 1) : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.tune_rounded, color: Colors.white),
                    onPressed: _openSettingsSheet,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.skip_next_rounded,
                      color: Colors.white,
                    ),
                    onPressed: hasNext ? () => _goToChapter(_index + 1) : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Direction/background/keep-screen-on, live-applied — mirrors the shape
  /// of NovelReaderScreen's settings sheet (StatefulBuilder + an `apply`
  /// helper that writes to prefs and rebuilds both the sheet and the
  /// reader).
  void _openSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final prefs = sl<ReaderPrefs>();
          void apply(VoidCallback change) {
            change();
            setSheetState(() {});
            if (mounted) setState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.textTertiary.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text('Reader settings', style: AppText.headline),
                  const SizedBox(height: 12),
                  Text('Direction', style: AppText.caption),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final d in const ['ltr', 'rtl', 'vertical'])
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _choiceChip(
                            _directionLabel(d),
                            prefs.direction == d,
                            () => apply(() {
                              prefs.setDirection(d);
                              _syncControllersAfterDirectionChange();
                            }),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Background', style: AppText.caption),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final b in const ['black', 'dark'])
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _choiceChip(
                            b == 'black' ? 'Black' : 'Dark',
                            prefs.background == b,
                            () => apply(() => prefs.setBackground(b)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Keep screen on', style: AppText.body),
                      ),
                      Switch(
                        value: prefs.keepScreenOn,
                        activeThumbColor: AppColors.accent,
                        onChanged: (v) => apply(() {
                          prefs.setKeepScreenOn(v);
                          applyReaderComfort();
                        }),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _directionLabel(String d) => switch (d) {
    'rtl' => 'Right to left',
    'vertical' => 'Vertical',
    _ => 'Left to right',
  };

  Widget _choiceChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.accent
                : Colors.white.withValues(alpha: 0.16),
            width: selected ? 2 : 1,
          ),
        ),
        child: Text(
          label,
          style: AppText.body.copyWith(
            color: selected ? AppColors.accent : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

Color _readerBackground(String background) =>
    background == 'dark' ? AppColors.bg : Colors.black;

/// Where a tap on a page lands, in the paged (ltr/rtl) reader.
enum ReaderTapZone { previous, next, chrome }

/// Pure and top-level so tap zones are unit-testable without pumping a
/// widget. Splits the page into left/center/right thirds; RTL swaps which
/// side means previous/next (an RTL manga page is physically flipped, so the
/// "next" side is on the left). Vertical mode has no left/right paging at
/// all — see `_verticalItem`, which routes every tap straight to
/// chrome-toggle without consulting this function.
ReaderTapZone zoneFor(double dx, double width, String direction) {
  if (direction == 'vertical') return ReaderTapZone.chrome;
  final third = width / 3;
  if (dx < third) {
    return direction == 'rtl' ? ReaderTapZone.next : ReaderTapZone.previous;
  }
  if (dx > width - third) {
    return direction == 'rtl' ? ReaderTapZone.previous : ReaderTapZone.next;
  }
  return ReaderTapZone.chrome;
}

/// The page indices to prefetch after landing on [current] — the next
/// [count] pages (default 3, matching the reader's original hardcoded
/// window), clamped to the chapter's bounds. Pure so the "preload the next N"
/// contract is unit-testable without a real image loader.
List<int> preloadWindow(int current, int pageCount, {int count = 3}) {
  final result = <int>[];
  for (var i = current + 1; i <= current + count && i < pageCount; i++) {
    result.add(i);
  }
  return result;
}

/// Clamps a saved/candidate page index into the valid `[0, pageCount)`
/// range — guards a chapter whose page count changed since the position was
/// saved (source re-scraped with more/fewer pages) from producing an
/// out-of-range PageView/ListView jump.
int clampPageIndex(int index, int pageCount) {
  if (pageCount <= 0) return 0;
  if (index < 0) return 0;
  if (index >= pageCount) return pageCount - 1;
  return index;
}

/// Estimates the current page index for the vertical (webtoon) reader from
/// scroll position. A ListView of variable-height images doesn't expose
/// per-item offsets cheaply, so this is a proportional approximation — good
/// enough for the progress bar/slider and for resume, not pixel-exact.
int estimateIndexFromScroll(double pixels, double maxExtent, int pageCount) {
  if (pageCount <= 0) return 0;
  if (maxExtent <= 0) return pageCount - 1; // whole chapter fits on screen
  // Scrolled to the bottom => the LAST page, deterministically. The
  // proportional estimate below assumes uniform page heights; webtoon pages
  // vary enormously and the reader appends a next-chapter footer, so it tops
  // out short of the final index — measured 95 of 99 at the visible end of a
  // chapter. Without this snap a chapter can never be marked read, which also
  // means it never scrobbles to AniList/MAL.
  if (pixels >= maxExtent - 8) return pageCount - 1;
  final raw = (pixels / maxExtent * (pageCount - 1)).round();
  return raw.clamp(0, pageCount - 1);
}
