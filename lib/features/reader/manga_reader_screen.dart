import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/reading/reader_image_budget.dart';
import '../../core/reading/crop_borders.dart';
import '../../core/reading/reader_page_queue.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:visibility_detector/visibility_detector.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/di/injector.dart';
import '../../core/error/exceptions.dart';
import '../../core/models/episode.dart';
import '../../core/reading/chapter_nav.dart';
import '../../core/ui/native_page_provider.dart';
import '../../core/download/cbz_image.dart';
import '../../core/models/page_content.dart';
import '../../core/models/provider_info.dart';
import '../../core/reading/page_file_cache.dart';
import '../../core/reading/read_history.dart';
import '../../core/reading/read_store.dart';
import '../../core/ui/app_toast.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/reading/reader_overrides.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/reading/tap_zones.dart';
import '../../core/reading/reader_settings.dart';
import '../../core/reading/tiles/tile_decoder.dart';
import '../../core/reading/tiles/tiled_page_image.dart';
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

/// How long a page takes to fade in once its image lands. Short on purpose:
/// this plays while someone is still scrolling, and the package's 500ms
/// default is long enough to look like the page is struggling.
const Duration _kPageFade = Duration(milliseconds: 220);

class _MangaReaderScreenState extends State<MangaReaderScreen>
    with ReaderComfortMixin<MangaReaderScreen>, TickerProviderStateMixin {
  /// Hands-free scrolling — webtoon only; paged modes step whole pages and
  /// have nothing to creep.
  late final ReaderAutoScroll _autoScroll;
  final GlobalKey _menuButtonKey = GlobalKey();
  late int _index; // chapter index
  // Mutable so a Continue Reading resume (opened with just the one chapter)
  // can widen to the show's full list in the background — see
  // `_maybeResolveChapters`. Every read of the chapter list goes through
  // this, never `widget.chapters` directly.
  late List<Episode> _chapters = widget.chapters;
  late final PageController _pageController;
  late final ScrollController _verticalController;

  /// The page the webtoon strip is CENTRED on — scroll offset 0 is its top.
  ///
  /// The strip is built as two slivers around it: the pages above, laid out
  /// upward into negative offsets, and this page onward laid out downward.
  /// That is what makes resuming exact. The old code jumped to
  /// `index / pageCount * maxScrollExtent`, a percentage of a height built
  /// from pages that had not loaded yet — so page 31 of 112 landed 28% down
  /// the strip and drifted further as the real heights arrived. Anchoring
  /// instead means a page above changing height extends the strip upward and
  /// cannot move what you are reading.
  int _anchorIndex = 0;

  /// Marks the centre sliver. Rebuilt with [_anchorIndex] so a seek re-centres
  /// rather than trying to compute where the page lives in pixels.
  Key _centerKey = const ValueKey('manga-center-0');

  bool _loading = true;
  String? _error;

  /// Every page currently in the strip — which, once you read past the end of
  /// a chapter, spans MORE THAN ONE chapter. [_slots] says which.
  List<PageImage>? _pages;

  /// Parallel to [_pages]: where each page came from. This is what lets one
  /// flat strip hold several chapters, so reading into the next one is just
  /// scrolling rather than tearing the reader down and building it again.
  final List<_PageSlot> _slots = [];

  /// Chapter indices already in the strip, in the order they were appended.
  final List<int> _stripChapters = [];

  /// One page at a time, nearest first. See [ReaderPageQueue].
  late final ReaderPageQueue _pageQueue;

  /// Resolves a page to a real on-disk file, for tiled decoding. See
  /// [PageFileCache].
  late final PageFileCache _pageFiles;

  /// Decodes tile-sized crops of a page file. See [TileDecoder].
  late final TileDecoder _tileDecoder;

  /// What the queue should actually do for a given page url.
  final Map<String, Future<void> Function()> _queueTasks = {};

  /// True while the next chapter is being fetched for the strip's tail.
  bool _appending = false;

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

  /// False for the moment between a chapter's pages arriving and the strip
  /// actually having laid out. See [_buildBody] for what it hides.
  bool _stripReady = true;
  Timer? _stripReadyTimer;

  /// Fires once scrolling has actually stopped, to move the anchor onto the
  /// page being read. See [_reanchorToCurrentPage].
  Offset? _lastDoubleTapPos;
  final Map<int, TransformationController> _zoomControllers = {};

  // Webtoon (vertical) pinch-zoom. The strip stays a lazy ListView for
  // one-finger scrolling; a two-finger pinch drives this scale/offset which a
  // Transform applies over the whole list. See _buildVertical.
  double _wScale = 1.0; // current strip scale, clamped [1, 4]

  /// ONE controller drives every page placeholder, so a screenful of them
  /// pulses together and costs a single ticker — same convention as
  /// `states.dart`'s skeleton grid.
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
    // keepScrollOffset:false — the strip's position is OURS to set, via the
    // anchor. Left on (the default), Flutter stashes the offset in
    // PageStorage under the list's key and restores it when the strip is
    // rebuilt for the next chapter — so tapping "next" opened the new chapter
    // at the old one's offset, i.e. at the bottom, showing its end-of-chapter
    // card over a screen of pages that hadn't loaded.
    _pageQueue = ReaderPageQueue(
      fetch: (key) async =>
          await (_queueTasks.remove(key)?.call() ?? Future.value()),
    );
    _pageFiles = PageFileCache();
    _tileDecoder = TileDecoder();
    _verticalController = ScrollController(keepScrollOffset: false)
      ..addListener(_onVerticalScroll);
    // Wakelock/brightness/orientation — see ReaderComfortMixin. Best-effort:
    // a plugin-channel failure (e.g. an unusual device, or — in widget tests
    // — no host handler at all) must not crash the reader; the mixin itself
    // swallows that.
    applyReaderComfort();
    _syncVolumeKeys();
    // A manga page dwarfs the covers the app-wide 80MB budget was sized for;
    // measured mid-scroll the cache sat pinned at 79.4/80MB, evicting a page
    // for every page it took in. Raised for as long as a chapter is open.
    unawaited(ReaderImageBudget.acquire());
    // One-way loop: the highlight travels down the page and starts again.
    // reverse:true would walk it back up, which reads as a glitch.
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
    ReaderImageBudget.release(); // hands the page bitmaps back to the OS
    _captureFinalVerticalIndex();
    _flushProgress(); // reader close: don't lose the last-read position
    _autoScroll.dispose();
    VolumeKeys.disable(); // give the volume rocker back
    restoreReaderComfort();
    _pageQueue.dispose();
    unawaited(_tileDecoder.dispose());
    _stripReadyTimer?.cancel();
    _aspectFlush?.cancel();
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

  /// Where next/prev actually go. A multi-group source lists every group's
  /// release in one flat list, so stepping by row lands on the SAME chapter
  /// from another group — see [adjacentChapterIndex].
  int? get _nextIndex => adjacentChapterIndex(_chapters, _index, step: 1);
  int? get _prevIndex => adjacentChapterIndex(_chapters, _index, step: -1);

  /// The chapter after everything currently in the strip — what an overscroll
  /// at the bottom should reach for.
  int? get _afterStrip => _stripChapters.isEmpty
      ? _nextIndex
      : adjacentChapterIndex(_chapters, _stripChapters.last, step: 1);

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
      final pages = await _fetchPages();
      if (!mounted) return;
      final saved = sl<ReadStore>().get(
        widget.sourceId,
        widget.showId,
        _chapter.id,
      );
      var start = clampPageIndex(saved?.pos ?? 0, pages.length);
      // Reopening a chapter you read to the end used to drop you straight onto
      // the end-of-chapter card, because that IS the saved position and the
      // card rides inside the last page. Useless place to land: nothing above
      // it you haven't read, nothing below it but a button.
      //
      // Vertical only. The card lives in the webtoon strip, so in paged mode
      // the last page is just a page and resuming onto it is exactly right.
      if (start == pages.length - 1 &&
          pages.length > 1 &&
          _effectiveDirection(sl<ReaderPrefs>()) == 'vertical') {
        start = 0;
      }
      setState(() {
        _pages = pages;
        _slots
          ..clear()
          ..addAll([
            for (var i = 0; i < pages.length; i++)
              _PageSlot(_index, i, pages.length),
          ]);
        _stripChapters
          ..clear()
          ..add(_index);
        _pageIndex = start;
        _loading = false;
      });
      _armStripReady();
      _preload(start, pages);
      _restoreControllerPositions(start, pages.length);
      _detectWebtoon();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = kChapterLoadFailedMessage;
        _loading = false;
      });
    }
  }

  /// The chapter's pages, retrying once before giving up.
  ///
  /// The failure this recovers from is transient — a source hiccup, a dropped
  /// request — and opening the same chapter a second time is what worked every
  /// time this was hit by hand. Showing a Retry button for something the app
  /// can do itself just moves the problem onto the reader.
  ///
  /// Deliberately different from Mihon and the other readers, which show the
  /// button and leave it there. The cost is one extra request against a source
  /// that is genuinely down; the gain is that the common case fixes itself.
  ///
  /// A Cloudflare challenge is NOT retried: it needs a person to solve it, and
  /// asking again immediately only wastes their time.
  Future<List<PageImage>> _fetchPages() async {
    for (var attempt = 1; attempt <= _loadAttempts; attempt++) {
      try {
        final pages = await sl<SourceRepository>().pages(
          _chapter.url,
          sourceId: widget.sourceId,
        );
        if (pages.isNotEmpty || attempt == _loadAttempts) return pages;
        // An empty list from a chapter that plainly has pages is the same
        // transient failure wearing a different hat — worth one more go.
      } on CloudflareRequiredException {
        rethrow;
      } catch (_) {
        if (attempt == _loadAttempts) rethrow;
      }
      if (!mounted) return const [];
      await Future<void>.delayed(_retryDelay);
      if (!mounted) return const [];
    }
    // Unreachable: the last attempt either returns or rethrows.
    return const [];
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
      if (pageCount > 1) _anchorToPage(start);
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
    if (_measuredFirstPage) return; // one resolve per chapter
    // The measurement is taken even with auto-webtoon off. It is the only
    // honest page shape available before anything renders, and the whole list
    // is sized from it — a chapter of unloaded pages reserving a guess is how
    // the list ends up half its real length. Only the DIRECTION decision below
    // is gated on the pref.
    _measuredFirstPage = true;
    final first = pages.first;
    final width = _decodeWidth(context);
    final stream = _pageProvider(
      first,
      width,
    ).resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final aspect = info.image.height / info.image.width;
      final tall = aspect >= _webtoonAspect;
      info.dispose(); // only the size was wanted, not a retained decode
      if (!mounted) return;
      // Every page not yet seen reserves this. A webtoon slice runs 3x its
      // width or more, against the 1.45 a print page sits at — reserving the
      // wrong one shortens the list by half, and a fast scroll then reaches a
      // "bottom" that is nowhere near the end of the chapter.
      setState(() => _chapterAspect = aspect);
      if (!sl<ReaderPrefs>().autoWebtoon) return;
      if (_looksLikeWebtoon == tall) return;
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

  /// Decode width for a page in the WEBTOON strip — see [webtoonZoomHeadroom].
  ///
  /// Tracks the live pinch, so an un-zoomed strip keeps a dozen cheap pages
  /// resident and a zoomed one re-resolves the pages on screen at the
  /// resolution actually being displayed. Settling on [_wScale] AFTER the
  /// gesture ends is deliberate: re-decoding mid-pinch would fight the
  /// gesture for the same frames.
  int _webtoonDecodeWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    final device = (mq.size.width * mq.devicePixelRatio).round();
    return readerDecodeWidth(
      device,
      zoomHeadroom: webtoonZoomHeadroom(_wZooming ? 1.0 : _wScale),
    );
  }

  void _preload(int index, List<PageImage> pages) {
    // The SAME width the list will ask for, or the page is fetched and decoded
    // twice under two different cache keys — paying double and warming neither.
    // Keyed off the direction actually being rendered, not the auto-webtoon
    // guess: an explicit 'vertical' override renders the strip too.
    final width = _effectiveDirection(sl<ReaderPrefs>()) == 'vertical'
        ? _webtoonDecodeWidth(context)
        : _decodeWidth(context);
    final window = preloadWindow(
      index,
      pages.length,
      count: sl<ReaderPrefs>().preloadCount,
    );

    // Through the queue, one at a time, nearest first — NOT all at once.
    //
    // Firing the whole window in parallel let the network decide what arrived
    // first, so pages appeared in a scatter rather than top to bottom, and on
    // a rate-limited source (measured at 8-19s per request) the page actually
    // on screen could finish LAST, behind four nobody had reached yet.
    //
    // The visible page goes in at [PagePriority.current] so it always wins;
    // the rest queue behind it in reading order. Anything still waiting that
    // the reader has since scrolled away from is dropped.
    final keep = <String>{for (final i in window) pages[i].url};
    _pageQueue.keepOnly(keep);
    for (final i in window) {
      final p = pages[i];
      _pageQueue.add(
        p.url,
        i == index ? PagePriority.current : PagePriority.adjacent,
      );
      _queueTasks[p.url] = () => _fetchPageBytes(p, i, width);
    }
    _warmNextChapter(index, pages.length);
    // Within a couple of pages of the strip's end — pull the next chapter on.
    if (sl<ReaderPrefs>().overscrollChapter && index >= pages.length - 2) {
      unawaited(_appendNextChapter());
    }
  }

  /// Moves [_index] onto the chapter the reader has actually scrolled into.
  ///
  /// Without this, reading on past a chapter boundary leaves the reader still
  /// "in" the old chapter: next/prev would skip one, the chapter sheet would
  /// highlight the wrong row, and the comfort of continuous scrolling would
  /// come with a reader that had lost track of where you are.
  void _followChapter(int stripIndex) {
    final c = _slotAt(stripIndex)?.chapterIdx;
    if (c == null || c == _index || c < 0 || c >= _chapters.length) return;
    setState(() => _index = c);
    _warmedNext = false; // the next chapter to warm is a different one now
  }

  /// Pulls the next chapter onto the END of the strip, so reading past the
  /// last page of one chapter just carries on into the next.
  ///
  /// This is what replaces the chapter change for anyone who simply keeps
  /// scrolling: nothing is torn down, there is no loading screen, the anchor
  /// does not move, and the pages are already below you by the time you reach
  /// them. Tapping "next chapter" still does a real [_goToChapter] — that is a
  /// deliberate jump, and rebuilding for it is correct.
  ///
  /// Appending only ever adds BELOW the reading position, which is the one
  /// direction that cannot move what you are looking at.
  Future<void> _appendNextChapter() async {
    if (_appending || !mounted) return;
    final pages = _pages;
    if (pages == null || pages.isEmpty || _stripChapters.isEmpty) return;
    final after = adjacentChapterIndex(_chapters, _stripChapters.last, step: 1);
    if (after == null || _stripChapters.contains(after)) return;

    // Drives the spinner on the end card, so it has to rebuild.
    setState(() => _appending = true);
    try {
      final next = await sl<SourceRepository>().pages(
        _chapters[after].url,
        sourceId: widget.sourceId,
      );
      if (!mounted || next.isEmpty) return;
      // The strip may have been rebuilt underneath us — a chapter jump, a
      // reload — while the request was in the air. Identity is the check: a
      // rebuild always assigns a NEW list.
      if (!identical(_pages, pages) || _stripChapters.contains(after)) return;
      setState(() {
        _pages = [...pages, ...next];
        for (var i = 0; i < next.length; i++) {
          _slots.add(_PageSlot(after, i, next.length));
        }
        _stripChapters.add(after);
        // Everything added sits BELOW the reading position, so the anchor and
        // the scroll offset are untouched — no compensation needed.
      });
    } catch (_) {
      // A chapter that will not load is not an error here — you simply reach
      // the end card, which still offers the explicit jump.
    } finally {
      if (mounted) {
        setState(() => _appending = false);
      } else {
        _appending = false;
      }
    }
  }

  /// Fetches the NEXT chapter's page list once you're most of the way through
  /// this one, so tapping through opens on pages instead of a spinner.
  ///
  /// Two thirds in, not on the last page: by the time the footer is on screen
  /// the tap is already coming, and the request needs a head start to be worth
  /// making. One request per chapter read, and only for someone who has
  /// actually read most of it — so it never costs anything for a chapter that
  /// was opened and abandoned.
  void _warmNextChapter(int index, int pageCount) {
    if (_warmedNext || pageCount < 3) return;
    // Late on purpose. Sources rate-limit, and this request queues behind the
    // SAME limiter the current chapter's page images are waiting on — warming
    // early bought a faster chapter change at the cost of slower pages in the
    // chapter being read, which is the wrong trade.
    if (index < pageCount - 2) return;
    final next = _nextIndex;
    if (next == null) return;
    _warmedNext = true;
    unawaited(
      sl<SourceRepository>().warmPages(
        _chapters[next].url,
        sourceId: widget.sourceId,
      ),
    );
  }

  /// Downloads one page's bytes, and learns its shape on the way past.
  ///
  /// Deliberately NOT precacheImage. A page decodes to width x height x 4 —
  /// around 28MB at our decode width — so precaching even a few pushed the
  /// already-decoded ones straight back out of the image cache and the reader
  /// paid to decode them again on the way past. This is the same call
  /// CachedNetworkImage makes for maxWidthDiskCache, so the file lands under
  /// the key the visible page resolves to; only the page being looked at ends
  /// up decoded in memory.
  Future<void> _fetchPageBytes(PageImage p, int index, int width) async {
    // A tile crop needs a real file on disk, which most pages do not start
    // with — resolve one here, off the same preload pass that measures the
    // page, so it is ready by the time the page is built.
    if (!_pageFile.containsKey(p.url)) {
      final f = await _pageFiles.fileFor(p.url, p.headers);
      if (f != null && mounted) {
        _pageFile[p.url] = f.path;
        // Read the TRUE pixel size here rather than leaving it to the measure
        // paths below, because neither can supply it for every page kind: a
        // page the native side draws never reaches [_measureFromFile], and
        // [_measureFromProvider] only ever knows the size it decoded AT, not
        // the size the file really is. Getting that wrong means a tile crop
        // addressed in the wrong space — and a page cropped wrong is a visibly
        // broken page, not a slow one.
        await _recordPixelSize(f, p.url);
      }
    }
    // A page the NATIVE side draws must be measured from what the native side
    // draws — never from the url.
    //
    // These are the sources that serve their pages scrambled and reassemble
    // them in their own interceptor. Fetching the url from Dart gets the
    // scrambled bytes, whose dimensions need not match the reassembled page at
    // all; reserving a slot from those and then rendering the real one leaves
    // black space around it. It also downloads every page twice, once here and
    // once natively, for nothing.
    // Trimming borders means looking at the pixels, which the header-only
    // path below deliberately never does. Opting in to the crop is opting in
    // to that decode.
    if (_drawnLocally(p) || sl<ReaderPrefs>().cropBorders) {
      await _measureFromProvider(p, width);
      return;
    }
    final stream = DefaultCacheManager().getImageFile(
      p.url,
      headers: p.headers,
      maxWidth: width,
    );
    await for (final r in stream) {
      if (r is FileInfo) {
        // Shape read off the file BEFORE the page is ever built — see
        // [_measureFromFile] for why that matters so much here.
        if (!_aspect.containsKey(p.url)) {
          await _measureFromFile(r.file, p.url, index);
        }
        return;
      }
    }
  }

  /// Records a page's shape, and — when the reader is trimming borders — the
  /// part of it that is actually artwork.
  ///
  /// The aspect stored is the CROPPED one, so the slot reserved for the page
  /// is the size the page will really draw at. Storing the full aspect and
  /// then drawing a cropped image would just move the flat band from inside
  /// the picture to underneath it.
  Future<void> _recordShape(String url, ui.Image image, int w, int h) async {
    var aspect = h / w;
    if (sl<ReaderPrefs>().cropBorders) {
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final bytes = data?.buffer.asUint8List();
        if (bytes != null) {
          final r = findContentRect(bytes, w, h);
          final cw = r.right - r.left, ch = r.bottom - r.top;
          if (cw > 0 && ch > 0 && (cw != w || ch != h)) {
            _crop[url] = (x: r.left / w, y: r.top / h, w: cw / w, h: ch / h);
            aspect = ch / cw;
          }
        }
      } catch (_) {
        // Un-inspectable page: draw it whole, which is what used to happen.
      }
    }
    if (!mounted || _aspect.containsKey(url)) return;
    _aspect[url] = aspect;
    _flushAspects();
  }

  /// Resolves a natively-drawn page far enough to learn its real shape.
  ///
  /// This is the only honest measurement for a page whose bytes the extension
  /// rewrites — it asks the very provider that will draw it. It costs a decode,
  /// which is why it is only ever done for pages [_preload] was going to fetch
  /// anyway, and why [ReaderImageBudget] raises the image cache while a chapter
  /// is open.
  Future<void> _measureFromProvider(PageImage p, int width) async {
    if (!mounted || _aspect.containsKey(p.url)) return;
    final done = Completer<void>();
    final stream = _pageProvider(p, width).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width, h = info.image.height;
        if (mounted && w > 0 && h > 0 && !_aspect.containsKey(p.url)) {
          unawaited(_recordShape(p.url, info.image, w, h));
        }
        stream.removeListener(listener);
        if (!done.isCompleted) done.complete();
      },
      onError: (_, _) {
        stream.removeListener(listener);
        if (!done.isCompleted) done.complete();
      },
    );
    stream.addListener(listener);
    return done.future;
  }

  /// Reads a page's true shape out of the downloaded file's header, without
  /// decoding the image.
  ///
  /// This is the fix for manhwa. A comic page is about one screen tall, so a
  /// placeholder guessing wrong is a small correction. A manhwa page is
  /// SEVERAL screens tall — the guess reserves one screen, the real image
  /// wants five, and the page grows by thousands of pixels while you are
  /// standing inside it. Anchoring cannot save you there: the anchor pins the
  /// page's TOP, and everything you are reading is below that top, so it all
  /// slides down. Measured on device, a page finishing its decode moved the
  /// panel being read ~700px down the screen with no input at all.
  ///
  /// So the shape is learned from the bytes [_preload] has already fetched,
  /// one download ahead of where you are reading. By the time a page reaches
  /// the viewport its slot is already the right size and there is nothing left
  /// to correct. `ImageDescriptor` parses the header only — no full decode, no
  /// bitmap, nothing added to the image cache.
  /// Records a page's true pixel size, read header-only from the file
  /// [PageFileCache] resolved for it. Header-only on purpose: the point is to
  /// avoid decoding the page, so pulling the whole thing in to ask how big it
  /// is would defeat the feature it serves.
  Future<void> _recordPixelSize(File file, String url) async {
    if (_pixelSize.containsKey(url)) return;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? desc;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      desc = await ui.ImageDescriptor.encoded(buffer);
      final w = desc.width, h = desc.height;
      if (w <= 0 || h <= 0 || !mounted) return;
      _pixelSize[url] = Size(w.toDouble(), h.toDouble());
    } catch (_) {
      // Unreadable means no tiling for this page, which is the same as not
      // having a file at all — the plain path draws it.
    } finally {
      desc?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> _measureFromFile(File file, String url, int index) async {
    if (!mounted || _aspect.containsKey(url)) return;
    // ONLY pages below the one being read.
    //
    // Resizing a slot at or above the reading position pushes everything under
    // it down — that is the "it slides down while I'm reading" report, and it
    // is why the idle re-anchor alone was not enough: between stopping and the
    // anchor catching up, every page from the anchor down to you can still
    // shove you.
    //
    // Below the reading position there is nothing to shove: the strip simply
    // grows downward into space nobody is looking at. And because [_preload]
    // runs ahead, a page is measured while it is still below you and is the
    // right size by the time you arrive — so it never resizes under you at
    // all. Pages you have already passed keep their estimate, which costs
    // nothing but a slightly inexact scrollbar.
    if (index < _pageIndex) return;
    if (index == _pageIndex) {
      // The page you are standing in — allowed ONLY while you are at its very
      // top, where it can grow downward without moving anything on screen.
      // That is the chapter-open case, and skipping it cost a measured 316px
      // lurch the moment page one's image landed. Once you have scrolled into
      // the page its top is above you, and resizing it would shove the panel
      // you are reading.
      if (index != _anchorIndex || !_verticalController.hasClients) return;
      if (_verticalController.position.pixels > 0) return;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? desc;
    try {
      // fromFilePath, NOT readAsBytes + fromUint8List. The latter pulls the
      // whole page into the Dart heap and then copies it again — several MB
      // per page, on the UI isolate, while you are scrolling. This hands the
      // path to the engine and never materialises the bytes in Dart at all.
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      desc = await ui.ImageDescriptor.encoded(buffer);
      final w = desc.width, h = desc.height;
      if (w <= 0 || h <= 0 || !mounted) return;
      _aspect[url] = h / w;
      _pixelSize[url] = Size(w.toDouble(), h.toDouble());
      _flushAspects();
    } catch (_) {
      // An unreadable file is the image loader's problem, not ours — it will
      // show its own error. Leaving the aspect unset just means the old guess.
    } finally {
      desc?.dispose();
      buffer?.dispose();
    }
  }

  /// Batches newly-measured shapes into one rebuild.
  ///
  /// [_preload] fetches several pages at once, and calling setState per page
  /// would lay the strip out several times for one scroll — which is how an
  /// earlier attempt at measuring ahead ended up tripling scroll bounce.
  void _flushAspects() {
    if (_aspectFlush?.isActive ?? false) return;
    _aspectFlush = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      if (!_verticalController.hasClients) {
        setState(() {});
        return;
      }
      // Never while the finger is down or the fling is running. setState here
      // rebuilds every laid-out page, and doing that mid-scroll is a stutter
      // you can feel. These corrections only ever apply to pages BELOW the
      // reader, so nothing is lost by waiting for the scroll to settle.
      if (_verticalController.position.isScrollingNotifier.value) {
        _aspectFlush = Timer(
          const Duration(milliseconds: 250),
          () => _flushAspects(),
        );
        return;
      }
      // Hold `pixels` — NOT the distance from the top of the strip.
      //
      // Offset 0 is the anchor page's top, so a page ABOVE the anchor getting
      // its true height only pushes minScrollExtent further negative; at the
      // same `pixels` the anchor is still in the same place on screen and
      // nothing you are looking at moves. Restoring the distance-from-top
      // instead would faithfully re-apply every correction made above you,
      // which is precisely the shove this is here to stop.
      final pixels = _verticalController.position.pixels;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_verticalController.hasClients) return;
        final p = _verticalController.position;
        if ((p.pixels - pixels).abs() < 0.5) return;
        _verticalController.jumpTo(
          pixels.clamp(p.minScrollExtent, p.maxScrollExtent),
        );
      });
    });
  }

  Timer? _aspectFlush;

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

  /// index -> how much of that page is on screen, for the pages currently
  /// built. The webtoon page number used to be `pixels / maxExtent`, which
  /// assumes every page is the same height; they are not, so the counter
  /// stuck, jumped and skipped numbers and you could not tell whether you
  /// were reading in order. This is what is actually in front of you.
  final Map<int, double> _visible = {};

  /// Height/width of pages we've laid out, so a page that has been seen once
  /// reserves its real height on the way back. Keyed by index rather than url
  /// because the same url can legitimately repeat within a chapter.
  /// Measured page shapes, keyed by the page's URL — NOT by its index.
  ///
  /// Index keys were a bug: page 5 of this chapter and page 5 of the next one
  /// shared a key, so the map had to be thrown away on every chapter change
  /// and each chapter re-learned every height from scratch. Keyed by URL it
  /// can simply be kept, so a chapter you come back to reserves the right
  /// space on the first frame and nothing shifts as the images arrive.
  final Map<String, double> _aspect = {};

  /// True pixel size, for pages that may be tiled. [_aspect] keeps only the
  /// ratio, but a tile crop is addressed in the file's own pixels.
  final Map<String, Size> _pixelSize = {};

  /// The on-disk file backing a page, once [PageFileCache] has one. Tiling
  /// needs a file descriptor; most pages do not start with one.
  final Map<String, String> _pageFile = {};

  /// The part of a page that is actually artwork, as fractions of the whole,
  /// for pages whose flat margins are being trimmed. Empty when "crop borders"
  /// is off, and empty for any page we could not inspect.
  ///
  /// Kept beside [_aspect] because the two must agree: the height reserved for
  /// a page is derived from the CROPPED shape, so that trimming a margin makes
  /// the page shorter rather than leaving the same hole with the art moved up
  /// inside it.
  final Map<String, ({double x, double y, double w, double h})> _crop = {};

  /// The first page's real decoded aspect, used for every page not yet seen.
  /// Measured in [_detectWebtoon] from the decoded image — NOT from the laid
  /// out widget, which before an image arrives is the placeholder, whose
  /// height came from this value in the first place.
  double? _chapterAspect;

  /// One first-page resolve per chapter, whatever the auto-webtoon pref says.
  bool _measuredFirstPage = false;

  /// Set once the next chapter's page list has been asked for, so reading
  /// back and forth across the threshold doesn't re-request it. Cleared on
  /// every chapter change.
  bool _warmedNext = false;

  /// Pages whose image has actually drawn. A page still showing its
  /// placeholder has NOT been read, however far past it the list has scrolled.
  final Set<int> _loaded = {};

  void _onVerticalScroll() {
    final pages = _pages;
    if (pages == null || pages.isEmpty || !_verticalController.hasClients) {
      return;
    }
    final pos = _verticalController.position;
    // Bottom of the list is the last page, whatever the visibility says: the
    // end-of-chapter footer rides inside the last item, so the page above it
    // can still be the most visible one there — and a chapter that never
    // reaches its last index is never marked read, so it never scrobbles.
    final current =
        verticalPageIndex(
          atBottom: pos.pixels >= pos.maxScrollExtent - 8,
          lastPageLoaded: _loaded.contains(pages.length - 1),
          pageCount: pages.length,
          visible: _visible,
        ) ??
        _estimateOrKeep(pos, pages.length);
    if (current != _pageIndex) {
      _pageIndex = current; // notifier only — see _onPageChanged
      _followChapter(current);
      if (!_seeking) _preload(current, pages);
    }
    // Same reasoning as _onPageChanged: a slider drag also drives this via
    // ScrollController.jumpTo, and _commitSeek is the single source of
    // truth for the preload/save once the drag ends.
    if (_seeking) return;

    // Deliberately NO idle re-anchor here. Moving the anchor forward changes
    // what offset 0 means, so the frame after the rebuild renders at the old
    // offset — one page out — before the correction lands. That single bad
    // frame is a visible lurch, and measured on device it was a full page:
    //
    //   re-anchor jump: was=1961 want=-221 delta=-2182   (page height 2182)
    //
    // Its job — stopping a page above from shoving you — is done earlier and
    // better now: [_measureFromFile] and [_measureFromProvider] size a page
    // before you ever reach it, so it does not resize under you at all.

    // Throttle routine in-chapter saves to ~once/second, same as the novel
    // reader's scroll listener.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollSaveMs < 1000) return;
    _lastScrollSaveMs = now;
    _saveProgress(flush: false);
  }

  /// The scroll-derived page, or the one we already had when the strip has no
  /// extent to derive it FROM.
  ///
  /// On the first frame after a chapter loads, nothing has been laid out yet
  /// and maxScrollExtent is still 0 — and `estimateIndexFromScroll(0, 0, n)`
  /// answers `n - 1`, the LAST page (it is pinned that way by its own test, so
  /// a chapter scrolled to a zero-height bottom still counts as finished).
  ///
  /// Harmless when a scroll position was the source of truth. Not harmless now
  /// that the anchor follows `_pageIndex`: the reader took that answer, moved
  /// the anchor to the final page, and opened the chapter on its
  /// end-of-chapter card over a page that had not loaded — a black screen
  /// saying "End of Chapter 8" on page 1 of 36.
  int _estimateOrKeep(ScrollPosition pos, int pageCount) {
    final span = pos.maxScrollExtent - pos.minScrollExtent;
    if (span <= 0) return clampPageIndex(_pageIndex, pageCount);
    return estimateIndexFromScroll(
      pos.pixels - pos.minScrollExtent,
      span,
      pageCount,
    );
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
    _pageIndex =
        verticalPageIndex(
          atBottom: pos.pixels >= pos.maxScrollExtent - 8,
          lastPageLoaded: _loaded.contains(pages.length - 1),
          pageCount: pages.length,
          visible: _visible,
        ) ??
        _estimateOrKeep(pos, pages.length);
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
    // The strip can hold several chapters, so progress belongs to the chapter
    // under the reading position — NOT to the strip as a whole, and not to
    // whichever chapter happened to be opened first.
    final slot = _slotAt(_pageIndex) ?? _slotAt(pages.length - 1);
    if (slot == null) return;
    final ep = _chapters[slot.chapterIdx];
    final total = slot.chapterPages;
    final pos = complete ? total - 1 : slot.pageInChapter;
    sl<ReadStore>().save(
      widget.sourceId,
      widget.showId,
      ep.id,
      pos: pos,
      total: total,
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
        total: total,
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

  void _goToChapter(int? newIndex) {
    if (newIndex == null || newIndex < 0 || newIndex >= _chapters.length) {
      return;
    }
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
      // Shapes and visibility belong to the chapter that was open.
      _visible.clear();
      _loaded.clear();
      _chapterAspect = null;
      _measuredFirstPage = false;
      _error = null;
      _looksLikeWebtoon = null;
      _warmedNext = false;
      _pageIndex = 0;
      // Back to the top, or the next chapter opens centred on the page number
      // the last one was left on.
      _anchorIndex = 0;
      _centerKey = const ValueKey('manga-center-0');
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
    if (pages.length > 1) _anchorToPage(clamped);
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
      if (pages.length > 1) _anchorToPage(_pageIndex);
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
        _goToChapter(_nextIndex);
      case ReaderAction.prevChapter:
        _goToChapter(_prevIndex);
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
      final pos = _verticalController.position;
      final target = (_verticalController.offset + (forward ? page : -page))
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
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
  String? _chapterLabel(int? i) {
    if (i == null || i < 0 || i >= _chapters.length) return null;
    final t = _chapters[i].title.trim();
    return t.isNotEmpty ? t : 'Chapter ${chapterNumberLabel(_chapters, i)}';
  }

  Widget _buildBody(ReaderPrefs prefs) {
    if (_loading) {
      // A spinner and the chapter's name, and nothing else.
      //
      // This used to draw a full screen of shimmering page slots. The problem
      // was that they looked EXACTLY like the placeholder a real page shows
      // while its image downloads — so you couldn't tell "the chapter list is
      // still being fetched" from "page 3 is still coming", and the whole
      // thing read as one long loading screen you were never getting out of.
      //
      // The two states are now different on sight: a spinner means the chapter
      // hasn't arrived, a shimmering slot with a page number on it means that
      // page hasn't. Reopening a chapter usually skips this entirely now —
      // see SourceRepository's page-list cache.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleChrome,
        child: _ChapterLoadingBar(label: _chapterLabel(_index)),
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
      // A source answering with an EMPTY list isn't an exception, so this
      // never set _error and the reader drew an empty box: a black screen with
      // no message and no way out. Opening the same chapter again often works,
      // which is exactly what the retry button does.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleChrome,
        child: _buildMessage(kChapterLoadFailedMessage),
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
        // Past the END OF THE STRIP, not past the chapter being read. The
        // strip can already hold the next chapter or two, so pulling at its
        // bottom means "the one after everything loaded" — offering the one
        // after the CURRENT chapter would have jumped backwards into pages
        // already sitting below.
        hasPrev: _prevIndex != null,
        hasNext: _afterStrip != null,
        prevLabel: _chapterLabel(_prevIndex),
        nextLabel: _chapterLabel(_afterStrip),
        onChangeChapter: (d) => _goToChapter(d > 0 ? _afterStrip : _prevIndex),
        child: direction == 'vertical'
            ? _buildVertical(pages)
            : _buildPaged(pages, direction),
      ),
    );
    if (!_stripReady) {
      content = Stack(
        children: [
          content,
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: readerBgColor(prefs.mangaBackground),
                child: _ChapterLoadingBar(label: _chapterLabel(_index)),
              ),
            ),
          ),
        ],
      );
    }
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
      Center(child: SingleChildScrollView(child: _chapterEndFooter(_index)));

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
  /// Trims a page's flat margins, when the reader is set to.
  ///
  /// This used to be `Transform.scale(1.06)` inside a `ClipRect` — a blind 3%
  /// shave off every side, which took artwork off a page that had no margin
  /// and left almost all of a wide one. The rect now comes from looking at the
  /// page (see [findContentRect]), so a page with nothing to trim is left
  /// exactly as it was.
  Widget _cropIfEnabled(Widget image, String url) {
    if (!sl<ReaderPrefs>().cropBorders) return image;
    final r = _crop[url];
    if (r == null) return image;
    return ClipRect(
      child: Align(
        alignment: Alignment(
          r.w >= 1 ? 0 : (r.x / (1 - r.w)) * 2 - 1,
          r.h >= 1 ? 0 : (r.y / (1 - r.h)) * 2 - 1,
        ),
        widthFactor: r.w,
        heightFactor: r.h,
        child: image,
      ),
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
            // Two slivers around [_anchorIndex] rather than one flat list.
            // Everything before the centre key lays out UPWARD into negative
            // offsets, so offset 0 is always the top of the anchor page and a
            // page above it finishing its decode — changing height — extends
            // the strip upward instead of shoving the page being read.
            //
            // A plain ListView pinned the viewport to a pixel offset computed
            // from placeholder heights, so every real height that arrived
            // moved the content under the reader. That is the scrambling.
            child: CustomScrollView(
              key: const ValueKey('manga-listview'),
              controller: _verticalController,
              center: _centerKey,
              physics: _wZooming ? const NeverScrollableScrollPhysics() : null,
              // Build and decode well past the viewport. Flutter's default is
              // 250 logical pixels, which on a strip whose pages run THOUSANDS
              // of pixels tall means a page only starts decoding as its top
              // edge arrives — so it arrives blank and fills in late, which is
              // what "pages don't load properly" is.
              //
              // Three quarters of a viewport in each direction — the same
              // reserve the reference Android readers use, for the same
              // reason. Bigger is not better: every laid-out page holds a
              // decoded bitmap, and this reader already fights the image
              // cache (see [_preload]).
              scrollCacheExtent: const ScrollCacheExtent.viewport(0.75),
              slivers: [
                // Pages above the anchor, nearest first — a sliver before the
                // centre is built in reverse, so item 0 here is the page
                // directly above the anchor.
                // Wrap-content, NOT a declared extent.
                //
                // Declaring each page's height let the sliver size the strip
                // without building it, which fixed a collapse — but it forces
                // every child to the height it was promised, and any page
                // whose promise was wrong drew with black around it. A page
                // with no measured aspect of its own falls back to the
                // CHAPTER's aspect, so every page shorter than page one got a
                // black band: caught on device with a speech bubble sliced in
                // half, the same letters continuing below the gap.
                //
                // A page is now exactly as tall as its image, which is the one
                // arrangement in which a gap cannot happen.
                SliverList.builder(
                  itemCount: _anchorIndex,
                  itemBuilder: (context, i) =>
                      _verticalStripItem(context, pages, _anchorIndex - 1 - i),
                ),
                SliverList.builder(
                  key: _centerKey,
                  itemCount: pages.length - _anchorIndex,
                  itemBuilder: (context, i) =>
                      _verticalStripItem(context, pages, _anchorIndex + i),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// One page of the webtoon strip, by ABSOLUTE page index — shared by both
  /// slivers so a page builds identically whichever side of the anchor it
  /// falls on.
  ///
  /// The end-of-chapter footer rides along INSIDE the last item rather than
  /// being an extra one, so the item count stays == the page count and the
  /// slider's page mapping needs no adjustment for a phantom page.
  Widget _verticalStripItem(
    BuildContext context,
    List<PageImage> pages,
    int index,
  ) {
    // The transition card rides with the LAST page of each chapter — which,
    // in a strip that holds several chapters, happens more than once. Its
    // height is declared in [_extentOf] so nothing is clipped.
    final page = _verticalItem(context, pages[index], index);
    final slot = _slotAt(index);
    final body = (slot?.isChapterEnd ?? false)
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [page, _chapterEndFooter(slot!.chapterIdx)],
          )
        : page;
    // What the page counter reads. Cheap — the detector only fires when a
    // page's visible fraction actually changes.
    return VisibilityDetector(
      key: ValueKey('manga-page-$index'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        if (info.visibleFraction <= 0) {
          _visible.remove(index);
        } else {
          _visible[index] = info.visibleFraction;
        }
        // Learn the page's real shape from the same callback, so scrolling
        // back reserves what it actually takes.
        //
        // Only once the image has DRAWN. Before that the item is the
        // placeholder, whose height was computed from the aspect — measuring
        // it reads back our own guess and locks it in. The chapter-wide
        // aspect comes from the decoded first page instead (see
        // _detectWebtoon).
        //
        if (!_loaded.contains(index)) return;
        final size = info.size;
        if (size.width <= 0 || size.height <= 0) return;
        _aspect[pages[index].url] = size.height / size.width;
      },
      child: body,
    );
  }

  /// Holds the chapter's spinner over the strip until the strip is actually
  /// worth looking at.
  ///
  /// For a frame or two after the pages arrive, nothing has been laid out and
  /// maxScrollExtent is still 0 — measured on device, exactly that. With no
  /// extent the whole strip collapses and the LAST item surfaces, footer and
  /// all, so a chapter you just opened flashed its own "End of Chapter N" card
  /// over a page that had not loaded. On a slow source that flash lasted
  /// seconds and read as a black screen.
  ///
  /// The strip is still built and still loading underneath — this only covers
  /// it — so nothing is delayed by waiting.
  void _armStripReady() {
    _stripReadyTimer?.cancel();
    _stripReady = false;
    // Whichever comes first: the first page drawn, or a short grace period so
    // a source that never answers cannot leave a spinner up forever.
    _stripReadyTimer = Timer.periodic(const Duration(milliseconds: 50), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final laid =
          _verticalController.hasClients &&
          _verticalController.position.maxScrollExtent > 0;
      if (laid || _loaded.contains(0) || t.tick > 24) {
        t.cancel();
        _stripReadyTimer = null;
        setState(() => _stripReady = true);
      }
    });
  }

  /// Re-centres the strip on [index]. This is what replaces a `jumpTo` in
  /// webtoon mode.
  ///
  /// The anchor is structural — it decides which sliver a page is built into —
  /// so moving it is a setState, and the offset is zeroed on the next frame
  /// because offset 0 means "top of the anchor page" under the new layout.
  /// Unlike a pixel jump this needs no page heights, so it is exact on a
  /// chapter where nothing has loaded yet.
  void _anchorToPage(int index) {
    final target = index < 0 ? 0 : index;
    if (_anchorIndex != target) {
      setState(() {
        _anchorIndex = target;
        _centerKey = ValueKey('manga-center-$target');
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_verticalController.hasClients) return;
      _verticalController.jumpTo(0);
    });
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
    // Leaving _wZooming clears the hold on [_webtoonDecodeWidth], so the pages
    // on screen re-resolve at the zoomed resolution — soft during the pinch,
    // sharp the moment it settles. Same bargain a subsampling view makes.
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
                  _drawnLocally(page)
                      ? Image(
                          image: _pageProvider(page, width),
                          fit: _pageBoxFit(_effectiveFit(sl<ReaderPrefs>())),
                          // Same gap as the strip had: nothing at all while
                          // the page decodes.
                          frameBuilder: (context, child, frame, wasSync) {
                            if (frame != null) _loaded.add(index);
                            if (wasSync || frame != null) return child;
                            return Center(
                              child: _shimmerSlot(
                                context,
                                label: '${index + 1}',
                              ),
                            );
                          },
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
                  page.url,
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
  /// The slot for strip position [i], or null when the strip has not caught up
  /// (a frame between the pages landing and the slots being filled).
  _PageSlot? _slotAt(int i) => (i >= 0 && i < _slots.length) ? _slots[i] : null;

  /// Height to hold for a page that hasn't drawn yet.
  ///
  /// It used to be a flat 200px against a page that renders at fifteen hundred
  /// or more, so every load grew the list by most of a screen: the page you
  /// were reading slid away under you, and `maxScrollExtent` moved so much
  /// that anything derived from it was noise. Reserving the real shape is what
  /// makes the list stop moving.
  double _reservedHeight(BuildContext context, int index) {
    final pages = _pages;
    final url = (pages != null && index >= 0 && index < pages.length)
        ? pages[index].url
        : null;
    return reservedPageHeight(
      MediaQuery.sizeOf(context).width,
      measured: url == null ? null : _aspect[url],
      chapter: _chapterAspect,
    );
  }

  Widget _verticalItem(BuildContext context, PageImage page, int index) {
    // See the comment on _pagedItem's RepaintBoundary — same reasoning here.
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _dispatchTap(d.globalPosition),
        onLongPress: () => _showPageActions(page),
        child: _cropIfEnabled(
          _verticalPageImage(context, page, index),
          page.url,
        ),
      ),
    );
  }

  /// Tiles the page when tiling is on and everything it needs is in hand;
  /// otherwise draws it whole, exactly as before. Every null check below is
  /// load-bearing — a page with no recorded file or no true pixel size takes
  /// the plain path, not a guessed one.
  Widget _verticalPageImage(BuildContext context, PageImage page, int index) {
    final aspect = _aspect[page.url];
    final pixels = _pixelSize[page.url];
    final file = _pageFile[page.url];
    final canTile =
        aspect != null &&
        pixels != null &&
        file != null &&
        // Below about two screens there is nothing to win and the plain path
        // is simpler and faster.
        (aspect * _webtoonDecodeWidth(context)) >
            MediaQuery.sizeOf(context).height * 2;

    if (canTile) {
      return TiledPageImage(
        path: file,
        imageWidth: pixels.width.round(),
        imageHeight: pixels.height.round(),
        decoder: _tileDecoder,
        fallbackBuilder: () => _plainPageImage(context, page, index),
      );
    }
    return _plainPageImage(context, page, index);
  }

  /// The old, untiled page draw — used directly when tiling is off or not
  /// possible for this page, and as [TiledPageImage]'s fallback.
  Widget _plainPageImage(BuildContext context, PageImage page, int index) {
    final width = _webtoonDecodeWidth(context);
    return _drawnLocally(page)
        ? Image(
            image: _pageProvider(page, width),
            width: double.infinity,
            fit: _verticalBoxFit(_effectiveFit(sl<ReaderPrefs>())),
            // A downloaded/CBZ page needs no fetch — it is there.
            // A local page decodes fast but not instantly, and it used
            // to cut straight from placeholder to art. Same short fade
            // the network path gets, so both read the same way.
            // Until the first frame decodes this shows the SAME
            // placeholder the network path shows.
            //
            // It used to fade in from opacity 0, which on this path
            // means the page is simply invisible while it loads — no
            // spinner, no page number, nothing. And this is not a rare
            // path: a source that rewrites its image bytes serves every
            // page through the native bridge (see [nativePageProvider]),
            // which is most long manhwa. That is the "it just shows
            // black" report — the progress ring was only ever on the
            // branch those pages never take.
            frameBuilder: (context, child, frame, wasSync) {
              if (frame != null) _loaded.add(index);
              if (wasSync) return child;
              if (frame == null) return _pagePlaceholder(context, index);
              return AnimatedOpacity(
                opacity: 1,
                duration: _kPageFade,
                curve: Curves.easeOut,
                child: child,
              );
            },
            errorBuilder: (_, _, _) => const SizedBox(
              height: 200,
              child: Icon(Icons.broken_image_outlined, color: Colors.white24),
            ),
          )
        : CachedNetworkImage(
            imageUrl: page.url,
            httpHeaders: page.headers,
            width: double.infinity,
            memCacheWidth: width,
            maxWidthDiskCache: width,
            fit: _verticalBoxFit(_effectiveFit(sl<ReaderPrefs>())),
            // The package default is 500ms, which is a long time to
            // watch a page arrive while you are still scrolling. Short
            // enough to feel immediate, long enough not to be a cut.
            fadeInDuration: _kPageFade,
            fadeOutDuration: _kPageFade,
            // The placeholder is already on screen holding the page's
            // space — fading it IN as well just delays it.
            placeholderFadeInDuration: Duration.zero,
            // The page is on screen for real from here. Scrolling PAST a
            // placeholder is not reading it, and that distinction is what
            // keeps a fast scroll from marking the chapter read.
            imageBuilder: (context, imageProvider) {
              _loaded.add(index);
              return Image(
                image: imageProvider,
                width: double.infinity,
                fit: _verticalBoxFit(_effectiveFit(sl<ReaderPrefs>())),
              );
            },
            // A page that has not arrived reserves its real height
            // (see [_reservedHeight]) so the list does not jump, and
            // shows how far along the download actually is. A shimmer
            // says "something is happening"; a percentage says whether
            // it is nearly there or barely started, which on a slow
            // source is the difference between waiting and giving up.
            progressIndicatorBuilder: (_, _, progress) =>
                _pagePlaceholder(context, index, progress.progress),
            errorWidget: (_, _, _) => const SizedBox(
              height: 200,
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 48,
              ),
            ),
          );
  }

  /// The strip, before there are any pages to put in it.
  ///
  /// Deliberately the same slots [_pagePlaceholder] draws, so the moment the
  /// page list lands the screen does not change character — the skeletons are
  /// simply replaced one by one by the art.
  /// The shimmering surface a page shows in its own place until its image
  /// arrives. Only pages use it — see the `_loading` branch of [_buildBody]
  /// for why the chapter fetch deliberately looks like something else.
  /// What a page shows while it is still coming: a progress ring, and nothing
  /// else.
  ///
  /// It used to be a shimmering slab with "Page 7 · 45%" written across it,
  /// which on a page several screens tall reads as a loading SCREEN rather
  /// than a page that has not arrived. A ring on the reader's own background
  /// says the same thing and gets out of the way.
  ///
  /// Determinate as soon as the download reports a total, so a page that is
  /// nearly there looks nearly there.
  Widget _shimmerSlot(
    BuildContext context, {
    required String label,
    double? progress,
    double? band,
  }) {
    return _repeatDown(
      band,
      SizedBox(
        width: 36,
        height: 36,
        child: CircularProgressIndicator(
          value: progress,
          // The current Material 3 drawing, set property by property. The
          // `year2023: false` shorthand does the same thing but is deprecated.
          strokeWidth: 3,
          strokeCap: StrokeCap.round,
          trackGap: 4,
          color: AppColors.accent,
          backgroundColor: AppColors.textSecondary.withValues(alpha: 0.16),
        ),
      ),
    );
  }

  /// Repeats [child] roughly once per screenful down a tall slot.
  ///
  /// A manhwa page runs several screens tall, and now that the slot is sized
  /// correctly BEFORE the image arrives (see [_measureFromFile]) a single
  /// centred spinner sits thousands of pixels away — off screen. What you got
  /// instead was a black slab with nothing on it, which is exactly the "it
  /// just shows black" report. Measuring ahead made that worse, not better,
  /// because the slots got bigger.
  ///
  /// So the indicator appears about once per screen: wherever you are in a
  /// page that has not arrived, one is in view telling you which page it is
  /// and how far along it is. Capped, because a very tall page must not turn
  /// into a hundred widgets.
  Widget _repeatDown(double? band, Widget child) {
    if (band == null || band <= 0) return Center(child: child);
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        if (!h.isFinite || h <= band) return Center(child: child);
        final n = math.min((h / band).ceil(), 10);
        return Column(
          children: [
            for (var i = 0; i < n; i++) Expanded(child: Center(child: child)),
          ],
        );
      },
    );
  }

  /// Shown in a page's place until its image arrives.
  ///
  /// Holds the page's real height (see [_reservedHeight]) so nothing shifts
  /// when the image lands, and sweeps a soft highlight across itself so the
  /// wait reads as loading rather than as a dead grey slab. The page number
  /// sits in the middle: on a slow source it is the only evidence the reader
  /// is where you think it is.
  ///
  /// A sweeping gradient rather than a pulsing block — a pulse dims the whole
  /// screen at once when several placeholders are visible, which is precisely
  /// the "broken app" look it was meant to avoid.
  Widget _pagePlaceholder(BuildContext context, int index, [double? progress]) {
    return SizedBox(
      height: _reservedHeight(context, index),
      width: double.infinity,
      child: _shimmerSlot(
        context,
        label: '${index + 1}',
        progress: progress,
        band: MediaQuery.sizeOf(context).height,
      ),
    );
  }

  /// End-of-chapter card, shown under the last page of the webtoon strip.
  ///
  /// Part of the scrolling content rather than floating over it, so it can
  /// never sit on top of the art. Reading the last page now ends the way it
  /// should: the page finishes, then the card, then a pull opens the next
  /// chapter — the three line up instead of overlapping.
  /// The marker between two chapters that are BOTH already in the strip.
  ///
  /// Reading here is continuous — the next chapter's pages are directly below
  /// — so this has nothing to ask and nothing to load. It only says which
  /// chapter you are crossing into, so the hand-off is not silent.
  ///
  /// Deliberately quiet: no button, because there is nothing to press that
  /// scrolling would not do for you, and tapping one used to tear the strip
  /// down to rebuild a chapter already an inch below.
  Widget _chapterDivider(int fromIdx, int toIdx) {
    final rule = Expanded(
      child: Container(
        height: 1,
        color: AppColors.textSecondary.withValues(alpha: 0.18),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              rule,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  Icons.south_rounded,
                  size: 15,
                  color: AppColors.textSecondary.withValues(alpha: 0.55),
                ),
              ),
              rule,
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'UP NEXT',
            style: AppText.caption.copyWith(
              color: AppColors.textSecondary.withValues(alpha: 0.55),
              fontSize: 10,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _chapterLabel(toIdx) ?? '',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.body.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14.5,
            ),
          ),
        ],
      ),
    );
  }

  /// The card between two chapters, for the chapter ENDING at this point —
  /// [chapterIdx], not necessarily the one being read. The strip can hold
  /// several chapters, so there can be several of these in it.
  Widget _chapterEndFooter(int chapterIdx) {
    final nextIdx = adjacentChapterIndex(_chapters, chapterIdx, step: 1);

    // The next chapter is already sitting below this card — so this is a
    // divider between two chapters in one strip, not the end of the road.
    //
    // Offering "Chapter 2 →" here was wrong twice over: it appeared in the
    // MIDDLE of a scroll with nothing ended, and tapping it tore the strip
    // down and rebuilt it for a chapter already loaded two inches below. A
    // quiet marker is all this position wants; keep scrolling and you are
    // there.
    if (nextIdx != null && _stripChapters.contains(nextIdx)) {
      return _chapterDivider(chapterIdx, nextIdx);
    }

    final hasNext = nextIdx != null;
    final next = _chapterLabel(nextIdx);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 34, 20, 48),
      child: Column(
        children: [
          Text(
            'FINISHED',
            style: AppText.caption.copyWith(
              color: AppColors.textSecondary.withValues(alpha: 0.5),
              fontSize: 10,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _chapterLabel(chapterIdx) ?? 'this chapter',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.body.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14.5,
            ),
          ),
          if (hasNext) ...[
            const SizedBox(height: 20),
            // The next chapter is being pulled onto the strip right now — say
            // so, rather than offering a button that races the fetch.
            if (_appending)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      strokeCap: StrokeCap.round,
                      trackGap: 4,
                      color: AppColors.accent,
                      backgroundColor: AppColors.textSecondary.withValues(
                        alpha: 0.16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    next ?? context.l10n.nextChapter,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              )
            else ...[
              Text(
                'UP NEXT',
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary.withValues(alpha: 0.5),
                  fontSize: 10,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              ReaderPillSurface(
                radius: 22,
                onTap: () => _goToChapter(nextIdx),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 11,
                ),
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
            ],
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                context.l10n.thatSTheLastChapter,
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildError() => _buildMessage(_error!);

  /// Icon, message, and a Retry that re-runs [_load]. Shared by the failure
  /// and the empty-chapter cases — both leave the reader with nothing to show
  /// and both are worth another attempt.
  Widget _buildMessage(String text) {
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
              text,
              style: AppText.body.copyWith(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            // Retry alone was a dead end: when a chapter won't render, the
            // thing you actually want is the page on the source's own site.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: _load,
                  child: Text(
                    context.l10n.retry,
                    style: AppText.body.copyWith(color: AppColors.accent),
                  ),
                ),
                if (source_actions.canOpenInBrowser(widget.sourceId, _chapter.url))
                  TextButton(
                    onPressed: () => unawaited(
                      source_actions.openUrlInSourceWebView(
                        source_actions.chapterWebUrl(widget.sourceId, _chapter.url) ?? '',
                        title: widget.showTitle,
                      ),
                    ),
                    child: Text(
                      context.l10n.openInBrowser,
                      style: AppText.body.copyWith(color: AppColors.accent),
                    ),
                  ),
              ],
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
                            ? 'Chapter ${chapterNumberLabel(_chapters, _index)}'
                                  ' / ${chapterCountLabel(_chapters)}'
                            // Read off the slot, not the strip: once reading
                            // has run on into the next chapter the strip holds
                            // both, and "pg 30/22" is not a thing.
                            : 'ch ${chapterNumberLabel(_chapters, _slotAt(pageIndex)?.chapterIdx ?? _index)}'
                                  ' · pg ${(_slotAt(pageIndex)?.pageInChapter ?? pageIndex) + 1}'
                                  '/${_slotAt(pageIndex)?.chapterPages ?? pages.length}',
                        onTap: _openChapterSheet,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  ReaderPillIconButton(
                    key: _menuButtonKey,
                    icon: Icons.more_vert_rounded,
                    tooltip: context.l10n.readerSettings,
                    onTap: () => unawaited(_openReaderMenu()),
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
    final hasPrev = _prevIndex != null;
    final hasNext = _nextIndex != null;
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
                    () => _goToChapter(_prevIndex),
                    enabled: hasPrev,
                  ),
                  Expanded(
                    // A chapter with one page has nothing to scrub, so the
                    // slider is replaced by empty space rather than a dead
                    // control pinned at both ends.
                    child: pageCount > 1
                        ? ValueListenableBuilder<int>(
                            valueListenable: _pageIndexVN,
                            builder: (context, pageIndex, _) {
                              // Scrub the CHAPTER, not the strip. The strip
                              // grows as reading runs on into the next
                              // chapter, and a slider that silently got longer
                              // under your thumb would be nonsense.
                              final slot = _slotAt(pageIndex);
                              final inChapter =
                                  slot?.pageInChapter ?? pageIndex;
                              final count = slot?.chapterPages ?? pageCount;
                              final start = pageIndex - inChapter;
                              if (count < 2) return const SizedBox(height: 40);
                              return ReaderSlider(
                                value: inChapter.toDouble().clamp(
                                  0,
                                  (count - 1).toDouble(),
                                ),
                                min: 0,
                                max: (count - 1).toDouble(),
                                divisions: count - 1,
                                onChangeStart: (_) => _seeking = true,
                                onChanged: (v) =>
                                    _seekToPage(start + v.round()),
                                onChangeEnd: (v) =>
                                    _commitSeek(start + v.round()),
                              );
                            },
                          )
                        : const SizedBox(height: 40),
                  ),
                  readerBarButton(
                    Icons.skip_next_rounded,
                    () => _goToChapter(_nextIndex),
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
                  '${chapterNumberLabel(_chapters, _index)}'
                  ' of ${chapterCountLabel(_chapters)}',
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
                                  chapterNumberLabel(_chapters, i),
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
                                      : 'Chapter '
                                            '${chapterNumberLabel(_chapters, i)}',
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
  /// Whether [_pageProvider] should draw this page rather than
  /// CachedNetworkImage.
  ///
  /// True for a downloaded/CBZ page, and for one the bridge marked as needing
  /// its source's own client — see [nativePageProvider]. Both end up as a
  /// plain [Image], so the network widget keeps its cache for every ordinary
  /// page.
  static bool _drawnLocally(PageImage page) =>
      _isLocal(page.url) ||
      CbzImage.tryParse(page.url) != null ||
      nativePageProvider(page.url, page.headers) != null;

  static ImageProvider _pageProvider(PageImage page, int width) {
    final cbz = CbzImage.tryParse(page.url);
    if (cbz != null) return ResizeImage.resizeIfNeeded(width, null, cbz);
    if (_isLocal(page.url)) {
      return ResizeImage.resizeIfNeeded(width, null, FileImage(File(page.url)));
    }
    // A source that serves its pages scrambled puts the descrambler on its own
    // OkHttp client, and fetching the url ourselves never touches that client —
    // the reader drew the raw scrambled bytes and the page looked torn into
    // squares. The bridge marks those pages, and the fix is the one covers have
    // used all along: go and get them natively instead.
    final native = nativePageProvider(page.url, page.headers);
    if (native != null) return ResizeImage.resizeIfNeeded(width, null, native);
    return ResizeImage.resizeIfNeeded(
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

  /// The ⋮ menu — a popup anchored to the button, not a bottom sheet.
  ///
  /// A sheet climbing up over the page you're reading is a lot of motion for
  /// three short rows. Reader settings still gets a sheet, because it IS a
  /// panel; this is just the way in.
  Future<void> _openReaderMenu() async {
    final chapter = _chapter;
    final canBrowse = source_actions.canOpenInBrowser(
      widget.sourceId,
      chapter.url,
    );
    final box = _menuButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    // Anchored under the button it came from, which is what makes it read as
    // that button's menu rather than a new screen.
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final position = RelativeRect.fromLTRB(
      origin.dx,
      origin.dy + box.size.height + 4,
      overlay.size.width - origin.dx - box.size.width,
      0,
    );

    final picked = await showMenu<_ReaderMenuAction>(
      context: context,
      position: position,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        // Hidden rather than greyed when the source has no page for this
        // chapter — see source_actions.chapterWebUrl.
        if (canBrowse)
          PopupMenuItem(
            value: _ReaderMenuAction.openInBrowser,
            child: _menuRow(
              Icons.public_rounded,
              context.l10n.openInBrowser,
            ),
          ),
        PopupMenuItem(
          value: _ReaderMenuAction.toggleRead,
          child: _menuRow(
            _markedRead
                ? Icons.remove_done_rounded
                : Icons.check_circle_outline_rounded,
            _markedRead ? context.l10n.markedUnread : context.l10n.markAsRead,
          ),
        ),
        PopupMenuItem(
          value: _ReaderMenuAction.settings,
          child: _menuRow(Icons.tune_rounded, context.l10n.readingSettings),
        ),
      ],
    );
    if (!mounted || picked == null) return;

    switch (picked) {
      case _ReaderMenuAction.openInBrowser:
        await source_actions.openUrlInSourceWebView(
          source_actions.chapterWebUrl(widget.sourceId, chapter.url) ?? '',
          title: widget.showTitle,
        );
      case _ReaderMenuAction.toggleRead:
        await _toggleReadFromMenu();
      case _ReaderMenuAction.settings:
        _openSettingsSheet();
    }
  }

  Widget _menuRow(IconData icon, String label) => Row(
    children: [
      Icon(icon, size: 20, color: AppColors.textSecondary),
      const SizedBox(width: 12),
      Text(label, style: AppText.body),
    ],
  );

  bool get _markedRead =>
      sl<ReadStore>().finished(widget.sourceId, widget.showId, _chapter.id);

  Future<void> _toggleReadFromMenu() async {
    final now = !_markedRead;
    await sl<ReadStore>().setRead(
      widget.sourceId,
      widget.showId,
      _chapter.id,
      read: now,
    );
    if (!mounted) return;
    setState(() {});
    showAppToast(
      context,
      now ? context.l10n.markedAsRead : context.l10n.markedUnread,
    );
  }

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
                        Text(
                          context.l10n.readerSettings,
                          style: AppText.headline,
                        ),
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
                            icon: Icons.fullscreen_rounded,
                            label: context.l10n.readerFullscreen,
                            trailing: Switch(
                              value: prefs.fullscreen,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setFullscreen(v);
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
/// What a chapter looks like while its page list is being fetched: the reader,
/// empty, with a spinner in the middle of it.
///
/// It replaced a full screen of shimmering page slots — see the `_loading`
/// branch of `_buildBody`. Indeterminate on purpose: a source hands back the
/// whole page list in one response, so there is no honest percentage to show,
/// and a ring sitting at some invented number would be worse than one that
/// just says "working".
class _ChapterLoadingBar extends StatelessWidget {
  const _ChapterLoadingBar({this.label});

  /// Which chapter is being fetched. Chrome is hidden when a chapter opens,
  /// so without this the screen is a spinner on black and says nothing about
  /// what it is waiting for.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final name = label;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              strokeCap: StrokeCap.round,
              trackGap: 4,
              color: AppColors.accent,
              backgroundColor: AppColors.textSecondary.withValues(alpha: 0.16),
            ),
          ),
          if (name != null && name.isNotEmpty) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Where one page of the strip came from.
///
/// The strip is flat — a single list the reader scrolls — but it can hold
/// several chapters at once, so every page has to carry its own provenance:
/// which chapter, where in that chapter, and how long that chapter is. The
/// page counter, the slider, progress saving and scrobbling all read these
/// rather than assuming the strip IS one chapter.
class _PageSlot {
  const _PageSlot(this.chapterIdx, this.pageInChapter, this.chapterPages);

  final int chapterIdx;
  final int pageInChapter;
  final int chapterPages;

  /// Last page of its chapter — where the transition card goes.
  bool get isChapterEnd => pageInChapter == chapterPages - 1;
}

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
/// Where the reader is, for a vertical chapter.
///
/// [atBottom] alone used to mean "the last page", and that is what let a fast
/// scroll finish a chapter nobody read: pages that have not loaded reserve a
/// guess, so the list can be half its real length and its "bottom" nowhere
/// near the end. Reaching the bottom only counts when the last page has
/// actually drawn.
int? verticalPageIndex({
  required bool atBottom,
  required bool lastPageLoaded,
  required int pageCount,
  required Map<int, double> visible,
}) {
  if (pageCount <= 0) return 0;
  if (atBottom && lastPageLoaded) return pageCount - 1;
  return mostVisiblePage(visible);
}

/// The page with most of itself on screen, from each built page's reported
/// visible fraction — null when nothing has reported yet.
///
/// This replaces reading the page number off scroll position, which assumed
/// every page was the same height. Webtoon pages are not, so the counter
/// stuck, jumped and skipped numbers, and you could not tell whether you were
/// reading in sequence.
int? mostVisiblePage(Map<int, double> visible) {
  int? best;
  var bestFraction = 0.0;
  for (final e in visible.entries) {
    // Ties go to the earlier page: scrolling forward, the page you are
    // leaving should not win back the counter from the one arriving.
    if (e.value > bestFraction) {
      bestFraction = e.value;
      best = e.key;
    }
  }
  return best;
}

/// A page taller than it is wide, which manga and webtoon pages both are.
/// Only used until the chapter's own first page has been measured.
/// Shown whenever the reader has nothing to display — the fetch threw, or it
/// came back with no pages at all.
///
/// One message for both on purpose. "No pages" reads as "this chapter is
/// empty", which sends people away; the usual cause is the source failing and
/// the usual fix is the Retry underneath it.
/// How many times the reader asks the source for a chapter before showing an
/// error. Two, not more: a source that fails twice in a row is not having a
/// blip, and a reader staring at a spinner wants to be told.
const int _loadAttempts = 2;

/// Long enough for a dropped request to not simply fail again, short enough
/// that nobody reads it as the app being stuck.
const Duration _retryDelay = Duration(milliseconds: 600);

const String kChapterLoadFailedMessage = "Couldn't load this chapter.";

const double kDefaultPageAspect = 1.45;

/// Height to hold for a page that hasn't drawn yet: its own measured shape,
/// else this chapter's, else a sensible portrait guess.
///
/// The placeholder used to be a flat 200px against a page that renders at
/// fifteen hundred or more, so every load grew the list by most of a screen —
/// the page being read slid away underneath, and maxScrollExtent moved enough
/// that anything derived from it was noise.
double reservedPageHeight(double width, {double? measured, double? chapter}) {
  final aspect = measured ?? chapter ?? kDefaultPageAspect;
  return width * (aspect <= 0 ? kDefaultPageAspect : aspect);
}

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

/// What the reader's ⋮ popup can return.
enum _ReaderMenuAction { openInBrowser, toggleRead, settings }
