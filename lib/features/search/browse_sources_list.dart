import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/playback/pinned_sources.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/source_icon_tile.dart';
import '../../core/ui/source_switcher.dart';
import '../../l10n/l10n.dart';

/// Restricts [BrowseSourcesList] to one kind-tab's buckets. Streaming = anime
/// + movies combined (they're one playback pool — see `ContentModeX.
/// matchesProvider`/`categorizedSources`); Manga and Novel map to their own
/// buckets. Null (the default) shows every bucket — the pre-tabs behaviour.
enum SourceListKind { streaming, manga, novel }

/// One source row as the buckets describe it.
typedef SourceRow = ({String id, String label, String? repo, String? icon});

/// Move pinned sources into a single group at the top, in pin order.
///
/// One group across every category, the same shape the source switcher uses —
/// these two screens list the same sources and should not disagree about where
/// a pinned one lives. Pin order rather than alphabetical: the list is the
/// user's own arrangement. Pinned rows leave their category so nothing is
/// listed twice, and a category emptied by that is dropped.
///
/// Pure so the ordering can be tested without Hive or a widget tree.
List<(String, List<SourceRow>)> groupWithPinned(
  List<(String, List<SourceRow>)> groups,
  List<String> pinnedIds,
  String pinnedLabel,
) {
  final visible = [for (final g in groups) ...g.$2];
  final pinned = [
    for (final id in pinnedIds) ...visible.where((s) => s.id == id),
  ];
  final pinnedSet = {for (final s in pinned) s.id};
  return [
    if (pinned.isNotEmpty) (pinnedLabel, pinned),
    for (final (title, rows) in groups)
      (
        title,
        [
          for (final s in rows)
            if (!pinnedSet.contains(s.id)) s,
        ],
      ),
  ].where((g) => g.$2.isNotEmpty).toList();
}

/// The A-Z bucket a source files under. '#' covers anything that does not
/// start with a letter, the way a launcher does.
///
/// Shared by the sort and the rail ON PURPOSE. When they disagreed, sources
/// whose name starts with an emoji ("⚡SportzX") bucketed as '#' but sorted
/// AFTER 'z' — because U+26A1 is above 'z' — so '#' existed in two places and
/// the rail could only ever reach the first.
String sourceInitial(String label) {
  final name = sourceRowName(label).trim();
  if (name.isEmpty) return '#';
  final c = name[0].toUpperCase();
  return RegExp('[A-Z]').hasMatch(c) ? c : '#';
}

/// Bucket first, then the name — so every bucket is one contiguous run.
String _sortKey(String label) =>
    '${sourceInitial(label)}${sourceRowName(label).toLowerCase()}';

/// "Which source do you want to browse?" — the idle state of Search's Sources
/// scope, and the way into one source's own catalogue.
///
/// Reads [categorizedSources] (the same function the Home switcher uses) rather
/// than `SourceRepository.loadedSources`, which narrows by language preference:
/// right for a search fan-out, wrong for a list that claims to show what you
/// have installed.
class BrowseSourcesList extends StatelessWidget {
  const BrowseSourcesList({
    super.key,
    required this.onBrowse,
    this.query = '',
    this.kind,
  });

  final void Function(String sourceId, String name) onBrowse;

  /// Filters the rows by source name (label, and repo tag when present) —
  /// case-insensitive substring, empty = show everything. This narrows which
  /// installed sources are listed; it never touches content search.
  final String query;

