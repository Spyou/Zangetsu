import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/page_content.dart';
import '../../core/models/provider_info.dart';
import '../../core/reading/read_history.dart';
import '../../core/reading/read_store.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import 'novel_paginator.dart';
import 'reader_chrome.dart';
import 'reader_comfort.dart';

/// Text reader for manga/novel chapters — the reading counterpart of the
/// video player. Phone-only (no TV twin, no TV focus handling needed).
///
/// Nothing routes here yet; Task 11 wires the Detail screen to push it.
class NovelReaderScreen extends StatefulWidget {
  const NovelReaderScreen({
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
  State<NovelReaderScreen> createState() => _NovelReaderScreenState();
}

class _NovelReaderScreenState extends State<NovelReaderScreen>
    with ReaderComfortMixin<NovelReaderScreen> {
  late int _index;
  // Mutable so a Continue Reading resume (opened with just the one chapter)
  // can widen to the show's full list in the background — see
  // `_maybeResolveChapters`. Every read of the chapter list goes through
  // this, never `widget.chapters` directly.
  late List<Episode> _chapters = widget.chapters;
  late final ScrollController _scrollController;
  late final PageController _pageController;

  bool _loading = true;
  String? _error;
  ChapterText? _text;
  bool _chromeVisible = false;
  bool _atEnd = false;
  int _lastScrollSaveMs = 0;
  // Last scroll permille computed while the controller was still attached.
  // `dispose()` flushes progress AFTER the Scrollable has detached, so
  // `_currentPermille()` can't read the live position then — it falls back to
  // this instead of saving 0, which would blank the Continue-Reading progress
  // bar and make the chapter reopen at the top. Manga keeps its position in a
  // retained field for the same reason.
  int _lastScrollPermille = 0;

  // Paged (book) mode state — only used when `prefs.novelPaginated` is true.
  // The scroll path above is left completely untouched so the default reader
  // stays byte-for-byte today's behavior. `_paginationKey` fingerprints the
  // inputs (chapter + text style + page size) so we only re-paginate when one
  // of them actually changes, not on every LayoutBuilder tick.
  List<TextSpan> _pages = const [];
  int _pageIndex = 0;
  String? _paginationKey;

  // Chapter ids already scrobbled this session — dedupes a repeated
  // "finished" save (throttled scroll ticks + the flush on chapter
  // change/dispose can all observe the same finished chapter).
  final Set<String> _scrobbled = {};

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    _scrollController = ScrollController()..addListener(_onScroll);
    _pageController = PageController();
    // Wakelock/brightness/orientation — see ReaderComfortMixin. The novel
    // reader never held a wakelock before this; it now does, same as manga.
    applyReaderComfort();
    _load();
    _maybeResolveChapters();
  }

  @override
  void dispose() {
    _flushProgress(); // reader close: don't lose the last-read position
    restoreReaderComfort();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Episode get _chapter => _chapters[_index];

  /// Background upgrade for a Continue Reading resume: opened with just the
  /// one already-read chapter, this fetches the show's real chapter list
  /// (same repo call the Detail screen uses) and — once it lands — widens
  /// `_chapters` and corrects `_index` to the same chapter's new position,
  /// so prev/next light up without disturbing whatever's already on screen.
  /// Never touches `_load()`/scroll state itself. Silent no-op on any
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
      final text = await sl<SourceRepository>().chapterText(
        _chapter.url,
        sourceId: widget.sourceId,
      );
      if (!mounted) return;
      setState(() {
        _text = text;
        _loading = false;
      });
      _restoreScrollPosition();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = "Couldn't load this chapter.";
        _loading = false;
      });
    }
  }

  /// Jumps to the chapter's saved scroll permille once the fresh content has
  /// laid out. No-op for a never-read chapter (nothing saved, or saved 0).
  ///
  /// The scroll body is now a lazy `SliverList` (see `_buildBody`), so unlike
  /// the old shrink-wrapped `Text.rich`, `maxScrollExtent` is only an
  /// ESTIMATE until enough items have actually laid out — a single
  /// post-frame `jumpTo` lands short. Poll instead: re-jump to the same
  /// target FRACTION every tick, so each tick corrects the previous one's
  /// guess against the current (better) estimate. Stops once the estimate
  /// stops moving, the user grabs the scrollbar themselves (don't yank
  /// them), or a ~3s ceiling either way.
  void _restoreScrollPosition() {
    final saved = sl<ReadStore>().get(
      widget.sourceId,
      widget.showId,
      _chapter.id,
    );
    if (saved == null || saved.pos <= 0) return;
    // Set now, not after the poll lands — a dispose before the poll settles
    // must not fall back to 0 (see `_lastScrollPermille`'s own doc).
    _lastScrollPermille = saved.pos;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _pollRestoreScroll(saved.pos / 1000),
    );
  }

  Future<void> _pollRestoreScroll(double fraction) async {
    // Bounded by a fixed tick count, NOT a DateTime.now() deadline: widget
    // tests run on a faked clock where wall-time barely advances, so a
    // real-clock deadline would never trip and this loop would spin forever
    // (hanging pumpAndSettle). 60 ticks × 50ms ≈ 3s of lazy layout to catch up.
    double? lastMax;
    for (var tick = 0; tick < 60 && mounted && _scrollController.hasClients; tick++) {
      final pos = _scrollController.position;
      // A jump already landed and the user has since dragged away from it —
      // leave them alone instead of yanking them back mid-read.
      if (lastMax != null && (pos.pixels - fraction * lastMax).abs() > 8) {
        return;
      }
      final max = pos.maxScrollExtent;
      if (max > 0) {
        _scrollController.jumpTo((fraction * max).clamp(0, max));
        if (lastMax != null && (max - lastMax).abs() < 1) return; // settled
        lastMax = max;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atEnd =
        pos.maxScrollExtent <= 0 || pos.pixels >= pos.maxScrollExtent - 4;
    if (atEnd != _atEnd) setState(() => _atEnd = atEnd);

    // Throttle routine in-chapter saves to ~once/second.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollSaveMs < 1000) return;
    _lastScrollSaveMs = now;
    _saveProgress(flush: false);
  }

  int _currentPermille() {
    // Both modes speak the same 0–1000 permille scale, so ReadStore/scrobble/
    // resume semantics are identical — only the source of the number differs.
    if (sl<ReaderPrefs>().novelPaginated) return _pagedPermille();
    // Controller already detached (e.g. inside dispose's flush) — reuse the
    // last value captured while scrolling instead of clobbering progress with 0.
    if (!_scrollController.hasClients) return _lastScrollPermille;
    final pos = _scrollController.position;
    // Nothing to scroll means "the whole chapter fits on screen" — finished —
    // but ONLY when there's actually a chapter there. A blank page (a source
    // that returned no text) is unscrollable too, and counting that as read
    // would mark it finished and scrobble it to the user's tracker.
    if (pos.maxScrollExtent <= 0) {
      final hasText = (_text?.html.trim().isNotEmpty ?? false);
      return _lastScrollPermille = hasText ? 1000 : 0;
    }
    final raw = (pos.pixels / pos.maxScrollExtent * 1000).round();
    return _lastScrollPermille = raw.clamp(0, 1000);
  }

  /// Paged-mode permille: the last page is 1000 (= finished, ≥ ReadStore's 950
  /// novel rule), so mark-read + scrobble fire at the end of a paged chapter
  /// exactly like they do when scrolling to the bottom.
  int _pagedPermille() {
    final count = _pages.length;
    if (count <= 1) return 1000; // single page = whole chapter on screen
    final raw = (_pageIndex / (count - 1) * 1000).round();
    if (raw < 0) return 0;
    if (raw > 1000) return 1000;
    return raw;
  }

  /// The chapter's saved permille (0 when never read) — the paged analogue of
  /// what `_restoreScrollPosition` reads.
  int _savedPermille() {
    final saved = sl<ReadStore>().get(
      widget.sourceId,
      widget.showId,
      _chapter.id,
    );
    if (saved == null) return 0;
    final p = saved.pos;
    if (p < 0) return 0;
    if (p > 1000) return 1000;
    return p;
  }

  /// Converts a saved permille to a starting page, so resuming lands on the
  /// same spot the scroll mode would — and switching modes mid-chapter keeps
  /// the reader at roughly the same place.
  int _pageForPermille(int permille, int count) {
    if (count <= 1) return 0;
    final page = (permille / 1000 * (count - 1)).round();
    if (page < 0) return 0;
    if (page >= count) return count - 1;
    return page;
  }

  /// Persists the current chapter's position. `ReadStore.save`/
  /// `ReadHistory.save` both already start with `if (IncognitoMode.on)
  /// return;` internally, so no extra guard belongs here — adding one would
  /// duplicate that check for no behavioral change.
  ///
  /// Fire-and-forget by design: page turns and dispose must not block on
  /// disk/network I/O, and both call sites (`dispose`, chapter change) are
  /// sync anyway.
  void _saveProgress({required bool flush}) {
    if (_text == null) return; // nothing loaded for this chapter yet
    final ep = _chapter;
    final permille = _currentPermille();
    sl<ReadStore>().save(
      widget.sourceId,
      widget.showId,
      ep.id,
      pos: permille,
      total: 1000,
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
        pos: permille,
        total: 1000,
        updatedMs: DateTime.now().millisecondsSinceEpoch,
        type: ProviderType.novel,
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
      novel: true, // AniList files this under manga+format:NOVEL, not manga
    );
  }

  void _flushProgress() => _saveProgress(flush: true);

  void _goToChapter(int newIndex) {
    if (newIndex < 0 || newIndex >= _chapters.length) return;
    if (newIndex == _index) return;
    _flushProgress(); // chapter change: push the chapter we're leaving now
    setState(() {
      _index = newIndex;
      _text = null;
      _error = null;
      _atEnd = false;
      _lastScrollSaveMs = 0;
      _lastScrollPermille = 0; // don't carry the old chapter's progress over
      // Drop the old chapter's pages so paged mode re-paginates the new one
      // and restores from ITS saved permille (empty pages → use saved, below).
      _pages = const [];
      _paginationKey = null;
      _pageIndex = 0;
    });
    _load();
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  @override
  Widget build(BuildContext context) {
    final prefs = sl<ReaderPrefs>();
    final theme = _readerTheme(prefs.theme);
    return Scaffold(
      backgroundColor: theme.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleChrome,
              child: _buildBody(theme, prefs),
            ),
          ),
          // Always mounted now (fade instead of build-if-visible) — see the
          // IgnorePointer inside each for why that doesn't eat page taps.
          _buildTopBar(),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildBody(_ReaderTheme theme, ReaderPrefs prefs) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          color: theme.text.withValues(alpha: 0.6),
        ),
      );
    }
    if (_error != null) return _buildError(theme);
    final text = _text;
    if (text == null) return const SizedBox.shrink();

    // Optional page-flip mode. When off (the default) the scroll path below is
    // left exactly as it was — same widgets, same restore, same behavior.
    if (prefs.novelPaginated) return _buildPaged(theme, prefs, text);

    final base = TextStyle(
      fontFamily: novelFontFamily(prefs.fontFamily),
      fontSize: prefs.fontSize,
      height: prefs.lineHeight,
      color: theme.text,
    );
    final hasNext = _index < _chapters.length - 1;
    // Same condition the old trailing `if (_atEnd && hasNext)` child used —
    // just expressed as one extra sliver, so it only exists (and only adds
    // to maxScrollExtent) once the chapter's actually been scrolled to the
    // bottom.
    final showNext = _atEnd && hasNext;
    final direction = resolveNovelDirection(prefs, text.html);

    // Lazy sliver HTML instead of a paragraph-per-ListView-item — a long
    // chapter with a few huge paragraphs used to still lay those out (and
    // repaint) whole; `flutter_widget_from_html`'s sliverList mode only
    // builds the blocks actually on screen. Same `_scrollController`, so
    // progress/resume/mark-read (all pixels/maxScrollExtent based) are
    // untouched — <img> tags render via the package's own bundled
    // cached-network-image support, no wiring needed here.
    //
    // Wrapped in [Directionality] so Arabic (and other RTL-script) chapters
    // read right-to-left: 'text-align: start' below then resolves to right
    // instead of left, and HtmlWidget mirrors block layout to match.
    return SafeArea(
      child: Directionality(
        textDirection: direction,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.symmetric(
                horizontal: prefs.marginWidth,
                vertical: 32,
              ),
              sliver: HtmlWidget(
                cleanNovelHtml(text.html),
                renderMode: RenderMode.sliverList,
                textStyle: base,
                // HtmlWidget caches its built tree and only re-renders when the
                // HTML or one of these triggers changes — a changed `textStyle`
                // alone does NOT re-render it. So every setting that feeds `base`
                // (font size/family/line height/colour) or `customStylesBuilder`
                // (spacing/alignment/direction) has to be listed here, or the
                // slider moves but the text doesn't.
                rebuildTriggers: [
                  prefs.fontSize,
                  prefs.fontFamily,
                  prefs.lineHeight,
                  theme.text,
                  prefs.paragraphSpacing,
                  prefs.textAlignJustify,
                  direction,
                ],
                customStylesBuilder: (element) {
                  // Force font size + line height as CSS on every element so a
                  // source that baked its own sizing in can't win over the
                  // reader's setting (textStyle alone loses to inline CSS).
                  final styles = <String, String>{
                    'font-size': '${prefs.fontSize}px',
                    'line-height': '${prefs.lineHeight}',
                    'direction': direction == TextDirection.rtl
                        ? 'rtl'
                        : 'ltr',
                  };
                  if (element.localName == 'p' || element.localName == 'div') {
                    styles['margin'] = '0 0 ${prefs.paragraphSpacing}px 0';
                    styles['text-align'] = prefs.textAlignJustify
                        ? 'justify'
                        : 'start';
                  }
                  return styles;
                },
              ),
            ),
            if (showNext)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 28, bottom: 40),
                  child: Center(
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
          ],
        ),
      ),
    );
  }

  Widget _buildError(_ReaderTheme theme) {
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
              style: AppText.body.copyWith(color: theme.text),
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

  /// Page-flip (book) mode: the same styled text split into page-sized
  /// [TextSpan]s by [paginateSpans] and shown in a horizontal [PageView].
  /// Left/right thirds turn the page, the center toggles chrome — the novel's
  /// analogue of the manga reader's tap zones. The scroll reader is untouched
  /// by this path; `prefs.novelPaginated` picks between them in `_buildBody`.
  Widget _buildPaged(_ReaderTheme theme, ReaderPrefs prefs, ChapterText text) {
    final base = TextStyle(
      fontFamily: novelFontFamily(prefs.fontFamily),
      fontSize: prefs.fontSize,
      height: prefs.lineHeight,
      color: theme.text,
    );
    final direction = resolveNovelDirection(prefs, text.html);
    return SafeArea(
      child: Directionality(
        // Same auto/user-forced direction as the scroll reader. `textAlign:
        // start` and `AlignmentDirectional.topStart` below then resolve
        // against it, so an RTL chapter's pages read right-to-left.
        textDirection: direction,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The page's text area, matching the item padding below exactly
            // (horizontal margin each side, 32 top + 32 bottom) so a paginated
            // page fills the view without ever overflowing it.
            final pageSize = Size(
              (constraints.maxWidth - prefs.marginWidth * 2).clamp(
                1.0,
                double.infinity,
              ),
              (constraints.maxHeight - 64).clamp(1.0, double.infinity),
            );
            _ensurePaginated(text.html, base, pageSize);
            final pages = _pages;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) =>
                  _handlePageTap(d.localPosition.dx, constraints.maxWidth),
              child: PageView.builder(
                controller: _pageController,
                itemCount: pages.isEmpty ? 1 : pages.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, index) {
                  if (pages.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: prefs.marginWidth,
                      vertical: 32,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: Text.rich(
                        pages[index],
                        textAlign: prefs.textAlignJustify
                            ? TextAlign.justify
                            : TextAlign.start,
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// Recomputes pagination only when the chapter, text style, or page size
  /// changes (not on every rebuild), then jumps the [PageController] to the
  /// resume/carry-over page. A never-read chapter with empty `_pages` uses its
  /// saved permille (0 → page 0); a re-paginate (font/size/rotation) carries
  /// the live position so the reader stays roughly in place.
  void _ensurePaginated(String html, TextStyle base, Size pageSize) {
    final key =
        '${identityHashCode(_text)}|${base.fontSize}|${base.fontFamily}'
        '|${base.height}|${pageSize.width.toStringAsFixed(1)}'
        '|${pageSize.height.toStringAsFixed(1)}';
    if (key == _paginationKey) return;
    final carry = _pages.isEmpty ? _savedPermille() : _pagedPermille();
    _paginationKey = key;
    final spans = novelSpans(html, base); // paragraphSpacing 0 → pure TextSpans
    _pages = paginateSpans(
      TextSpan(style: base, children: spans),
      pageSize: pageSize,
      style: base,
    );
    final target = _pageForPermille(carry, _pages.length);
    _pageIndex = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      if (_pageController.page?.round() != target) {
        _pageController.jumpToPage(target);
      }
    });
  }

  void _onPageChanged(int index) {
    if (index == _pageIndex) return; // e.g. the restore jump landing on target
    setState(() => _pageIndex = index); // refresh the page x / y indicator
    _saveProgress(flush: false); // same save/scrobble path as scroll mode
  }

  void _handlePageTap(double dx, double width) {
    final third = width / 3;
    if (dx < third) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else if (dx > width - third) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _toggleChrome();
    }
  }

  // Chrome bars are always white-on-scrim now, matching the manga reader —
  // a shared dark overlay reads over any of the three page themes (dark/
  // black/sepia) the same way the player's own control bars read over any
  // video, so these no longer take the page theme as a parameter.
  Widget _buildTopBar() {
    // IgnorePointer, not the old `if (_chromeVisible) build it at all` — the
    // bar is always in the tree so AnimatedOpacity has something to fade,
    // but that means it'd otherwise sit invisible on top of the page
    // catching taps meant for chrome-toggle underneath. Ignoring while
    // hidden keeps that tap zone working exactly as before.
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
                            Text(
                              'Chapter ${_index + 1} / ${_chapters.length}',
                              style: AppText.caption.copyWith(
                                color: Colors.white70,
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (sl<ReaderPrefs>().novelPaginated && _pages.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          'Page ${_pageIndex + 1} / ${_pages.length}',
                          style: AppText.caption.copyWith(
                            color: Colors.white70,
                          ),
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
                        readerBarButton(Icons.tune_rounded, _openSettingsSheet),
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
            ],
          ),
        ),
      ),
    );
  }

  /// The novel prefs, live-applied: each change writes straight to
  /// [ReaderPrefs] and calls `setState` on both the sheet and the reader
  /// body so the text underneath re-styles immediately. Every row is built
  /// from reader_chrome.dart's shared readerSheetRow/ReaderSegmentedControl/
  /// readerSheetGroup pieces, so this sheet, the manga reader's, and
  /// Settings -> Reader all read as one design.
  void _openSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final prefs = sl<ReaderPrefs>();
          void apply(VoidCallback change) {
            change();
            setSheetState(() {});
            if (mounted) setState(() {});
          }

          final fontOptions = <({String value, String label})>[
            for (final f in const ['inter', 'serif', 'system'])
              (value: f, label: _fontLabel(f)),
          ];
          const alignmentOptions = <({String value, String label})>[
            (value: 'left', label: 'Left'),
            (value: 'justify', label: 'Justify'),
          ];
          const directionOptions = <({String value, String label})>[
            (value: 'auto', label: 'Auto'),
            (value: 'ltr', label: 'LTR'),
            (value: 'rtl', label: 'RTL'),
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
                        Text('Reader settings', style: AppText.headline),
                        readerSheetSection('Text'),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.text_fields_rounded,
                            label: 'Font',
                            child: ReaderSegmentedControl(
                              options: fontOptions,
                              selected: prefs.fontFamily,
                              onSelect: (v) =>
                                  apply(() => prefs.setFontFamily(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.format_size_rounded,
                            label: 'Font size',
                            child: Slider(
                              value: prefs.fontSize.clamp(12, 28),
                              min: 12,
                              max: 28,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setFontSize(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.format_line_spacing_rounded,
                            label: 'Line height',
                            child: Slider(
                              value: prefs.lineHeight.clamp(1.2, 2.4),
                              min: 1.2,
                              max: 2.4,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setLineHeight(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.format_align_justify_rounded,
                            label: 'Alignment',
                            child: ReaderSegmentedControl(
                              options: alignmentOptions,
                              selected: prefs.textAlignJustify
                                  ? 'justify'
                                  : 'left',
                              onSelect: (v) => apply(
                                () =>
                                    prefs.setTextAlignJustify(v == 'justify'),
                              ),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.format_textdirection_r_to_l_rounded,
                            label: 'Direction',
                            child: ReaderSegmentedControl(
                              options: directionOptions,
                              selected: prefs.textDirection,
                              onSelect: (v) =>
                                  apply(() => prefs.setTextDirection(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.view_stream_outlined,
                            label: 'Paragraph spacing',
                            child: Slider(
                              value: prefs.paragraphSpacing.clamp(0, 24),
                              min: 0,
                              max: 24,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setParagraphSpacing(v)),
                            ),
                          ),
                        ]),
                        readerSheetSection('Page'),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.format_indent_increase_rounded,
                            label: 'Margin',
                            child: Slider(
                              value: prefs.marginWidth.clamp(0, 48),
                              min: 0,
                              max: 48,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setMarginWidth(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.menu_book_rounded,
                            label: 'Paginated',
                            trailing: Switch(
                              value: prefs.novelPaginated,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                // Persist the spot in the CURRENT mode first,
                                // then switch — so the other mode resumes from
                                // the same permille (see _ensurePaginated /
                                // _restoreScrollPosition).
                                _saveProgress(flush: false);
                                prefs.setNovelPaginated(v);
                                _paginationKey = null;
                                _pages = const [];
                                _pageIndex = 0;
                                if (!v) {
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (mounted) _restoreScrollPosition();
                                  });
                                }
                              }),
                            ),
                          ),
                        ]),
                        readerSheetSection('Theme'),
                        readerSheetGroup([
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 12,
                            ),
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 10,
                              children: [
                                for (final t in const [
                                  'dark',
                                  'black',
                                  'sepia',
                                  'gray',
                                  'paper',
                                ])
                                  _themeSwatch(
                                    t,
                                    prefs.theme == t,
                                    () => apply(() => prefs.setTheme(t)),
                                  ),
                              ],
                            ),
                          ),
                        ]),
                        readerSheetSection('Comfort'),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.visibility_outlined,
                            label: 'Keep screen on',
                            trailing: Switch(
                              value: prefs.keepScreenOn,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setKeepScreenOn(v);
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

  String _fontLabel(String f) => switch (f) {
    'serif' => 'Serif',
    'system' => 'System',
    _ => 'Inter',
  };

  Widget _themeSwatch(String id, bool selected, VoidCallback onTap) {
    final theme = _readerTheme(id);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.bg,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? AppColors.accent
                : Colors.white.withValues(alpha: 0.16),
            width: selected ? 2 : 1,
          ),
        ),
        child: Center(
          child: Text(
            'A',
            style: TextStyle(color: theme.text, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _ReaderTheme {
  const _ReaderTheme(this.bg, this.text);
  final Color bg;
  final Color text;
}

_ReaderTheme _readerTheme(String theme) {
  switch (theme) {
    case 'black':
      return const _ReaderTheme(Colors.black, Color(0xFFDDDDDD));
    case 'sepia':
      return const _ReaderTheme(Color(0xFFF0E6D2), Color(0xFF4A3B2A));
    // Soft charcoal — easier on the eyes than true black at night without
    // going all the way to the app's own (near-black) 'dark' background.
    case 'gray':
      return const _ReaderTheme(Color(0xFF2B2B2E), Color(0xFFD6D6D6));
    // Warm off-white "paper" — lighter and more neutral than 'sepia', for
    // readers who want something closer to a printed page than a screen.
    case 'paper':
      return const _ReaderTheme(Color(0xFFFAF6EE), Color(0xFF2B2B2B));
    default: // 'dark'
      return _ReaderTheme(AppColors.bg, AppColors.textPrimary);
  }
}

/// Maps the `fontFamily` pref to a [TextStyle.fontFamily]. 'inter' uses the
/// bundled Inter family (same one the rest of the app's UI text uses);
/// 'serif' hands the engine the generic 'serif' name, which the Android
/// engine resolves to a real system serif font — no bundled asset needed;
/// 'system' returns null so the platform's default text font renders
/// untouched.
String? novelFontFamily(String key) => switch (key) {
  'serif' => 'serif',
  'system' => null,
  _ => 'Inter',
};

/// One decoded run of inline HTML — a text run with its bold/italic state,
/// or a break marker — the unit [novelSpans] walks raw chapter HTML into via
/// [_tokenizeHtml]. Only used by the paged (book) reader mode now; the
/// scroll reader hands its HTML straight to `HtmlWidget` instead (see
/// `_buildBody`).
class _HtmlToken {
  const _HtmlToken.text(this.text, {required this.bold, required this.italic})
    : isBreak = false,
      paragraphBreak = false;
  const _HtmlToken.brk({required this.paragraphBreak})
    : text = '',
      bold = false,
      italic = false,
      isBreak = true;

  final String text;
  final bool bold;
  final bool italic;
  final bool isBreak;
  // Only meaningful when [isBreak] is true: a closed `</p>` (block boundary)
  // vs. a bare `<br>` (soft line break within a paragraph, e.g. a poem line).
  final bool paragraphBreak;
}

/// Walks HTML into a flat list of [_HtmlToken]s for [novelSpans] (the paged
/// reader's only remaining consumer) — kept as its own function since it was
/// pulled out that way rather than folded back inline.
List<_HtmlToken> _tokenizeHtml(String html) {
  // `(?:</\1>|$)` (not just `</\1>`) so an unclosed <script>/<style> tag
  // still gets its raw content stripped through end-of-string instead of
  // leaking into the rendered chapter.
  final cleaned = html.replaceAll(
    RegExp(
      r'<(script|style)[^>]*>.*?(?:</\1>|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    '',
  );

  final tokens = <_HtmlToken>[];
  final buffer = StringBuffer();
  var bold = false;
  var italic = false;

  void flush() {
    if (buffer.isEmpty) return;
    tokens.add(
      _HtmlToken.text(buffer.toString(), bold: bold, italic: italic),
    );
    buffer.clear();
  }

  final tagRe = RegExp(r'<[^>]*>');
  var last = 0;
  for (final m in tagRe.allMatches(cleaned)) {
    if (m.start > last) {
      buffer.write(_unescapeHtml(cleaned.substring(last, m.start)));
    }
    final tag = cleaned.substring(m.start, m.end).toLowerCase();
    if (tag.startsWith('</p') || tag.startsWith('<br')) {
      flush();
      tokens.add(_HtmlToken.brk(paragraphBreak: tag.startsWith('</p')));
    } else if (tag.startsWith('<b') || tag.startsWith('<strong')) {
      flush();
      bold = true;
    } else if (tag.startsWith('</b') || tag.startsWith('</strong')) {
      flush();
      bold = false;
    } else if (tag.startsWith('<i') || tag.startsWith('<em')) {
      flush();
      italic = true;
    } else if (tag.startsWith('</i') || tag.startsWith('</em')) {
      flush();
      italic = false;
    }
    // everything else (<p>, <div>, <span>, ...): stripped, no-op
    last = m.end;
  }
  if (last < cleaned.length) {
    buffer.write(_unescapeHtml(cleaned.substring(last)));
  }
  flush();
  return tokens;
}

/// HTML → styled spans for the novel body. Pure and top-level so it's
/// unit-testable without pumping a widget.
///
/// `<p>`/`<br>` become paragraph/line breaks, `<b>`/`<strong>` and
/// `<i>`/`<em>` become bold/italic spans, everything else (including
/// `<script>`/`<style>` and their contents) is stripped. A closed `<p>`
/// (not a bare `<br>` line break) additionally gets [paragraphSpacing] of
/// vertical gap via a full-width `WidgetSpan` — the standard way to get a
/// precise pixel gap between blocks inside one `Text.rich` without leaving
/// span-land for a widget-per-paragraph layout. Default 0 reproduces the
/// reader's original spacing exactly (just the `\n`), so every existing
/// caller is unaffected. What the page-flip paginator consumes — the scroll
/// reader renders its HTML directly via `HtmlWidget` instead (see
/// `_buildBody`).
/// Strips a chapter's own inline styling before it's handed to `HtmlWidget`,
/// so the source's baked-in font size / family / line height can't override
/// the reader's settings. Removes `<style>` blocks, `style="…"` attributes,
/// and `<font>` tags (keeping their text). Only the scroll reader's HTML path
/// uses this; the paginator keeps parsing the raw HTML via `novelSpans`.
String cleanNovelHtml(String html) {
  return html
      .replaceAll(
        RegExp(r'<style[^>]*>.*?</style>', dotAll: true, caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp('''\\sstyle\\s*=\\s*("[^"]*"|'[^']*')''', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'</?font[^>]*>', caseSensitive: false), '');
}

/// Matches characters from RTL scripts (Arabic + its supplement/presentation
/// blocks, plus Hebrew) so [resolveNovelDirection] can auto-detect direction
/// straight from chapter text — no per-source configuration needed.
final RegExp _rtlChar = RegExp(
  r'[\u0590-\u05FF\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
);

/// True if at least a third of a sample of the chapter's letters are from an
/// RTL script. A ratio (not "any match") avoids false positives on chapters
/// that are mostly Latin text with the odd Arabic name or quote embedded.
bool _looksRtl(String html) {
  // Clamp against the stripped text, not the html it came from: each tag
  // collapses to a single space, so `plain` is the shorter of the two, and
  // slicing it to the html's length overran the end on any chapter shorter
  // than the sample size.
  final stripped = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
  final plain = stripped.substring(
    0,
    stripped.length < 4000 ? stripped.length : 4000,
  );
  final letters = plain.replaceAll(RegExp(r'[^\p{L}]', unicode: true), '');
  if (letters.isEmpty) return false;
  final rtlCount = _rtlChar.allMatches(letters).length;
  return rtlCount / letters.length > 0.33;
}

/// Resolves the effective [TextDirection] for a chapter: an explicit user
/// choice in Settings wins outright, otherwise it's auto-detected from the
/// chapter's own text so Arabic (and other RTL) novels default to reading
/// right-to-left without a manual per-source toggle.
TextDirection resolveNovelDirection(ReaderPrefs prefs, String html) {
  switch (prefs.textDirection) {
    case 'rtl':
      return TextDirection.rtl;
    case 'ltr':
      return TextDirection.ltr;
    default:
      return _looksRtl(html) ? TextDirection.rtl : TextDirection.ltr;
  }
}

List<InlineSpan> novelSpans(
  String html,
  TextStyle base, {
  double paragraphSpacing = 0,
}) {
  final spans = <InlineSpan>[];
  for (final t in _tokenizeHtml(html)) {
    if (t.isBreak) {
      spans.add(const TextSpan(text: '\n'));
      if (t.paragraphBreak && paragraphSpacing > 0) {
        spans.add(
          WidgetSpan(
            child: SizedBox(height: paragraphSpacing, width: double.infinity),
          ),
        );
      }
      continue;
    }
    spans.add(
      TextSpan(
        text: t.text,
        style: base.copyWith(
          fontWeight: t.bold ? FontWeight.bold : null,
          fontStyle: t.italic ? FontStyle.italic : null,
        ),
      ),
    );
  }
  return spans;
}

const Map<String, String> _htmlEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
};

/// Decodes the handful of HTML entities real scraped chapter text actually
/// contains (named + numeric). Anything unrecognised — including a numeric
/// reference outside the valid Unicode code point range (`&#99999999;`,
/// which a source with odd markup can genuinely contain) — is left as-is
/// rather than crashing: [String.fromCharCode] throws a [RangeError] outside
/// 0..0x10FFFF, and this runs synchronously from `build()`, well outside the
/// try/catch that only guards the network fetch in `_load()`.
///
/// Lone UTF-16 surrogates (0xD800-0xDFFF) are deliberately NOT special-cased:
/// `String.fromCharCode` doesn't throw for them (confirmed), it just renders
/// as tofu — a display quirk, not a crash, so out of scope for this guard.
String _unescapeHtml(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (
    m,
  ) {
    final ref = m.group(1)!;
    if (ref.startsWith('#x')) {
      final code = int.tryParse(ref.substring(2), radix: 16);
      return _charOrRaw(code, m.group(0)!);
    }
    if (ref.startsWith('#')) {
      final code = int.tryParse(ref.substring(1));
      return _charOrRaw(code, m.group(0)!);
    }
    return _htmlEntities[ref] ?? m.group(0)!;
  });
}

String _charOrRaw(int? code, String raw) {
  if (code == null || code < 0 || code > 0x10FFFF) return raw;
  return String.fromCharCode(code);
}
