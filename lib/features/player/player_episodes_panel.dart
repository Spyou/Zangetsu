// Episodes side panel.
part of 'player_screen.dart';

String stripEpisodePrefix(String title, int n) =>
    stripGenericEpisodePrefix(title, n);

// One row in the panel — either a "SEASON n" header or an episode (with its
// global index into the flat episode list).
class _PanelItem {
  const _PanelItem.header(this.season) : index = -1;
  const _PanelItem.episode(this.index) : season = -1;
  final int season; // valid when index == -1
  final int index; // global episode index when season == -1
  bool get isHeader => index == -1;
}

// Right-side episodes panel (CloudStream-style): thumbnail + "E{n} · title"
// cards grouped by "SEASON n" headers for multi-season titles; the current one
// is highlighted and the list opens scrolled to it. Tap to switch.
class _EpisodesPanel extends StatefulWidget {
  const _EpisodesPanel({
    required this.episodes,
    required this.currentIndex,
    required this.cover,
    required this.coverHeaders,
    required this.fillerEps,
    required this.onSelect,
  });

  final List<Episode> episodes;
  final int currentIndex;
  final String? cover;
  final Map<String, String>? coverHeaders;

  /// Filler episode NUMBERS from the Jikan lookup. Sources don't carry filler
  /// info, so [Episode.filler] is false here and this set is what the badge
  /// goes by. Snapshotted when the panel opens — by then the lookup, kicked
  /// off when playback started, has long since landed.
  final Set<int> fillerEps;

  final void Function(int) onSelect;

  @override
  State<_EpisodesPanel> createState() => _EpisodesPanelState();
}

class _EpisodesPanelState extends State<_EpisodesPanel> {
  /// Below this many episodes the search + sort row is more clutter than help,
  /// so it stays hidden and the list gets the space instead. Low enough that a
  /// normal season shows it — 20 meant a 13-episode series never did.
  static const int _toolsFrom = 8;
  static const double _headerH = 32;

  late final bool _multiSeason;
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _desc = false; // newest-first
  bool _jumped = false; // the opening scroll-to-current has run
  int? _season; // season chip tapped; null = whichever holds the current episode

  // Everything is sized off the panel width rather than fixed px — a 104px
  // thumbnail in a box that can be 240 or 380 wide is what made this look
  // cramped on a small phone and lost on a tablet. Set in build().
  double _rowH = 64;
  double _thumbW = 88;

  @override
  void initState() {
    super.initState();
    _multiSeason = seasonsOf(widget.episodes).length > 1;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  bool _matches(Episode e, int i) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    final n = (e.number?.toInt() ?? (i + 1)).toString();
    return n == q || n.startsWith(q) || e.title.toLowerCase().contains(q);
  }

  List<_PanelItem> _buildItems() {
    final idx = [
      for (var i = 0; i < widget.episodes.length; i++)
        if (_matches(widget.episodes[i], i)) i,
    ];
    if (_desc) idx.sort((a, b) => b.compareTo(a));

    if (!_multiSeason) return [for (final i in idx) _PanelItem.episode(i)];

    final bySeason = <int, List<int>>{};
    for (final i in idx) {
      (bySeason[seasonOf(widget.episodes[i]) ?? 1] ??= []).add(i);
    }
    final seasons = bySeason.keys.toList()..sort();
    if (_desc) {
      final r = seasons.reversed.toList();
      seasons
        ..clear()
        ..addAll(r);
    }
    final out = <_PanelItem>[];
    for (final s in seasons) {
      out.add(_PanelItem.header(s));
      out.addAll(bySeason[s]!.map(_PanelItem.episode));
    }
    return out;
  }

  /// Exact pixel offset of the first item matching [test].
  ///
  /// The old version multiplied by a hardcoded 78px card height, so any row
  /// that was actually taller (a long two-line title) skewed the sum and the
  /// list opened further off the further in you were. Rows are a known fixed
  /// height now — titles clamp to one line — so this is exact rather than a
  /// guess.
  double _offsetOf(List<_PanelItem> items, bool Function(_PanelItem) test) {
    var o = 0.0;
    for (final it in items) {
      if (test(it)) return o;
      o += it.isHeader ? _headerH : _rowH;
    }
    return 0;
  }

