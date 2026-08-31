import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/download/cbz_image.dart';
import '../../core/models/page_content.dart';
import '../../core/models/provider_info.dart';
import '../../core/reading/read_history.dart';
import '../../core/reading/read_store.dart';
import '../../core/reading/reader_overrides.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/reading/tap_zones.dart';
import '../../core/reading/reader_settings.dart';
import '../../core/reading/volume_keys.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import 'reader_chrome.dart';
import 'reader_auto_scroll.dart';
import 'reader_auto_scroll_ui.dart';
import 'reader_comfort.dart';
import '../../l10n/l10n.dart';
import 'reader_pull_chapter.dart';

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
    this.peek = false,
  });

  final String sourceId;
  final String showId;
  final String showTitle;
  final String? cover;
  final List<Episode> chapters;
  final int startIndex;

  /// Opened as a look-ahead (or look-back) rather than as your current place:
  /// nothing is persisted. Every write lives behind [_saveProgress] — the
  /// per-chapter mark, the Continue entry AND the tracker scrobble — so one
  /// guard there covers all three. The mark matters as much as the rest,
  /// because the detail screen derives "where you left off" from the highest
  /// marked chapter; a peek mark alone would move your place.
  final bool peek;

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
    with ReaderComfortMixin<MangaReaderScreen>, TickerProviderStateMixin {
  /// Hands-free scrolling — webtoon only; paged modes step whole pages and
  /// have nothing to creep.
  late final ReaderAutoScroll _autoScroll;
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

  // Whether this chapter's first page turned out to be a long vertical strip.
  // Null until _detectWebtoon resolves it, and again on every chapter change.
  bool? _looksLikeWebtoon;

  /// Height/width past which a page is a strip rather than a comic page. A
  /// print-shaped page sits near 1.4 and a double spread below 1; a webtoon
  /// slice is usually 3x its width or more, so 2.5 lands in the gap.
  static const double _webtoonAspect = 2.5;

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
    // Built here, NOT lazily: createTicker reads TickerMode off the
    // context, and a `late final` initialiser would run that on first
    // access — which, if auto-scroll was never used, is dispose(), where
    // the element is already deactivated and the lookup throws.
    _autoScroll = ReaderAutoScroll(vsync: this);
    _verticalController = ScrollController()..addListener(_onVerticalScroll);
    // Wakelock/brightness/orientation — see ReaderComfortMixin. Best-effort:
    // a plugin-channel failure (e.g. an unusual device, or — in widget tests
    // — no host handler at all) must not crash the reader; the mixin itself
    // swallows that.
    applyReaderComfort();
    _syncVolumeKeys();
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
    _autoScroll.dispose();
    VolumeKeys.disable(); // give the volume rocker back
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
      _detectWebtoon();
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
      if (_pageController.hasClients) {
        // In double-page mode the PageView is indexed by spread, so map the
        // real page we're resuming to onto its spread before jumping.
        final spreads = _activeSpreads();
        _pageController.jumpToPage(
          spreads == null ? start : _spreadOfPage(spreads, start),
        );
      }
      if (_verticalController.hasClients && pageCount > 1) {
        final max = _verticalController.position.maxScrollExtent;
        if (max > 0) {
          _verticalController.jumpTo(start / (pageCount - 1) * max);
        }
      }
    });
  }

  /// Reads the first page's real decoded size to work out whether the chapter
  /// is one long strip (manhwa) rather than comic pages — paged mode shows a
  /// strip as sideways slices, which is unreadable. Deliberately off the build
  /// path: [_effectiveDirection] runs on every build and only reads the result.
  ///
  /// The provider is built the way [_pagedItem]/[_verticalItem] build theirs
  /// (CachedNetworkImage wraps its provider in a ResizeImage), so this reads
  /// the page the reader is already decoding instead of fetching a second,
  /// full-size copy. A page that never resolves leaves the flag null and the
  /// reader keeps whatever direction was asked for.
  void _detectWebtoon() {
    final pages = _pages;
    if (pages == null || pages.isEmpty) return;
    if (_looksLikeWebtoon != null) return; // one resolve per chapter
    if (!sl<ReaderPrefs>().autoWebtoon) return;
    final first = pages.first;
    final width = _decodeWidth(context);
    final stream = _pageProvider(
      first,
      width,
    ).resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final tall = info.image.height / info.image.width >= _webtoonAspect;
      info.dispose(); // only the size was wanted, not a retained decode
      if (!mounted || _looksLikeWebtoon == tall) return;
      setState(() => _looksLikeWebtoon = tall);
      // Vertical and paged run off different controllers, so flipping here
      // would otherwise drop the reader back at the top of the chapter.
      _syncControllersAfterDirectionChange();
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
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
      // Warm the bytes on disk, deliberately NOT precacheImage. A page decodes
      // to width × height × 4 — around 28MB at our decode width — against a
      // 100MB Flutter image cache, so precaching even a few pages pushed the
      // already-decoded ones straight back out and the reader paid to decode
      // them again on the way past. This is the same call CachedNetworkImage
      // makes for maxWidthDiskCache, so the file lands under the key the
      // visible page resolves to; only the page you're actually looking at
      // ends up decoded in memory.
      DefaultCacheManager()
          .getImageFile(p.url, headers: p.headers, maxWidth: width)
          .drain<void>()
          .catchError((_) {}); // best-effort — a failed prefetch is not fatal
    }
  }

  void _onPageChanged(int index) {
    // `index` is a spread index when the double-page view is active, else a
    // real page index. Map it back to a real page so `_pageIndex` NEVER holds
    // a spread index — every downstream consumer (`_saveProgress`, resume,
    // mark-read, scrobble, the slider, the "pg x/N" label) reads it as an
    // actual page. Using the highest page of the spread means the final spread
    // yields the final page, so `ReadStore.finished` still fires at the end.
    final spreads = _activeSpreads();
    // The transition page sits past the last real one. Leave _pageIndex on the
    // final page rather than letting it run out of range — everything
    // downstream (the pg x/N label, resume, mark-read, scrobble, the slider)
    // reads it as a real page.
    final count = spreads?.length ?? _pages?.length ?? 0;
    if (index >= count) return;
    final page = spreads == null
        ? index
        : spreads[index].reduce((a, b) => a > b ? a : b);
    // Just the notifier, not setState — see the field comment on
    // _pageIndexVN. The next-chapter overlay and chrome's page counter each
    // listen for this themselves.
    _pageIndex = page;
    // A slider drag drives this too (jumpToPage fires onPageChanged) —
    // _commitSeek does the preload/save exactly once when the drag ends.
    if (_seeking) return;
    final pages = _pages;
    if (pages != null) _preload(page, pages);
    _saveProgress(flush: false);
  }

  /// The double-page spread grouping in effect right now, or null when the
  /// reader is on its ordinary one-page-per-view path (portrait, double-page
  /// pref off, or vertical/webtoon mode). Recomputed on demand — a single pass
  /// over the page indices, cheap enough to call from every page-turn/seek —
  /// so the page↔spread mapping in the callbacks can never drift from whatever
  /// the current build produced.
  List<List<int>>? _activeSpreads() {
    if (!mounted) return null;
    final pages = _pages;
    if (pages == null || pages.isEmpty) return null;
    final prefs = sl<ReaderPrefs>();
    if (!prefs.doublePageLandscape) return null;
    final dir = _effectiveDirection(prefs);
    if (dir == 'vertical') return null;
    if (MediaQuery.orientationOf(context) != Orientation.landscape) return null;
    // ponytail: wide-page detection deferred (needs the image decoded to read
    // its aspect ratio) — every pair is two portrait pages. Upgrade path:
    // resolve each page's decoded size via an ImageStream listener and pass
    // the landscape (aspect > 1) indices here as `wide`.
    return pairPages(pages.length, rtl: dir == 'rtl', wide: const {});
  }

  /// The index of the spread that contains real page [page]. Falls back to 0
  /// so a stale/out-of-range page never throws while seeking or restoring.
  int _spreadOfPage(List<List<int>> spreads, int page) {
    for (var s = 0; s < spreads.length; s++) {
      if (spreads[s].contains(page)) return s;
    }
    return 0;
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
    if (widget.peek) return; // just looking — leave saved progress alone
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
    // The next chapter starts at the top with nothing laid out yet; carrying a
    // live auto-scroll across would race the load and creep through a blank.
    _autoScroll.stop();
    // Moving ON to a later chapter means the user is done with this one — mark
    // it read and let it scrobble even if they never scrolled the tail (the
    // context.l10n.nextChapter2 footer button is the common path). Going BACKWARDS is
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
      _looksLikeWebtoon = null;
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
    if (_pageController.hasClients) {
      // The slider seeks in real page numbers; map to the containing spread
      // when the double-page view is active.
      final spreads = _activeSpreads();
      _pageController.jumpToPage(
        spreads == null ? clamped : _spreadOfPage(spreads, clamped),
      );
    }
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

  /// The direction this chapter is actually shown with, in priority order:
  /// this series' own override (set from the settings sheet's Direction
  /// chips), then auto-webtoon if the chapter turned out to be a long strip,
  /// then the global `prefs.direction`. An explicit per-series choice wins —
  /// auto never second-guesses one.
  ///
  /// Called from build() and a handful of callbacks, so it only ever reads
  /// state that's already computed — see [_detectWebtoon] for the work.
  ///
  /// The `isRegistered` guard matters for tests: most build this reader with
  /// a GetIt that never registers `ReaderOverrideStore`, and this simply
  /// falls back to the global pref there rather than throwing — same fallback
  /// the app itself would never need, since the injector always registers it.
  String _effectiveDirection(ReaderPrefs prefs) {
    final override = sl.isRegistered<ReaderOverrideStore>()
        ? sl<ReaderOverrideStore>().modeOverride(widget.sourceId, widget.showId)
        : null;
    if (override != null) return override;
    if (prefs.autoWebtoon && _looksLikeWebtoon == true) return 'vertical';
    return prefs.direction;
  }

  /// Same idea as [_effectiveDirection], for fit.
  String _effectiveFit(ReaderPrefs prefs) =>
      sl.isRegistered<ReaderOverrideStore>()
      ? sl<ReaderOverrideStore>().effectiveFit(
          widget.sourceId,
          widget.showId,
          prefs,
        )
      : prefs.fitMode;

  /// Best-effort continuity when the direction pref changes mid-chapter from
  /// the settings sheet: jumps whichever view becomes active to the page the
  /// reader was already on, instead of snapping back to the top.
  void _syncControllersAfterDirectionChange() {
    final pages = _pages;
    if (pages == null || pages.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) {
        // Reused when the double-page toggle flips too (itemCount goes
        // page-count↔spread-count under the same controller): re-anchor on the
        // spread holding the current page instead of trusting the stale index.
        final spreads = _activeSpreads();
        _pageController.jumpToPage(
          spreads == null ? _pageIndex : _spreadOfPage(spreads, _pageIndex),
        );
      }
      if (_verticalController.hasClients && pages.length > 1) {
        final max = _verticalController.position.maxScrollExtent;
        if (max > 0) {
          _verticalController.jumpTo(_pageIndex / (pages.length - 1) * max);
        }
      }
    });
  }

  /// Run whatever the current reading mode's tap zones say for a tap at
  /// [global].
  ///
  /// Screen coordinates on purpose: in webtoon mode the tap lands on a page
  /// widget that can be several screens tall, so a position local to that
  /// widget says nothing about where on the SCREEN the finger went. Zones are
  /// normalised, so this is the one measurement that works in every mode.
  void _dispatchTap(Offset global) {
    final size = MediaQuery.sizeOf(context);
    if (size.width <= 0 || size.height <= 0) return;
    final prefs = sl<ReaderPrefs>();
    final mode = _effectiveDirection(prefs);
    final layout = prefs.tapZonesForMode(mode);
    _runReaderAction(
      layout.actionAt(
        Offset(
          (global.dx / size.width).clamp(0.0, 1.0),
          (global.dy / size.height).clamp(0.0, 1.0),
        ),
        rtl: mode == 'rtl',
      ),
    );
  }

  void _runReaderAction(ReaderAction action) {
    const dur = Duration(milliseconds: 200);
    switch (action) {
      case ReaderAction.none:
        return;
      case ReaderAction.toggleMenu:
        _toggleChrome();
      case ReaderAction.nextPage:
        _pageController.nextPage(duration: dur, curve: Curves.easeOut);
      case ReaderAction.prevPage:
        _pageController.previousPage(duration: dur, curve: Curves.easeOut);
      case ReaderAction.scrollUp:
        _scrollStrip(-1);
      case ReaderAction.scrollDown:
        _scrollStrip(1);
      case ReaderAction.nextChapter:
        _goToChapter(_index + 1);
      case ReaderAction.prevChapter:
        _goToChapter(_index - 1);
    }
  }

  /// One screenful, less a sliver of overlap so the line you were on is still
  /// visible after the jump.
  void _scrollStrip(int direction) {
    if (!_verticalController.hasClients) return;
    final pos = _verticalController.position;
    final step = pos.viewportDimension * 0.85 * direction;
    _verticalController.animateTo(
      (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
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
          if (prefs.autoScrollButton)
            ReaderAutoScrollButton(
              autoScroll: _autoScroll,
              onTap: _openAutoScrollSheet,
              initialX: prefs.autoScrollButtonX,
              initialY: prefs.autoScrollButtonY,
              onMoved: prefs.setAutoScrollButtonPos,
            ),
        ],
      ),
    );
  }

  /// Volume-key paging, driven by the native `dispatchKeyEvent` hook (see
  /// [VolumeKeys] for why it can't be done in Dart).
  ///
  /// Down = forward by default; the invert pref swaps that. Vertical/webtoon
  /// mode scrolls a viewport instead of stepping pages, so the keys nudge the
  /// strip rather than doing nothing.
  void _onVolumeKey(bool up) {
    if (!mounted) return;
    final prefs = sl<ReaderPrefs>();
    final forward = up == prefs.invertVolumeKeys;

    if (_effectiveDirection(prefs) == 'vertical') {
      if (!_verticalController.hasClients) return;
      final page = _verticalController.position.viewportDimension * 0.85;
      final target = (_verticalController.offset + (forward ? page : -page))
          .clamp(0.0, _verticalController.position.maxScrollExtent);
      _verticalController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
      return;
    }

    // Same controller calls a tap makes, so paging, progress saving and the
    // last-page next-chapter overlay all behave identically either way.
    const dur = Duration(milliseconds: 180);
    if (forward) {
      _pageController.nextPage(duration: dur, curve: Curves.easeOut);
    } else {
      _pageController.previousPage(duration: dur, curve: Curves.easeOut);
    }
  }

  /// Re-applies the volume-key pref — called on init and whenever the settings
  /// sheet changes it, so toggling it takes effect without leaving the reader.
  void _syncVolumeKeys() {
    if (sl<ReaderPrefs>().volumeKeyPaging) {
      VolumeKeys.enable(_onVolumeKey);
    } else {
      VolumeKeys.disable();
    }
  }

  /// Display name for a neighbouring chapter, for the pull indicator. Null
  /// when the index is out of range, which the indicator treats as "no label".
  String? _chapterLabel(int i) {
    if (i < 0 || i >= _chapters.length) return null;
    final t = _chapters[i].title.trim();
    return t.isNotEmpty ? t : 'Chapter ${i + 1}';
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
    // Touching PAUSES auto-scroll; lifting resumes it after a short grace.
    // The first version stopped it outright on any drag, so nudging the page
    // to re-read a line killed the whole thing and you had to go and switch it
    // back on. Listener rather than scroll notifications: this needs to know
    // about a finger resting on the page, not only one that moved it.
    Widget content = Listener(
      onPointerDown: (_) => _autoScroll.pauseForTouch(),
      onPointerUp: (_) => _autoScroll.resumeAfterTouch(),
      onPointerCancel: (_) => _autoScroll.resumeAfterTouch(),
      child: ReaderPullChapter(
        enabled: prefs.overscrollChapter,
        hasPrev: _index > 0,
        hasNext: _index < _chapters.length - 1,
        prevLabel: _chapterLabel(_index - 1),
        nextLabel: _chapterLabel(_index + 1),
        onChangeChapter: (d) => _goToChapter(_index + d),
        child: direction == 'vertical'
            ? _buildVertical(pages)
            : _buildPaged(pages, direction),
      ),
    );
    // Only wrap in ColorFiltered when a filter is actually chosen — 'none'
    // (the default) must leave this widget out of the tree entirely so the
    // default reading path is byte-for-byte what it was before this feature.
    final colorFilter = readerColorFilter(prefs.colorFilter);
    if (colorFilter != null) {
      content = ColorFiltered(colorFilter: colorFilter, child: content);
    }
    return Stack(
      children: [
        Positioned.fill(child: content),

        // _pageIndex no longer setState()s on every page/scroll tick (see
        // _pageIndexVN), so the overlay has to watch it directly to still
        // appear/disappear exactly at the last page, same as before.
      ],
    );
  }

  /// One extra swipeable page after the last, when there's a chapter to go to.
  /// The old floating context.l10n.nextChapter button sat on top of the artwork; this
  /// gets out of the way instead. Webtoon does the same thing with a footer
  /// under the strip.
  bool get _hasTransitionPage => _index < _chapters.length - 1;

  Widget _buildPaged(List<PageImage> pages, String direction) {
    final spreads = _activeSpreads();
    final extra = _hasTransitionPage ? 1 : 0;
    if (spreads == null) {
      return PageView.builder(
        key: const ValueKey('manga-pageview'),
        controller: _pageController,
        reverse: direction == 'rtl',
        itemCount: pages.length + extra,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) => index >= pages.length
            ? _chapterEndPage()
            : _pagedItem(pages[index], index),
      );
    }
    // Double-page landscape: each PageView page is a spread. `onPageChanged`
    // still maps the spread index back to a real page (see there).
    return PageView.builder(
      key: const ValueKey('manga-pageview'),
      controller: _pageController,
      reverse: direction == 'rtl',
      itemCount: spreads.length + extra,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) => index >= spreads.length
          ? _chapterEndPage()
          : _spreadItem(spreads[index], pages),
    );
  }

  /// Full-screen end-of-chapter page, same card the webtoon strip ends with.
  Widget _chapterEndPage() =>
      Center(child: SingleChildScrollView(child: _chapterEndFooter()));

  /// One PageView page in double-page mode: a lone page renders exactly like
  /// the single-page path, a two-page spread lays the two page images side by
  /// side. Reusing [_pagedItem] per side keeps each page's own fit, pinch-zoom,
  /// RepaintBoundary, decode width and tap zones (a tap still turns a whole
  /// spread — the tap advances the PageController one page, i.e. one spread).
  Widget _spreadItem(List<int> spread, List<PageImage> pages) {
    if (spread.length == 1) {
      return _pagedItem(pages[spread.first], spread.first);
    }
    return Row(
      children: [
        for (final i in spread) Expanded(child: _pagedItem(pages[i], i)),
      ],
    );
  }

  /// Conservative border crop for the `cropBorders` pref. Overflow-scales the
  /// page a few percent and clips back to its box, shaving the outer margin a
  /// typical scan leaves without pixel analysis.
  // ponytail: content-aware crop deferred (needs pixel analysis) — this is a
  // fixed ~3%-per-edge inset, tuned to trim margins without eating art.
  Widget _cropIfEnabled(Widget image) {
    if (!sl<ReaderPrefs>().cropBorders) return image;
    return ClipRect(child: Transform.scale(scale: 1.06, child: image));
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
                GestureRecognizerFactoryWithHandlers<_TwoFingerScaleRecognizer>(
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
              physics: _wZooming ? const NeverScrollableScrollPhysics() : null,
              itemCount: pages.length,
              // The end-of-chapter footer rides along INSIDE the last item
              // rather than being an extra one. itemCount stays == pages.length
              // so `estimateIndexFromScroll`'s scroll-to-page mapping (and the
              // slider that shares it) needs no adjustment for a phantom page.
              itemBuilder: (context, index) {
                final page = _verticalItem(context, pages[index]);
                if (index != pages.length - 1) return page;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [page, _chapterEndFooter()],
                );
              },
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
            onTapUp: (d) => _dispatchTap(d.globalPosition),
            onDoubleTapDown: (d) => _lastDoubleTapPos = d.localPosition,
            onDoubleTap: () => _toggleZoom(ctrl),
            onLongPress: () => _showPageActions(page),
            child: InteractiveViewer(
              transformationController: ctrl,
              minScale: 1.0,
              maxScale: 4.0,
              child: Center(
                child: _cropIfEnabled(
                  _isLocal(page.url)
                      ? Image(
                          image: _pageProvider(page, width),
                          fit: _pageBoxFit(_effectiveFit(sl<ReaderPrefs>())),
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white24,
                          ),
                        )
                      : CachedNetworkImage(
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
            ),
          );
        },
      ),
    );
  }

  /// Webtoon mode has its own zones: top and bottom scroll a screenful, the
  /// middle opens the controls. There are no pages to turn in a continuous
  /// strip, so tapping used to do nothing here but toggle chrome.
  Widget _verticalItem(BuildContext context, PageImage page) {
    final width = _decodeWidth(context);
    // See the comment on _pagedItem's RepaintBoundary — same reasoning here.
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _dispatchTap(d.globalPosition),
        onLongPress: () => _showPageActions(page),
        child: _cropIfEnabled(
          _isLocal(page.url)
              ? Image(
                  image: _pageProvider(page, width),
                  width: double.infinity,
                  fit: _verticalBoxFit(_effectiveFit(sl<ReaderPrefs>())),
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 200,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white24,
                    ),
                  ),
                )
              : CachedNetworkImage(
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
      ),
    );
  }

  /// End-of-chapter card, shown under the last page of the webtoon strip.
  ///
  /// Part of the scrolling content rather than floating over it, so it can
  /// never sit on top of the art. Reading the last page now ends the way it
  /// should: the page finishes, then the card, then a pull opens the next
  /// chapter — the three line up instead of overlapping.
  Widget _chapterEndFooter() {
    final hasNext = _index < _chapters.length - 1;
    final next = hasNext ? _chapterLabel(_index + 1) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 44),
      child: Column(
        children: [
          Text(
            'End of ${_chapterLabel(_index) ?? 'this chapter'}',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
          if (hasNext) ...[
            const SizedBox(height: 12),
            ReaderPillSurface(
              radius: 22,
              onTap: () => _goToChapter(_index + 1),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      next ?? context.l10n.nextChapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 17,
                    color: AppColors.accent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.orKeepPulling,
              style: AppText.caption.copyWith(
                color: AppColors.textSecondary.withValues(alpha: 0.7),
                fontSize: 10.5,
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                context.l10n.thatSTheLastChapter,
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
        ],
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
                context.l10n.retry,
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
          // Floating pills, no scrim: back · title (tap for chapters) ·
          // settings. The settings button moved up here from the bottom row,
          // which the bottom pill needed the width for.
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ReaderPillIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: context.l10n.back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: ValueListenableBuilder<int>(
                      valueListenable: _pageIndexVN,
                      builder: (context, pageIndex, _) => ReaderTitlePill(
                        title: widget.showTitle,
                        subtitle: pages == null || pages.isEmpty
                            ? 'Chapter ${_index + 1} / ${_chapters.length}'
                            : 'ch ${_index + 1} · pg ${pageIndex + 1}/${pages.length}',
                        onTap: _openChapterSheet,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  ReaderPillIconButton(
                    icon: Icons.more_vert_rounded,
                    tooltip: context.l10n.readerSettings,
                    onTap: _openSettingsSheet,
                  ),
                ],
              ),
            ),
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
          // One floating pill: prev chapter · page slider · next chapter.
          // The page counter that used to flank the slider now lives in the
          // title pill's subtitle, so the numbers aren't lost.
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: ReaderBottomPill(
                children: [
                  readerBarButton(
                    Icons.skip_previous_rounded,
                    () => _goToChapter(_index - 1),
                    enabled: hasPrev,
                  ),
                  Expanded(
                    // A chapter with one page has nothing to scrub, so the
                    // slider is replaced by empty space rather than a dead
                    // control pinned at both ends.
                    child: pageCount > 1
                        ? ValueListenableBuilder<int>(
                            valueListenable: _pageIndexVN,
                            builder: (context, pageIndex, _) => ReaderSlider(
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
                          )
                        : const SizedBox(height: 40),
                  ),
                  readerBarButton(
                    Icons.skip_next_rounded,
                    () => _goToChapter(_index + 1),
                    enabled: hasNext,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Start/stop hands-free reading. Works in every mode: the webtoon strip
  /// creeps, the paged views turn a page every so often — a mode where the
  /// feature simply doesn't exist is what made the first attempt feel broken.
  void _setAutoScroll(bool on) {
    final prefs = sl<ReaderPrefs>();
    _autoScroll.speed = prefs.autoScrollSpeed;
    if (!on) {
      _autoScroll.stop();
      return;
    }
    if (_effectiveDirection(prefs) == 'vertical') {
      if (!_verticalController.hasClients) return;
      _autoScroll.start(controller: _verticalController);
    } else {
      _autoScroll.start(
        advancePage: () => _pageController.nextPage(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        ),
      );
    }
    if (_chromeVisible) setState(() => _chromeVisible = false);
  }

  void _openAutoScrollSheet() {
    final prefs = sl<ReaderPrefs>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ReaderAutoScrollSheet(
        running: _autoScroll.running.value,
        speed: prefs.autoScrollSpeed,
        showButton: prefs.autoScrollButton,
        onToggle: _setAutoScroll,
        onSpeed: (v) {
          prefs.setAutoScrollSpeed(v);
          _autoScroll.speed = v; // live while running
        },
        onShowButton: (v) {
          prefs.setAutoScrollButton(v);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  /// Chapter list, opened by tapping the title pill. Jumping goes through the
  /// same [_goToChapter] the prev/next buttons use, so progress is saved and
  /// the chapter marked read on the way out exactly as it always was.
  ///
  /// Opens scrolled to the current chapter: these lists run to hundreds of
  /// entries, and landing at the top would mean scrolling to find where you
  /// already are.
  void _openChapterSheet() {
    // A resume opened with a one-chapter placeholder hasn't widened yet (see
    // _maybeResolveChapters) — a sheet listing only the chapter you're on is
    // a dead end, so say so instead of opening it.
    if (_chapters.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.noOtherChaptersLoadedYet)),
      );
      return;
    }
    const rowHeight = 52.0;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      // Not readerSheetBody: that wraps its children in a SingleChildScrollView,
      // and a lazy ListView inside one has no bounded height — it would try to
      // build all 100+ rows at once. Same grabber and title, own scrolling.
      builder: (ctx) => ReaderSheetShell(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(0, 8, 0, 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 2),
                child: Text(context.l10n.chapters, style: AppText.headline),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  '${_index + 1} of ${_chapters.length}',
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              // Capped at half the screen: a long list would otherwise let the
              // shrink-wrapped ListView grow the sheet to full height, which
              // reads as a new page rather than a sheet over the reader.
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    controller: ScrollController(
                      // Centre-ish rather than pinned to the top edge, so the
                      // chapters either side are visible too.
                      initialScrollOffset: ((_index - 2) * rowHeight).clamp(
                        0,
                        double.infinity,
                      ),
                    ),
                    itemCount: _chapters.length,
                    itemExtent: rowHeight,
                    itemBuilder: (context, i) {
                      final current = i == _index;
                      return InkWell(
                        onTap: () {
                          Navigator.of(ctx).pop();
                          if (i != _index) _goToChapter(i);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 46,
                                child: Text(
                                  '${i + 1}',
                                  style: AppText.caption.copyWith(
                                    color: current
                                        ? AppColors.accent
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  _chapters[i].title.trim().isNotEmpty
                                      ? _chapters[i].title
                                      : 'Chapter ${i + 1}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.body.copyWith(
                                    color: current
                                        ? AppColors.accent
                                        : Colors.white,
                                    fontWeight: current
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (current)
                                Icon(
                                  Icons.play_arrow_rounded,
                                  size: 18,
                                  color: AppColors.accent,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// True for a saved page — those come back from the repository as a file
  /// path, not a URL, and CachedNetworkImage can't load one.
  static bool _isLocal(String url) => !url.startsWith('http');

  /// The image for a page: inside a saved `.cbz`, a loose saved file, or the
  /// network. One place, so the two page builders and the webtoon probe can't
  /// disagree about what they're loading.
  static ImageProvider _pageProvider(PageImage page, int width) {
    final cbz = CbzImage.tryParse(page.url);
    if (cbz != null) return ResizeImage.resizeIfNeeded(width, null, cbz);
    return _isLocal(page.url)
      ? ResizeImage.resizeIfNeeded(width, null, FileImage(File(page.url)))
      : ResizeImage.resizeIfNeeded(
          width,
          null,
          CachedNetworkImageProvider(
            page.url,
            headers: page.headers,
            maxWidth: width,
          ),
        );
  }

  /// Direction/Fit/Background/Filter/Comfort, live-applied — mirrors the
  /// shape of NovelReaderScreen's settings sheet (StatefulBuilder + an
  /// `apply` helper that writes to prefs and rebuilds both the sheet and the
  /// reader). Every row is built from reader_chrome.dart's shared
  /// readerSheetRow/ReaderSegmentedControl/readerSheetGroup pieces, so this
  /// sheet, the novel reader's, and Settings -> Reader all read as one
  /// design instead of three different layouts.
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

          // 'default' is a sentinel segment, not a real direction/fit value —
          // picking it clears the per-series override (same
          // setModeOverride/setFitOverride(..., null) the old null-chip did).
          final directionOptions = <({String value, String label})>[
            (value: 'default', label: context.l10n.defaultLabel),
            for (final d in const ['ltr', 'rtl', 'vertical'])
              (value: d, label: _directionLabel(d)),
          ];
          final fitOptions = <({String value, String label})>[
            (value: 'default', label: context.l10n.defaultLabel),
            for (final f in const [
              'contain',
              'width',
              'height',
              'original',
              'smart',
            ])
              (value: f, label: _fitLabel(f)),
          ];
          final backgroundOptions = <({String value, String label})>[
            for (final b in const ['black', 'white', 'gray', 'system'])
              (value: b, label: _backgroundLabel(b)),
          ];
          final filterOptions = <({String value, String label})>[
            for (final f in const ['none', 'grayscale', 'invert', 'sepia'])
              (value: f, label: _filterLabel(f)),
          ];

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
                        Text(context.l10n.readerSettings, style: AppText.headline),
                        readerSheetSection(context.l10n.statusReading),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.swap_horiz_rounded,
                            label: context.l10n.direction,
                            trailing: modeOverride != null
                                ? readerOverrideTag(context)
                                : null,
                            child: ReaderSegmentedControl(
                              options: directionOptions,
                              selected: modeOverride ?? 'default',
                              onSelect: (v) => apply(() {
                                overrides?.setModeOverride(
                                  widget.sourceId,
                                  widget.showId,
                                  v == 'default' ? null : v,
                                );
                                _syncControllersAfterDirectionChange();
                              }),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.view_day_outlined,
                            label: context.l10n.autoWebtoonMode,
                            trailing: Switch(
                              value: prefs.autoWebtoon,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setAutoWebtoon(v);
                                _detectWebtoon(); // no-op once off
                                _syncControllersAfterDirectionChange();
                              }),
                            ),
                          ),
                        ]),
                        readerSheetSection(context.l10n.display),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.fit_screen_outlined,
                            label: context.l10n.fit,
                            trailing: fitOverride != null
                                ? readerOverrideTag(context)
                                : null,
                            child: ReaderSegmentedControl(
                              options: fitOptions,
                              selected: fitOverride ?? 'default',
                              onSelect: (v) => apply(
                                () => overrides?.setFitOverride(
                                  widget.sourceId,
                                  widget.showId,
                                  v == 'default' ? null : v,
                                ),
                              ),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.palette_outlined,
                            label: context.l10n.background,
                            child: ReaderSegmentedControl(
                              options: backgroundOptions,
                              selected: prefs.mangaBackground,
                              onSelect: (v) =>
                                  apply(() => prefs.setMangaBackground(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.tune_rounded,
                            label: context.l10n.filter,
                            child: ReaderSegmentedControl(
                              options: filterOptions,
                              selected: prefs.colorFilter,
                              onSelect: (v) =>
                                  apply(() => prefs.setColorFilter(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.auto_stories_outlined,
                            label: context.l10n.doublePageLandscape,
                            trailing: Switch(
                              value: prefs.doublePageLandscape,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setDoublePageLandscape(v);
                                // itemCount flips page-count↔spread-count under
                                // the same controller — re-anchor on the page
                                // we're already reading.
                                _syncControllersAfterDirectionChange();
                              }),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.crop_outlined,
                            label: context.l10n.cropBorders,
                            trailing: Switch(
                              value: prefs.cropBorders,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setCropBorders(v)),
                            ),
                          ),
                        ]),
                        readerSheetSection('Navigation'),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.swipe_vertical_rounded,
                            label: context.l10n.pullToChangeChapter,
                            trailing: Switch(
                              value: prefs.overscrollChapter,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setOverscrollChapter(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.play_circle_outline_rounded,
                            label: context.l10n.autoScroll,
                            trailing: Icon(
                              Icons.chevron_right_rounded,
                              color: AppColors.textSecondary,
                              size: 20,
                            ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _openAutoScrollSheet();
                            },
                          ),
                          readerSheetRow(
                            icon: Icons.volume_up_rounded,
                            label: context.l10n.volumeKeysTurnPages,
                            trailing: Switch(
                              value: prefs.volumeKeyPaging,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setVolumeKeyPaging(v);
                                _syncVolumeKeys();
                              }),
                            ),
                          ),
                          // Only worth showing once the keys actually do
                          // something — a lone "invert" switch above a feature
                          // that's off reads as broken.
                          if (prefs.volumeKeyPaging)
                            readerSheetRow(
                              icon: Icons.swap_vert_rounded,
                              label: context.l10n.invertVolumeKeys,
                              trailing: Switch(
                                value: prefs.invertVolumeKeys,
                                activeThumbColor: AppColors.accent,
                                onChanged: (v) =>
                                    apply(() => prefs.setInvertVolumeKeys(v)),
                              ),
                            ),
                        ]),
                        readerSheetSection('Comfort'),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.visibility_outlined,
                            label: context.l10n.keepScreenOn,
                            trailing: Switch(
                              value: prefs.keepScreenOn,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setKeepScreenOn(v);
                                applyReaderComfort();
                              }),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.brightness_6_rounded,
                            label: context.l10n.brightness,
                            trailing: _systemBrightnessTag(
                              prefs.brightness < 0,
                              () => apply(() {
                                prefs.setBrightness(-1.0);
                                applyReaderComfort();
                              }),
                            ),
                            child: Slider(
                              value: prefs.brightness.clamp(-1.0, 1.0),
                              min: -1.0,
                              max: 1.0,
                              activeColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setBrightness(v);
                                applyReaderComfort();
                              }),
                            ),
                          ),
                        ]),
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
    'vertical' => context.l10n.vertical,
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
    'white' => context.l10n.colourWhite,
    'gray' => 'Gray',
    'system' => context.l10n.theme,
    _ => context.l10n.colourBlack,
  };

  String _filterLabel(String f) => switch (f) {
    'grayscale' => 'Grayscale',
    'invert' => 'Invert',
    'sepia' => 'Sepia',
    _ => context.l10n.subtitleOutlineNone,
  };

  /// Small tappable pill next to the Brightness row — jumps straight to the
  /// OS-managed brightness. Calls the exact same `setBrightness(-1.0)` +
  /// `applyReaderComfort()` pair the old inline context.l10n.system chip did; only the
  /// styling moved (from a chip in the row to a tag beside its label).
  Widget _systemBrightnessTag(bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? AppColors.accent : AppColors.hairline,
          ),
        ),
        child: Text(
          context.l10n.system,
          style: AppText.caption.copyWith(
            color: active ? AppColors.accent : AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// Long-press on a page — a small sheet offering Save/Share. Both actions
  /// read the page's bytes from the disk cache the visible `CachedNetworkImage`
  /// already populated (`DefaultCacheManager().getSingleFile`, with the
  /// page's own CF headers so a protected source resolves the same way the
  /// reader itself does) rather than issuing a second download.
  Future<void> _showPageActions(PageImage page) async {
    final action = await showModalBottomSheet<_PageAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ReaderSheetShell(
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                _pageActionRow(
                  Icons.download_rounded,
                  'Save to gallery',
                  () => Navigator.pop(ctx, _PageAction.save),
                ),
                _pageActionRow(
                  Icons.ios_share_rounded,
                  context.l10n.share,
                  () => Navigator.pop(ctx, _PageAction.share),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (action == null) return;
    switch (action) {
      case _PageAction.save:
        await _savePage(page);
      case _PageAction.share:
        await _sharePage(page);
    }
  }

  Widget _pageActionRow(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, color: AppColors.textPrimary, size: 22),
            const SizedBox(width: 16),
            Text(label, style: AppText.body),
          ],
        ),
      ),
    );
  }

  /// Saves the page to the device gallery — same `gal` call/retry shape as
  /// the player's own screenshot save (`player_controller.dart`'s
  /// `captureScreenshot`): try the write, and only request the runtime
  /// permission on the older-Android/iOS path where it throws.
  Future<void> _savePage(PageImage page) async {
    try {
      final file = await DefaultCacheManager().getSingleFile(
        page.url,
        headers: page.headers ?? const {},
      );
      final bytes = await file.readAsBytes();
      final name = 'Zangetsu_${DateTime.now().millisecondsSinceEpoch}';
      try {
        await Gal.putImageBytes(bytes, name: name);
      } on GalException {
        await Gal.requestAccess();
        await Gal.putImageBytes(bytes, name: name);
      }
      _toast('Saved to gallery');
    } catch (_) {
      _toast('Save failed');
    }
  }

  Future<void> _sharePage(PageImage page) async {
    try {
      final file = await DefaultCacheManager().getSingleFile(
        page.url,
        headers: page.headers ?? const {},
      );
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {
      _toast('Share failed');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Save-or-share choice from [_MangaReaderScreenState._showPageActions].
enum _PageAction { save, share }

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
