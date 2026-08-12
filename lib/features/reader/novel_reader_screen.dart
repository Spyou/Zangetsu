import 'package:flutter/material.dart';

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

  bool _loading = true;
  String? _error;
  ChapterText? _text;
  bool _chromeVisible = false;
  bool _atEnd = false;
  int _lastScrollSaveMs = 0;

  // Chapter ids already scrobbled this session — dedupes a repeated
  // "finished" save (throttled scroll ticks + the flush on chapter
  // change/dispose can all observe the same finished chapter).
  final Set<String> _scrobbled = {};

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    _scrollController = ScrollController()..addListener(_onScroll);
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
  void _restoreScrollPosition() {
    final saved = sl<ReadStore>().get(
      widget.sourceId,
      widget.showId,
      _chapter.id,
    );
    if (saved == null || saved.pos <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (max <= 0) return;
      _scrollController.jumpTo((saved.pos / 1000) * max);
    });
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
    if (!_scrollController.hasClients) return 0;
    final pos = _scrollController.position;
    if (pos.maxScrollExtent <= 0) return 1000; // whole chapter fits on screen
    final raw = (pos.pixels / pos.maxScrollExtent * 1000).round();
    if (raw < 0) return 0;
    if (raw > 1000) return 1000;
    return raw;
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

    final base = TextStyle(
      fontFamily: novelFontFamily(prefs.fontFamily),
      fontSize: prefs.fontSize,
      height: prefs.lineHeight,
      color: theme.text,
    );
    final spans = novelSpans(
      text.html,
      base,
      paragraphSpacing: prefs.paragraphSpacing,
    );
    final hasNext = _index < _chapters.length - 1;

    return SafeArea(
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: EdgeInsets.symmetric(
          horizontal: prefs.marginWidth,
          vertical: 32,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(style: base, children: spans),
              textAlign: prefs.textAlignJustify
                  ? TextAlign.justify
                  : TextAlign.start,
            ),
            if (_atEnd && hasNext)
              Padding(
                padding: const EdgeInsets.only(top: 28),
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
                child: Row(
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The four novel prefs, live-applied: each change writes straight to
  /// [ReaderPrefs] and calls `setState` on both the sheet and the reader
  /// body so the text underneath re-styles immediately.
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
                        _prefSlider(
                          'Font size',
                          prefs.fontSize,
                          12,
                          28,
                          (v) => apply(() => prefs.setFontSize(v)),
                        ),
                        _prefSlider(
                          'Line height',
                          prefs.lineHeight,
                          1.2,
                          2.4,
                          (v) => apply(() => prefs.setLineHeight(v)),
                        ),
                        _prefSlider(
                          'Margin',
                          prefs.marginWidth,
                          0,
                          48,
                          (v) => apply(() => prefs.setMarginWidth(v)),
                        ),
                        const SizedBox(height: 4),
                        Text('Font', style: AppText.caption),
                        const SizedBox(height: 8),
                        Wrap(
                          runSpacing: 8,
                          children: [
                            for (final f in const ['inter', 'serif', 'system'])
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _choiceChip(
                                  _fontLabel(f),
                                  prefs.fontFamily == f,
                                  () => apply(() => prefs.setFontFamily(f)),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text('Alignment', style: AppText.caption),
                        const SizedBox(height: 8),
                        Wrap(
                          runSpacing: 8,
                          children: [
                            for (final justify in const [false, true])
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _choiceChip(
                                  justify ? 'Justify' : 'Left',
                                  prefs.textAlignJustify == justify,
                                  () => apply(
                                    () => prefs.setTextAlignJustify(justify),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _prefSlider(
                          'Paragraph spacing',
                          prefs.paragraphSpacing,
                          0,
                          24,
                          (v) => apply(() => prefs.setParagraphSpacing(v)),
                        ),
                        readerSheetSection('Theme'),
                        Wrap(
                          runSpacing: 8,
                          children: [
                            for (final t in const [
                              'dark',
                              'black',
                              'sepia',
                              'gray',
                              'paper',
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _themeSwatch(
                                  t,
                                  prefs.theme == t,
                                  () => apply(() => prefs.setTheme(t)),
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

  String _fontLabel(String f) => switch (f) {
    'serif' => 'Serif',
    'system' => 'System',
    _ => 'Inter',
  };

  /// Same shape as MangaReaderScreen's own `_choiceChip`.
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
/// caller is unaffected.
List<InlineSpan> novelSpans(
  String html,
  TextStyle base, {
  double paragraphSpacing = 0,
}) {
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

  final spans = <InlineSpan>[];
  final buffer = StringBuffer();
  var bold = false;
  var italic = false;

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(
      TextSpan(
        text: buffer.toString(),
        style: base.copyWith(
          fontWeight: bold ? FontWeight.bold : null,
          fontStyle: italic ? FontStyle.italic : null,
        ),
      ),
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
      spans.add(const TextSpan(text: '\n'));
      // Only a paragraph close gets the extra gap — a bare `<br>` is a soft
      // line break within a paragraph (e.g. a poem line), not a block
      // boundary, so it stays exactly `\n` as before.
      if (tag.startsWith('</p') && paragraphSpacing > 0) {
        spans.add(
          WidgetSpan(
            child: SizedBox(height: paragraphSpacing, width: double.infinity),
          ),
        );
      }
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