  /// Which kind-tab this list is showing; null shows every bucket.
  final SourceListKind? kind;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Sources are not all there when this first builds. CloudStream plugins
    // in particular load from disk a few seconds after launch, so the list
    // drew without them and kept that stale answer until something else
    // forced a rebuild — switching tabs and back was the only way to see
    // them. These three announce when their set changes; the hub screen
    // already listens to the same three.
    listenable: Listenable.merge([
      // Whichever are actually registered: the app registers all three, but
      // a screen has no business crashing over a manager its host left out.
      if (sl.isRegistered<CloudStreamManager>()) sl<CloudStreamManager>(),
      if (sl.isRegistered<AniyomiManager>()) sl<AniyomiManager>(),
      if (sl.isRegistered<MihonManager>()) sl<MihonManager>(),
      // The language prefs too. Turning a language back on changes which
      // sources belong here, and without these the list kept the answer it
      // had — the only way to see the new ones was to pin something, because
      // that fires the notifier below and forces the rebuild.
      if (sl.isRegistered<MangaLangPrefs>()) sl<MangaLangPrefs>(),
      if (sl.isRegistered<AnimeLangPrefs>()) sl<AnimeLangPrefs>(),
    ]),
    builder: (context, _) => ValueListenableBuilder<List<String>>(
      // Pinning is a long-press away on every row, and the switcher can
      // change it too — rebuild rather than hand back a list that lies until
      // you leave the screen.
      valueListenable: PinnedSources.notifier,
      builder: (context, pinnedIds, _) => _build(context, pinnedIds),
    ),
  );

  Widget _build(BuildContext context, List<String> pinnedIds) {
    final b = categorizedSources();
    final q = query.trim().toLowerCase();
    bool matches(({String id, String label, String? repo, String? icon}) s) =>
        q.isEmpty ||
        s.label.toLowerCase().contains(q) ||
        (s.repo?.toLowerCase().contains(q) ?? false);

    final showStreaming = kind == null || kind == SourceListKind.streaming;
    final showManga = kind == null || kind == SourceListKind.manga;
    final showNovel = kind == null || kind == SourceListKind.novel;

    // One list per tab, not one per manifest type. Streaming used to split
    // into ANIME and MOVIES & SERIES, which put the same source two headers
    // apart depending on what it declares and made the A-Z rail meaningless.
    final all = <({String id, String label, String? repo, String? icon})>[
      if (showStreaming) ...b.anime.where(matches),
      if (showStreaming) ...b.movies.where(matches),
      if (showManga) ...b.manga.where(matches),
      if (showNovel) ...b.novel.where(matches),
    ]..sort((x, y) => _sortKey(x.label).compareTo(_sortKey(y.label)));

    // Pinned keeps its own group at the top, in pin order: that list is the
    // user's own arrangement, so it is the one thing alphabetical order must
    // not touch.
    final groups = groupWithPinned(
      [(context.l10n.sources, all)],
      pinnedIds,
      context.l10n.pinned,
    );
    final pinnedSet = pinnedIds.toSet();

    if (groups.isEmpty) {
      // Empty regardless of the query — a real "nothing's installed for this
      // tab", not just a query that matched nothing.
      final nothingInstalled =
          (!showStreaming || (b.anime.isEmpty && b.movies.isEmpty)) &&
          (!showManga || b.manga.isEmpty) &&
          (!showNovel || b.novel.isEmpty);
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          nothingInstalled
              ? context.l10n.noSourcesInstalled
              : context.l10n.noMatchesFound,
          style: AppText.caption,
          textAlign: TextAlign.center,
        ),
      );
    }

    // Flattened once, with a KNOWN height per entry, so the A-Z rail can jump
    // to an exact offset instead of guessing. Heights are enforced by the
    // SizedBoxes below, not assumed.
    final entries = <_Entry>[];
    var alphaStart = 0;
    for (final (title, rows) in groups) {
      final isPinned = title == context.l10n.pinned;
      // Only PINNED earns a header. There is one category per tab now, so its
      // header would say nothing the tab hasn't already said.
      if (isPinned) entries.add(_Entry.header(title));
      for (final r in rows) {
        entries.add(_Entry.row(r));
      }
      if (isPinned) alphaStart = entries.length;
    }

    return _SourceListView(
      entries: entries,
      alphaStart: alphaStart,
      pinnedSet: pinnedSet,
      onBrowse: onBrowse,
    );
  }
}

/// Identifies the A-Z rail's touch strip — what the finger actually lands on
/// — so a test can assert it is there, and how tall it is, without reaching
/// for a private type.
const Key alphabetRailKey = ValueKey('sources-az-rail');

/// Height of one letter's slot on the A-Z rail. One source of truth, so a
/// test measuring the strip cannot drift from what is drawn.
const double railSlotHeight = 17;

/// Identifies the letter preview shown while a finger is on the rail, so a
/// test can assert it appears and goes away again.
const Key railPreviewKey = ValueKey('sources-az-preview');

/// One row of the flat list: a section header or a source.
class _Entry {
  const _Entry._(this.header, this.row);
  factory _Entry.header(String title) => _Entry._(title, null);
  factory _Entry.row(SourceRow row) => _Entry._(null, row);

  final String? header;
  final SourceRow? row;

  bool get isHeader => header != null;

  /// Fixed so a letter's scroll offset is arithmetic rather than a guess.
  /// [_SourceListView] wraps every entry in a SizedBox of exactly this, so the
  /// number cannot drift away from what is drawn.
  double get height => isHeader ? 38 : 68;