  void _scrollTo(double target, {bool animate = false}) {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final to = target.clamp(0.0, max);
    if (animate) {
      _scroll.animateTo(
        to,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(to);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    // A flat share of the screen, floored and capped so it stays sane at both
    // extremes. The old 42%-with-a-300px-floor swallowed half a small screen
    // and left the same small thumbnails rattling around inside 480px on a
    // big one; the contents scale with this now, so the panel can stay
    // comparatively narrow and still read well.
    final panelW = (w * 0.33).clamp(250.0, 360.0);

    // Contents scale with the panel instead of sitting at fixed px inside it.
    final s = (panelW / 300).clamp(0.86, 1.16); // type scale
    final pad = (panelW * 0.045).clamp(11.0, 18.0);
    _thumbW = (panelW * 0.30).clamp(64.0, 116.0);
    final thumbH = _thumbW * 9 / 16;

    // Row height is the taller of the thumbnail and the text beside it, not
    // just the thumbnail. Uniform rows are what keep [_offsetOf] exact, so the
    // height can't simply grow per row — but the text DOES grow with the
    // system font-size setting, and at ~1.3x it needs more than the thumbnail
    // leaves, which would overflow the row. Measuring both and taking the
    // larger keeps rows uniform, the scroll maths exact, and nothing clipped.
    // At normal text scale the thumbnail wins, so this changes nothing.
    final ts = MediaQuery.textScalerOf(context);
    final textH =
        ts.scale(13.5 * s) * 1.15 + // E-number
        ts.scale(12.5 * s) * 1.2 + // title
        2 + // gap above the meta line
        ts.scale(11.5 * s) * 1.15; // runtime · date
    _rowH = (thumbH > textH ? thumbH : textH) + 14;

    final items = _buildItems();
    final showTools = widget.episodes.length >= _toolsFrom;
    final seasons = _multiSeason
        ? (items.where((i) => i.isHeader).map((i) => i.season).toList())
        : const <int>[];
    // Until you tap one, the highlighted chip is the season you're watching —
    // so opening the panel already tells you where you are.
    final selSeason =
        _season ?? seasonOf(widget.episodes[widget.currentIndex]) ?? 1;

    // Opening scroll, once, after the first layout — by then _rowH is known
    // and the list has clients, so the offset can be exact.
    if (!_jumped) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _jumped) return;
        _jumped = true;
        _scrollTo(
          _offsetOf(items, (it) => !it.isHeader && it.index == widget.currentIndex) -
              _rowH * 1.5,
        );
      });
    }

    return Material(
      color: Colors.transparent,
      child: FrostedSurface(
        blur: true,
        opacity: 0.88,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
        child: SizedBox(
          width: panelW,
          height: double.infinity,
          // Left inset dropped, right kept. This panel is pinned to the RIGHT
          // screen edge, so a display cutout on the left can never reach it —
          // but SafeArea reads the screen-wide insets and was padding ~30
          // logical px off the panel's inner left anyway, eating about 11% of
          // its width to dodge a notch that isn't on its side. Worse, the
          // amount was whatever that phone's cutout happened to be, so the
          // contents landed differently on every device. Right stays: rotate
          // the phone and the camera moves to that edge, where the panel
          // really does touch it.
          child: SafeArea(
            left: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(pad, 11, 4, 8),
                  child: Row(
                    children: [
                      Text(
                        'Episodes',
                        style: AppText.title.copyWith(fontSize: 17 * s),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${widget.episodes.length}',
                          style: AppText.caption.copyWith(
                            color: AppColors.textTertiary,
                            fontWeight: FontWeight.w700,
                            fontSize: 11.5 * s,
                          ),
                        ),
                      ),
                      // Season lives up here rather than in a row of its own.
                      // The panel is ~300px wide with a search row already at
                      // the top, so vertical space is the scarce thing — this
                      // costs none, which is a whole extra episode visible. It
                      // also can't break on an odd season count the way a
                      // fixed row of chips does.
                      if (seasons.length > 1)
                        PopupMenuButton<int>(
                          initialValue: selSeason,
                          tooltip: 'Season',
                          color: AppColors.surface2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(11),
                          ),
                          onSelected: (sn) {
                            setState(() => _season = sn);
                            _scrollTo(
                              _offsetOf(
                                items,
                                (it) => it.isHeader && it.season == sn,
                              ),
                              animate: true,
                            );
                          },
                          itemBuilder: (c) => [
                            for (final sn in seasons)
                              PopupMenuItem<int>(
                                value: sn,
                                height: 40,
                                child: Text(
                                  'Season $sn',
                                  style: AppText.caption.copyWith(
                                    color: sn == selSeason
                                        ? AppColors.accent
                                        : AppColors.textSecondary,
                                    fontWeight: sn == selSeason
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    fontSize: 12.5 * s,
                                  ),
                                ),
                              ),
                          ],
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.surface2,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(9, 4, 5, 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'S$selSeason',
                                    style: AppText.caption.copyWith(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12 * s,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.expand_more_rounded,
                                    size: 16,
                                    color: AppColors.textSecondary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: AppColors.textSecondary,
                        ),
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                if (showTools)
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 36,
                            child: TextField(
                              controller: _search,
                              onChanged: (v) =>
                                  setState(() => _query = v.trim()),
                              style: AppText.caption.copyWith(
                                color: AppColors.textPrimary,
                                fontSize: 12.5 * s,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Jump to episode…',
                                hintStyle: AppText.caption.copyWith(
                                  color: AppColors.textTertiary,
                                  fontSize: 12.5 * s,
                                ),
                                prefixIcon: const Icon(
                                  Icons.search_rounded,
                                  size: 17,
                                  color: AppColors.textTertiary,
                                ),
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                isDense: true,
                                filled: true,
                                fillColor: AppColors.surface2,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(9),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Newest-first / oldest-first.
                        Material(
                          color: AppColors.surface2,
                          borderRadius: BorderRadius.circular(9),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => setState(() => _desc = !_desc),
                            child: SizedBox(
                              width: 38,
                              height: 36,
                              child: Icon(
                                _desc
                                    ? Icons.arrow_downward_rounded
                                    : Icons.arrow_upward_rounded,
                                size: 17,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: EdgeInsets.all(pad),
                            child: Text(
                              'No episode matches “$_query”',
                              textAlign: TextAlign.center,
                              style: AppText.caption.copyWith(
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.only(bottom: 16),
                          itemCount: items.length,
                          itemBuilder: (c, k) {
                            final it = items[k];
                            if (it.isHeader) {
                              return SizedBox(
                                height: _headerH,
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(pad, 10, pad, 2),
                                  child: Text(
                                    'SEASON ${it.season}',
                                    style: AppText.caption.copyWith(
                                      color: AppColors.textTertiary,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                      fontSize: 11 * s,
                                    ),
                                  ),
                                ),
                              );
                            }
                            return _card(
                              widget.episodes[it.index],
                              it.index,
                              thumbH,
                              s,
                              pad,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One episode row. Fixed [_rowH] on purpose — uniform rows are what make
  /// [_offsetOf] exact, which is what fixes the opening scroll landing in the
  /// wrong place. That's also why the title clamps to one line.
  Widget _card(Episode e, int i, double thumbH, double s, double pad) {
    final cur = i == widget.currentIndex;
    final n = e.number?.toInt() ?? (i + 1);
    final title = episodeDisplayTitle(e, number: n) ?? '';
    final hasTitle = title.isNotEmpty;
    final thumb = (e.thumbnail != null && e.thumbnail!.isNotEmpty)
        ? e.thumbnail!
        : (widget.cover ?? '');

    // From the Jikan lookup, not the source — see [_EpisodesPanel.fillerEps].
    final isFiller = widget.fillerEps.contains(n);

    // Runtime · air date, whichever the source actually gave us.
    final bits = <String>[
      if ((e.runtimeMinutes ?? 0) > 0) '${e.runtimeMinutes} min',
      if (cur) 'Now playing' else if ((e.date ?? '').trim().isNotEmpty)
        e.date!.trim(),
    ];

    return SizedBox(
      height: _rowH,
      child: Material(
        color: cur ? AppColors.accentSoft : Colors.transparent,
        child: InkWell(
          onTap: () => widget.onSelect(i),
          child: Stack(
            children: [
              // Accent rail on the current row — far clearer at a glance than
              // the coloured episode number alone.
              if (cur)
                Positioned(
                  left: 0,
                  top: 5,
                  bottom: 5,
                  width: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 7),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: SizedBox(
                        width: _thumbW,
                        height: thumbH,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            thumb.isNotEmpty
                                ? CachedNetworkImage(
                                    imageUrl: thumb,
                                    httpHeaders: widget.coverHeaders,
                                    fit: BoxFit.cover,
                                    memCacheWidth: 240,
                                    placeholder: (c, u) =>
                                        ColoredBox(color: AppColors.surface2),
                                    errorWidget: (c, u, e) =>
                                        ColoredBox(color: AppColors.surface2),
                                  )
                                : ColoredBox(color: AppColors.surface2),
                            if (cur)
                              DecoratedBox(
                                decoration: const BoxDecoration(
                                  color: Color(0x55000000),
                                ),
                                child: Center(
                                  child: Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 24 * s,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(width: 10 * s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'E$n',
                            style: AppText.body.copyWith(
                              color: cur
                                  ? AppColors.accent
                                  : AppColors.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5 * s,
                              height: 1.15,
                            ),
                          ),
                          if (hasTitle)
                            Text(
                              title,
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                                fontSize: 12.5 * s,
                                height: 1.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (bits.isNotEmpty || isFiller)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  if (isFiller) ...[
                                    const TagBadge(text: 'FILLER'),
                                    const SizedBox(width: 6),
                                  ],
                                  Flexible(
                                    child: Text(
                                      bits.join(' · '),
                                      style: AppText.caption.copyWith(
                                        color: AppColors.textTertiary,
                                        fontSize: 11.5 * s,
                                        height: 1.15,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
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
}

// Netflix-style combined panel: Audio (left) | Subtitles (right), selections
// apply live without closing; a Sync section sits below.
