import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/page_content.dart';
import '../../core/models/provider_info.dart';
import '../../core/reading/read_history.dart';
import '../../core/reading/read_store.dart';
import '../../core/reading/reader_overrides.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/reading/reader_settings.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import 'reader_chrome.dart';
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
    this.resolveChapters = false,
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

  /// True when [chapters] may be a single-chapter placeholder (e.g. a
  /// Continue Reading resume, which only has the last-read chapter) that
  /// should widen to the show's real chapter list in the background — see
  /// `_maybeResolveChapters`. Default false: every other caller (Detail
  /// screen) already passes the full list, so this is a no-op for them.
  final bool resolveChapters;

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends State<MangaReaderScreen>
    with ReaderComfortMixin<MangaReaderScreen> {
  late int _index; // chapter index
  // Mutable so a Continue Reading resume (opened with just the one chapter)
  // can widen to the show's full list in the background — see
  // `_maybeResolveChapters`. Every read of the chapter list goes through
  // this, never `widget.chapters` directly.
  late List<Episode> _chapters = widget.chapters;
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

  // Webtoon (vertical) pinch-zoom. The strip stays a lazy ListView for
  // one-finger scrolling; a two-finger pinch drives this scale/offset which a
  // Transform applies over the whole list. See _buildVertical.
  double _wScale = 1.0; // current strip scale, clamped [1, 4]
  Offset _wOffset = Offset.zero; // current strip translation
  bool _wZooming = false; // true only while a 2-finger pinch is live
  double _wStartScale = 1.0; // scale at pinch start
  Offset _wStartFocalChild = Offset.zero; // child point grabbed under the focal

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
    _maybeResolveChapters();
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

  Episode get _chapter => _chapters[_index];

  /// Background upgrade for a Continue Reading resume: opened with just the
  /// one already-read chapter, this fetches the show's real chapter list
  /// (same repo call the Detail screen uses) and — once it lands — widens
  /// `_chapters` and corrects `_index` to the same chapter's new position,
  /// so prev/next light up without disturbing whatever's already on screen.
  /// Never touches `_load()`/scroll/page state itself. Silent no-op on any
  /// failure, an empty/single-chapter result, or a chapter that can't be
  /// found in the fetched list — the single chapter stays a perfectly usable
  /// reader on its own.
  Future<void> _maybeResolveChapters() async {
    if (!widget.resolveChapters || _chapters.length > 1) return;
    final current = _chapter;
    try {
      final fetched = await sl<SourceRepository>().episodes(
        widget.showId,
        sourceId: widget.sourceId,
      );
      if (!mounted || fetched.length <= 1) return;
      var newIndex = fetched.indexWhere((c) => c.url == current.url);
      if (newIndex < 0) {
        newIndex = fetched.indexWhere((c) => c.id == current.id);
      }
      if (newIndex < 0) return;
      setState(() {
        _chapters = fetched;
        _index = newIndex;
      });
    } catch (_) {
      // Keep the single chapter — no error UI, no regression.
    }
  }

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
    if (newIndex < 0 || newIndex >= _chapters.length) return;
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
      // A new chapter starts un-zoomed — don't carry the last one's pinch over.
      _wScale = 1.0;
      _wOffset = Offset.zero;
      _wZooming = false;
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

  /// The direction this chapter is actually shown with: this series' own
  /// override (set from the settings sheet's Direction chips) if one is
  /// active, else the global `prefs.direction`. The `isRegistered` guard
  /// matters for tests: most build this reader with a GetIt that never
  /// registers `ReaderOverrideStore`, and this simply falls back to the
  /// global pref there rather than throwing — same fallback the app itself
  /// would never need, since the injector always registers it.
  String _effectiveDirection(ReaderPrefs prefs) => sl.isRegistered<ReaderOverrideStore>()
      ? sl<ReaderOverrideStore>().effectiveMode(widget.sourceId, widget.showId, prefs)
      : prefs.direction;

  /// Same idea as [_effectiveDirection], for fit.
  String _effectiveFit(ReaderPrefs prefs) => sl.isRegistered<ReaderOverrideStore>()
      ? sl<ReaderOverrideStore>().effectiveFit(widget.sourceId, widget.showId, prefs)
      : prefs.fitMode;

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
    switch (zoneFor(dx, width, _effectiveDirection(sl<ReaderPrefs>()))) {
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
      backgroundColor: readerBgColor(prefs.mangaBackground),
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody(prefs)),
          // Both bars stay in the tree at all times now (an AnimatedOpacity
          // fade instead of the old conditional if (_chromeVisible) build) so
          // the fade can actually animate — see the IgnorePointer below for
          // why that doesn't let a hidden bar eat page taps.
          _buildTopBar(),
          _buildBottomBar(),
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
    final direction = _effectiveDirection(prefs);
    Widget content = direction == 'vertical'
        ? _buildVertical(pages)
        : _buildPaged(pages, direction);
    // Only wrap in ColorFiltered when a filter is actually chosen — 'none'
    // (the default) must leave this widget out of the tree entirely so the
    // default reading path is byte-for-byte what it was before this feature.
    final colorFilter = readerColorFilter(prefs.colorFilter);
    if (colorFilter != null) {
      content = ColorFiltered(colorFilter: colorFilter, child: content);
    }
    final hasNext = _index < _chapters.length - 1;
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

  /// Webtoon pinch-zoom. The strip stays a lazy `ListView.builder` (one-finger
  /// scroll, controller, mark-read-on-bottom all untouched); zoom rides on top
  /// of it via a [_TwoFingerScaleRecognizer] that only enters the play once a
  /// *second* finger lands. That's the whole fix: the old
  /// `InteractiveViewer(panEnabled:false)` sat above the ListView and lost the
  /// gesture arena — the Scrollable's own vertical-drag recognizer claimed any
  /// two-finger gesture that carried the slightest net drag before the scale
  /// recognizer could, so the pinch never fired. This recognizer instead grabs
  /// the arena the instant the 2nd pointer goes down, before the drag
  /// recognizer can cross its slop, so the pinch reliably wins while a lone
  /// finger is still left entirely to the ListView.
  ///
  /// The scale/offset it produces feed a `Transform` wrapping the list, and the
  /// list is frozen ([NeverScrollableScrollPhysics]) only while a pinch is
  /// live so it can't scroll out from under the zoom. Two-finger drag pans a
  /// zoomed strip sideways; the offset is clamped so the content can't be
  /// pushed past its own edges.
  Widget _buildVertical(List<PageImage> pages) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _TwoFingerScaleRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _TwoFingerScaleRecognizer
                >(
                  () => _TwoFingerScaleRecognizer(),
                  (r) {
                    r.onStart = _onWebtoonScaleStart;
                    r.onUpdate = (d) => _onWebtoonScaleUpdate(d, viewport);
                    r.onEnd = _onWebtoonScaleEnd;
                  },
                ),
          },
          child: Transform(
            transform: Matrix4.identity()
              ..translateByDouble(_wOffset.dx, _wOffset.dy, 0, 1.0)
              ..scaleByDouble(_wScale, _wScale, 1.0, 1.0),
            child: ListView.builder(
              key: const ValueKey('manga-listview'),
              controller: _verticalController,
              physics: _wZooming
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemCount: pages.length,
              itemBuilder: (context, index) =>
                  _verticalItem(context, pages[index]),
            ),
          ),
        );
      },
    );
  }

  void _onWebtoonScaleStart(ScaleStartDetails d) {
    _wStartScale = _wScale;
    // The child-space point currently under the focal — held fixed for the
    // gesture so the zoom stays under the fingers and a two-finger drag pans.
    _wStartFocalChild = (d.localFocalPoint - _wOffset) / _wStartScale;
    setState(() => _wZooming = true);
  }

  void _onWebtoonScaleUpdate(ScaleUpdateDetails d, Size viewport) {
    final s = (_wStartScale * d.scale).clamp(1.0, 4.0);
    // Solve the translation that keeps the grabbed child point under the
    // current focal: screen = s * child + offset.
    var t = d.localFocalPoint - _wStartFocalChild * s;
    // Clamp so a scaled strip can't be panned past its own edges (and pins
    // offset to zero at scale 1, where there's nothing to pan).
    t = Offset(
      t.dx.clamp(viewport.width * (1 - s), 0.0),
      t.dy.clamp(viewport.height * (1 - s), 0.0),
    );
    setState(() {
      _wScale = s;
      _wOffset = t;
    });
  }

  void _onWebtoonScaleEnd(ScaleEndDetails d) {
    setState(() => _wZooming = false);
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
                  fit: _pageBoxFit(_effectiveFit(sl<ReaderPrefs>())),
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
          fit: _verticalBoxFit(_effectiveFit(sl<ReaderPrefs>())),
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
    // IgnorePointer, not the old `if (_chromeVisible) build it at all` — the
    // bar is always in the tree so AnimatedOpacity has something to fade,
    // but that means it'd otherwise sit invisible on top of the page
    // catching taps meant for page-turn/chrome-toggle underneath. Ignoring
    // while hidden keeps every tap zone in `_handleTap`/`_toggleChrome`
    // working exactly as before.
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_chromeVisible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _chromeVisible ? 1 : 0,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              const ReaderScrim(top: true),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      readerBarButton(
                        Icons.arrow_back_rounded,
                        () => Navigator.of(context).maybePop(),
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
                              style: AppText.body.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            ValueListenableBuilder<int>(
                              valueListenable: _pageIndexVN,
                              builder: (context, pageIndex, _) => Text(
                                pages == null || pages.isEmpty
                                    ? 'Chapter ${_index + 1} / ${_chapters.length}'
                                    : 'ch ${_index + 1} · pg ${pageIndex + 1}/${pages.length}',
                                style: AppText.caption.copyWith(
                                  color: Colors.white70,
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
    final hasNext = _index < _chapters.length - 1;
    // Same IgnorePointer-while-hidden reasoning as _buildTopBar.
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_chromeVisible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _chromeVisible ? 1 : 0,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              const ReaderScrim(top: false),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (pageCount > 1)
                        ValueListenableBuilder<int>(
                          valueListenable: _pageIndexVN,
                          builder: (context, pageIndex, _) => Row(
                            children: [
                              Text(
                                '${pageIndex + 1}',
                                style: AppText.caption.copyWith(
                                  color: Colors.white70,
                                ),
                              ),
                              Expanded(
                                child: ReaderSlider(
                                  value: pageIndex.toDouble().clamp(
                                    0,
                                    (pageCount - 1).toDouble(),
                                  ),
                                  min: 0,
                                  max: (pageCount - 1).toDouble(),
                                  divisions: pageCount - 1,
                                  onChangeStart: (_) => _seeking = true,
                                  onChanged: (v) => _seekToPage(v.round()),
                                  onChangeEnd: (v) => _commitSeek(v.round()),
                                ),
                              ),
                              Text(
                                '$pageCount',
                                style: AppText.caption.copyWith(
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          readerBarButton(
                            Icons.skip_previous_rounded,
                            () => _goToChapter(_index - 1),
                            enabled: hasPrev,
                          ),
                          readerBarButton(
                            Icons.tune_rounded,
                            _openSettingsSheet,
                          ),
                          readerBarButton(
                            Icons.skip_next_rounded,
                            () => _goToChapter(_index + 1),
                            enabled: hasNext,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
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
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final prefs = sl<ReaderPrefs>();
          // Guarded the same way as the reader body — see _effectiveDirection's
          // doc. Null only in a test harness that never registered the store;
          // the app itself always does (injector.dart).
          final overrides = sl.isRegistered<ReaderOverrideStore>()
              ? sl<ReaderOverrideStore>()
              : null;
          final modeOverride = overrides?.modeOverride(
            widget.sourceId,
            widget.showId,
          );
          final fitOverride = overrides?.fitOverride(
            widget.sourceId,
            widget.showId,
          );
          void apply(VoidCallback change) {
            change();
            setSheetState(() {});
            if (mounted) setState(() {});
          }

          return ReaderSheetShell(
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: AppColors.textTertiary.withValues(
                                alpha: 0.5,
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Text('Reader settings', style: AppText.headline),
                        readerSheetSection('Reading'),
                        Text('Direction', style: AppText.caption),
                        const SizedBox(height: 8),
                        Wrap(
                          runSpacing: 8,
                          children: [
                            for (final d in const <String?>[
                              null,
                              'ltr',
                              'rtl',
                              'vertical',
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _choiceChip(
                                  d == null ? 'Default' : _directionLabel(d),
                                  modeOverride == d,
                                  () => apply(() {
                                    overrides?.setModeOverride(
                                      widget.sourceId,
                                      widget.showId,
                                      d,
                                    );
                                    _syncControllersAfterDirectionChange();
                                  }),
                                ),
                              ),
                          ],
                        ),
                        if (modeOverride != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '· this title',
                              style: AppText.caption.copyWith(
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ),
                        readerSheetSection('Display'),
                        Text('Fit', style: AppText.caption),
                        const SizedBox(height: 8),
                        Wrap(
                          runSpacing: 8,
                          children: [
                            for (final f in const <String?>[
                              null,
                              'contain',
                              'width',
                              'height',
                              'original',
                              'smart',
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _choiceChip(
                                  f == null ? 'Default' : _fitLabel(f),
                                  fitOverride == f,
                                  () => apply(
                                    () => overrides?.setFitOverride(
                                      widget.sourceId,
                                      widget.showId,
                                      f,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (fitOverride != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '· this title',
                              style: AppText.caption.copyWith(
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        Text('Background', style: AppText.caption),
                        const SizedBox(height: 8),
                        Wrap(
                          runSpacing: 8,
                          children: [
                            for (final b in const [
                              'black',
                              'white',
                              'gray',
                              'system',
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _choiceChip(
                                  _backgroundLabel(b),
                                  prefs.mangaBackground == b,
                                  () => apply(() => prefs.setMangaBackground(b)),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text('Filter', style: AppText.caption),
                        const SizedBox(height: 8),
                        Wrap(
                          runSpacing: 8,
                          children: [
                            for (final f in const [
                              'none',
                              'grayscale',
                              'invert',
                              'sepia',
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _choiceChip(
                                  _filterLabel(f),
                                  prefs.colorFilter == f,
                                  () => apply(() => prefs.setColorFilter(f)),
                                ),
                              ),
                          ],
                        ),
                        readerSheetSection('Comfort'),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Keep screen on',
                                style: AppText.body,
                              ),
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
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: _prefSlider(
                                'Brightness',
                                prefs.brightness,
                                -1.0,
                                1.0,
                                (v) => apply(() {
                                  prefs.setBrightness(v);
                                  applyReaderComfort();
                                }),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _choiceChip(
                              'System',
                              prefs.brightness < 0,
                              () => apply(() {
                                prefs.setBrightness(-1.0);
                                applyReaderComfort();
                              }),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
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

  String _fitLabel(String f) => switch (f) {
    'width' => 'Width',
    'height' => 'Height',
    'original' => 'Original',
    'smart' => 'Smart',
    _ => 'Contain',
  };

  String _backgroundLabel(String b) => switch (b) {
    'white' => 'White',
    'gray' => 'Gray',
    'system' => 'Theme',
    _ => 'Black',
  };

  String _filterLabel(String f) => switch (f) {
    'grayscale' => 'Grayscale',
    'invert' => 'Invert',
    'sepia' => 'Sepia',
    _ => 'None',
  };

  /// Same shape as NovelReaderScreen's own `_prefSlider` — a label column
  /// plus an expanded `Slider`, used here for the brightness row.
  Widget _prefSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 88, child: Text(label, style: AppText.body)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            activeColor: AppColors.accent,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

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

/// Resolves `ReaderPrefs.fitMode` into the `BoxFit` used to render a paged
/// page. `smart` needs a page's own decoded aspect ratio to pick between
/// fit-width/fit-height (see `fitToBoxFit`'s smart branch, unit-tested on its
/// own), which means waiting on that page's `ImageStream` — heavier than
/// this phase needs, since a tall page (the common case smart-fit is for)
/// already wants fit-width.
// ponytail: smart-fit skips real aspect-ratio resolution here and renders as
// fitWidth (the common tall-page outcome). Upgrade path: resolve each page's
// decoded ImageInfo size via an ImageStream listener and call
// fitToBoxFit(FitMode.smart, pageAspect: ..., screenAspect: ...) with the
// real values.
BoxFit _pageBoxFit(String fitModeKey) {
  if (fitModeKey == 'smart') return BoxFit.fitWidth;
  final mode = FitMode.values.firstWhere(
    (m) => m.name == fitModeKey,
    orElse: () => FitMode.contain,
  );
  return fitToBoxFit(mode, pageAspect: 1, screenAspect: 1);
}

/// Same as [_pageBoxFit], but for the webtoon (vertical) strip: it's always
/// rendered `width: double.infinity`, so 'contain' has no meaning there — its
/// contain-equivalent default is fit-to-width, matching the reader's
/// original hardcoded behavior. Any other explicitly-chosen fit is honored
/// as-is.
BoxFit _verticalBoxFit(String fitModeKey) {
  if (fitModeKey == 'contain') return BoxFit.fitWidth;
  return _pageBoxFit(fitModeKey);
}

/// A [ScaleGestureRecognizer] that stays out of the gesture arena until a
/// *second* pointer lands, then claims it immediately. That two-part rule is
/// what lets the webtoon strip zoom without losing its scroll: a lone finger
/// is never contested, so the ListView underneath scrolls normally; the moment
/// a second finger goes down this grabs the arena — before the Scrollable's
/// vertical-drag recognizer can cross its touch slop — so the pinch reliably
/// wins instead of being read as a drag.
class _TwoFingerScaleRecognizer extends ScaleGestureRecognizer {
  final Set<int> _pointers = {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointers.add(event.pointer);
    if (_pointers.length >= 2) resolve(GestureDisposition.accepted);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointers.clear();
    super.didStopTrackingLastPointer(pointer);
  }
}

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