  /// The bucket this row files under in the A-Z rail — the same function the
  /// list is sorted by, so a bucket is always one contiguous run.
  String get initial => sourceInitial(row!.label);
}

/// The list plus its launcher-style A-Z rail.
class _SourceListView extends StatefulWidget {
  const _SourceListView({
    required this.entries,
    required this.alphaStart,
    required this.pinnedSet,
    required this.onBrowse,
  });

  final List<_Entry> entries;

  /// Index the alphabetical run begins at — everything before it is the
  /// pinned block, which is in pin order and so has no place in an A-Z rail.
  final int alphaStart;
  final Set<String> pinnedSet;
  final void Function(String sourceId, String name) onBrowse;

  @override
  State<_SourceListView> createState() => _SourceListViewState();
}

class _SourceListViewState extends State<_SourceListView> {
  final _controller = ScrollController();

  /// Letter -> scroll offset of its first row.
  late Map<String, double> _offsets;
  late List<String> _letters;

  /// Non-null while a finger is on the rail; drives the preview bubble.
  String? _active;

  /// Position of the active letter in [_letters]. Drives the magnification
  /// wave — the letters either side of your finger swell too, so you can see
  /// where you are even with a thumb over the strip.
  int? _activeIndex;

  /// Centre of the active letter, measured down from the top of the Stack.
  double _activeTop = 0;

  /// Inset of the rail box itself from the top of the Stack. The strip is
  /// centred inside that box, so its own offset comes from the rail.
  static const _railInset = 8.0;

  /// Below this the rail is noise — the whole list is already on screen.
  static const _minRowsForRail = 12;

  @override
  void initState() {
    super.initState();
    _index();
  }

  @override
  void didUpdateWidget(_SourceListView old) {
    super.didUpdateWidget(old);
    // The query narrows the list, so the rail has to be rebuilt with it or it
    // scrolls to letters that are no longer there.
    if (!identical(old.entries, widget.entries)) _index();
  }

  void _index() {
    final offsets = <String, double>{};
    var y = 0.0;
    for (var i = 0; i < widget.entries.length; i++) {
      final e = widget.entries[i];
      if (i >= widget.alphaStart && !e.isHeader) {
        offsets.putIfAbsent(e.initial, () => y);
      }
      y += e.height;
    }
    _offsets = offsets;
    _letters = offsets.keys.toList();
  }

  /// Which letter the finger is over, from its position down the rail.
  void _letterAt(double dy, double railHeight, double stripTop) {
    if (_letters.isEmpty) return;
    final slot = railHeight / _letters.length;
    final i = (dy / slot).floor().clamp(0, _letters.length - 1);
    final letter = _letters[i];
    if (letter == _active) return;
    setState(() {
      _active = letter;
      _activeIndex = i;
      // Snapped to the letter's centre, not the raw finger position, so the
      // preview steps letter by letter rather than sliding.
      _activeTop = _railInset + stripTop + (i + 0.5) * slot;
    });
    final target = _offsets[letter];
    if (target == null || !_controller.hasClients) return;
    // jumpTo, not animateTo: the list has to track the finger. Animating here
    // lags a drag and then overshoots when it stops.
    _controller.jumpTo(target.clamp(0.0, _controller.position.maxScrollExtent));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rowCount = widget.entries.where((e) => !e.isHeader).length;
    final showRail = _letters.length > 1 && rowCount >= _minRowsForRail;
    // This list is the Sources TAB, so the shell's floating dock is drawn over
    // it (extendBody) and its height arrives as a bottom inset. An explicit
    // padding opts out of absorbing that automatically, so add it back or the
    // last source sits under the dock, unreachable.
    final bottomInset = 24 + MediaQuery.paddingOf(context).bottom;

    final list = ListView.builder(
      controller: _controller,
      padding: EdgeInsets.only(bottom: bottomInset),
      itemCount: widget.entries.length,
      itemBuilder: (context, i) {
        final e = widget.entries[i];
        // Every entry is boxed to the exact height _Entry.height reports —
        // that equality is what makes the rail's offsets land correctly.
        return SizedBox(
          height: e.height,
          child: e.isHeader ? _header(e.header!) : _row(e.row!),
        );
      },
    );

    if (!showRail) return list;

    return Stack(
      children: [
        // Keep the rail clear of the text.
        // Only wide enough to clear the letters AT REST (they span roughly
        // 16-26 in from the edge). The rail box is wider than that to give the
        // swell somewhere to go, but a swollen letter floats over the list for
        // the moment it is swollen — padding the list out for it left a strip
        // of dead space beside every chevron, permanently.
        Padding(padding: const EdgeInsets.only(right: 24), child: list),
        Positioned(
          top: _railInset,
          bottom: bottomInset,
          // Not flush: a letter at its swollen size would touch the screen
          // edge, which reads as clipped.
          right: 4,
          child: _AlphabetRail(
            letters: _letters,
            active: _active,
            activeIndex: _activeIndex,
            onDrag: _letterAt,
            onEnd: () => setState(() {
              _active = null;
              _activeIndex = null;
            }),
          ),
        ),
        // Beside the rail and small — the slider letters themselves carry
        // the motion, this just names the one you are on.
        Positioned(
          right: 64,
          top: _activeTop - 22,
          child: IgnorePointer(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              // Keyed on the letter, so every letter is a NEW child and pops
              // in on its own instead of the text swapping silently.
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: CurvedAnimation(
                  parent: anim,
                  curve: Curves.easeOutBack,
                  reverseCurve: Curves.easeIn,
                ),
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: _active == null
                  ? const SizedBox.shrink(key: ValueKey('no-letter'))
                  : DecoratedBox(
                      key: ValueKey(_active),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black54,
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: SizedBox(
                        key: railPreviewKey,
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Text(
                            _active!,
                            style: AppText.largeTitle.copyWith(
                              fontSize: 20,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
    child: Text(
      title.toUpperCase(),
      style: AppText.caption.copyWith(
        color: AppColors.textTertiary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    ),
  );

  Widget _row(SourceRow s) => ListTile(
    // Trimmed on the right only: ListTile's default 16 each side stacked on
    // top of the rail's gutter and pushed the chevron well clear of the edge.
    contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
    // sourceRowName strips the ecosystem tag so the letter fallback is the
    // source's own initial, not "C" for every CloudStream row.
    leading: SourceIconTile(name: sourceRowName(s.label), icon: s.icon),
    title: Text(
      s.label,
      style: AppText.body,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: (s.repo == null || s.repo!.isEmpty)
        ? null
        : Text(
            s.repo!,
            style: AppText.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.pinnedSet.contains(s.id))
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(
              Icons.push_pin,
              size: 15,
              color: AppColors.textTertiary,
            ),
          ),
        Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
      ],
    ),
    onTap: () => widget.onBrowse(s.id, s.label),
    // Same gesture as the switcher, so there is one thing to learn.
    onLongPress: () => PinnedSources.toggle(s.id),
  );
}

/// The letters down the right edge. Tap or drag to jump.
class _AlphabetRail extends StatelessWidget {
  const _AlphabetRail({
    required this.letters,
    required this.active,
    required this.activeIndex,
    required this.onDrag,
    required this.onEnd,
  });

  final List<String> letters;
  final String? active;

  /// Where the finger is in [letters], or null when it is off the rail.
  final int? activeIndex;

  /// Resting size. Small, so the swell reads as a swell.
  static const double _rest = 9.5;

  /// Size for the letter [i] slots away from the finger. A dock-style wave,
  /// deliberately a big one: this strip IS the feedback, so the letters around
  /// your thumb have to swell enough to read past it.
  double _sizeAt(int i) {
    if (activeIndex == null) return _rest;
    return switch ((i - activeIndex!).abs()) {
      0 => 22,
      1 => 16,
      2 => 12,
      3 => 10,
      _ => _rest,
    };
  }

  /// How far left the letter leans out of the strip. Paired with [_sizeAt],
  /// this is what turns a column of text into something that curves around
  /// your thumb — the swollen letters stand proud of the ones behind them.
  double _bulgeAt(int i) {
    if (activeIndex == null) return 0;
    return switch ((i - activeIndex!).abs()) {
      0 => -14,
      1 => -9,
      2 => -5,
      3 => -2,
      _ => 0,
    };
  }

  /// How far the letter slides AWAY from the finger, up or down.
  ///
  /// A swollen glyph is bigger than its 13pt slot, so without this the letters
  /// either side get overlapped and the strip turns into a pile. A dock solves
  /// it the same way: make room by pushing the neighbours out.
  ///
  /// It has to ACCUMULATE outward, never shrink. Displacing d=1 by more than
  /// d=2 sends the near letter straight past the far one — which is exactly
  /// what happened, and 'I' ended up sitting on top of 'H'. Past the wave
  /// every letter shifts by the same amount, so the tail just slides as one.
  ///
  /// Selection still goes by slot: the finger is steering the list, and the
  /// preview names the letter.
  double _spreadAt(int i) {
    if (activeIndex == null) return 0;
    final d = i - activeIndex!;
    final sign = d.isNegative ? -1 : 1;
    return switch (d.abs()) {
      0 => 0,
      1 => 6.0 * sign,
      _ => 8.0 * sign,
    };
  }

  /// A few degrees per slot, opposite signs above and below the finger, so the
  /// run of letters reads as wrapped on a wheel rather than stacked flat.
  double _tiltAt(int i) {
    if (activeIndex == null) return 0;
    return (i - activeIndex!).clamp(-3, 3) * 0.085;
  }

  Color _colorAt(int i) {
    if (activeIndex == null) return AppColors.textTertiary;
    final d = (i - activeIndex!).abs();
    if (d == 0) return AppColors.accent;
    return d <= 2 ? AppColors.textSecondary : AppColors.textTertiary;
  }

  /// Reports where the finger is, how tall the strip is, and where the strip
  /// starts inside the rail — the caller turns that into a letter, and into a
  /// position for the preview.
  final void Function(double dy, double railHeight, double stripTop) onDrag;
  final VoidCallback onEnd;

  /// One slot per letter, the SAME slot whatever the list holds. Spreading the
  /// letters over the full height instead made the gaps depend on how many
  /// there were: airy on a 12-letter list, cramped on a 26-letter one.
  /// Enough room to tell the letters apart at rest, without leaving the strip
  /// looking like gaps with letters in them.
  static const double slot = railSlotHeight;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      // Only ever shrinks, and only when a full alphabet cannot fit the
      // space — the gaps stay equal either way.
      final h = slot * letters.length <= c.maxHeight
          ? slot * letters.length
          : c.maxHeight;
      // Centred in the list area. The strip is shorter than the space it sits
      // in, so where it starts is not a constant — it gets reported back with
      // every drag rather than assumed, or the preview drifts off the letter.
      final stripTop = (c.maxHeight - h) / 2;
      return Align(
        alignment: Alignment.center,
        // Listener OUTSIDE the GestureDetector, as a belt-and-braces release.
        //
        // GestureDetector's callbacks only fire if it WINS the gesture arena.
        // Lose it and onTapUp / onVerticalDragEnd never arrive, which would
        // leave a swollen letter and its preview on screen with no finger near
        // them. A Listener is raw pointer routing — it does not enter the
        // arena, so its up/cancel always land. The GestureDetector still does
        // the claiming so the list underneath doesn't scroll.
        //
        // Not written against a reproduced bug: a stuck highlight turned out
        // to be leftover scripted input during testing, not a real path.
        // Kept because it costs nothing and the guarantee is worth having.
        child: Listener(
          onPointerUp: (_) => onEnd(),
          onPointerCancel: (_) => onEnd(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Every handler measures against `h`, the strip's real height, so
            // the letter under the finger is the letter that gets picked.
            onTapDown: (d) => onDrag(d.localPosition.dy, h, stripTop),
            onTapUp: (_) => onEnd(),
            onTapCancel: onEnd,
            onVerticalDragStart: (d) => onDrag(d.localPosition.dy, h, stripTop),
            onVerticalDragUpdate: (d) =>
                onDrag(d.localPosition.dy, h, stripTop),
            onVerticalDragEnd: (_) => onEnd(),
            onVerticalDragCancel: onEnd,
            child: SizedBox(
              key: alphabetRailKey,
              // Wide enough for a letter at its swollen size; the resting strip
              // still reads as a thin rail because the glyphs are small.
              width: 34,
              height: h,
              child: Column(
                children: [
                  for (var i = 0; i < letters.length; i++)
                    Expanded(
                      child: Center(
                        // Animated, so the wave rolls along the strip as the
                        // finger moves instead of snapping letter to letter.
                        // OverflowBox because a swollen glyph is far bigger than
                        // its slot, and it leans out of the strip too — without
                        // this the swell gets clipped flat.
                        child: OverflowBox(
                          maxHeight: 60,
                          maxWidth: 60,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 130),
                            curve: Curves.easeOut,
                            transformAlignment: Alignment.center,
                            transform: Matrix4.identity()
                              ..translateByDouble(
                                _bulgeAt(i),
                                _spreadAt(i),
                                0,
                                1,
                              )
                              ..rotateZ(_tiltAt(i)),
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 130),
                              curve: Curves.easeOut,
                              style: AppText.caption.copyWith(
                                fontSize: _sizeAt(i),
                                height: 1.0,
                                fontWeight: i == activeIndex
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                color: _colorAt(i),
                              ),
                              child: Text(letters[i]),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
