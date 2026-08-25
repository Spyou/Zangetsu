// Source picker and download sheets.
part of 'detail_screen.dart';


/// A readable name for a source row. Providers like 4khdhub set a rich [label];
/// AllAnime sets neither label nor quality, so fall back to the host (or a
/// numbered server) instead of rendering a blank row.
String _sourceName(VideoSource s, int index) {
  final l = s.label?.trim();
  if (l != null && l.isNotEmpty) return l;
  final q = s.quality?.trim();
  if (q != null && q.isNotEmpty) return q;
  final host = (Uri.tryParse(s.url)?.host ?? '').replaceFirst('www.', '');
  return host.isNotEmpty
      ? 'Server ${index + 1} · $host'
      : 'Server ${index + 1}';
}

// Server/mirror picker (CloudStream-style) — resolves the episode's sources
// and lists them so the user downloads a specific, real link. Returns the
// chosen VideoSource via pop. HLS sources are shown disabled (phase 2).
class _SourcePickerSheet extends StatefulWidget {
  const _SourcePickerSheet({required this.title, required this.resolve});

  final String title;
  final Future<List<VideoSource>> Function() resolve;

  @override
  State<_SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<_SourcePickerSheet> {
  List<VideoSource>? _sources;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.resolve();
      if (mounted) setState(() => _sources = s);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load download options");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isHls(VideoSource s) =>
      s.container == SourceContainer.hls ||
      (Uri.tryParse(s.url)?.path ?? s.url).toLowerCase().endsWith('.m3u8');

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.6;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text('Download · choose server', style: AppText.title),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                widget.title,
                style: AppText.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              )
            else if (_error != null || (_sources?.isEmpty ?? true))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  _error ?? 'No download sources found',
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _sources!.length,
                  itemBuilder: (context, i) => _row(_sources![i], i),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(VideoSource s, int i) {
    final hls = _isHls(s);
    final label = _sourceName(s, i);
    final sub = [
      if (s.quality != null && s.quality!.trim().isNotEmpty) s.quality!.trim(),
      hls ? 'HLS' : 'Direct',
    ].join(' · ');
    void onTap() =>
        Navigator.pop(context, (chosen: s, all: _sources ?? <VideoSource>[s]));
    if (sl<AppMode>().isTv) {
      return TvListFocusable(
        autofocus: i == 0,
        onTap: onTap,
        semanticLabel: '$label, $sub',
        // This ListTile is only built on this TV branch — exclude its own
        // title/subtitle so TalkBack doesn't hear them twice.
        child: ExcludeSemantics(
          child: ListTile(
            contentPadding: const EdgeInsets.only(right: 8),
            leading: Icon(Icons.download_rounded, color: AppColors.accent),
            title: Text(
              label,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(sub, style: AppText.caption),
          ),
        ),
      );
    }
    return ListTile(
      contentPadding: const EdgeInsets.only(right: 8),
      leading: Icon(Icons.download_rounded, color: AppColors.accent),
      title: Text(
        label,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(sub, style: AppText.caption),
      onTap: onTap,
    );
  }
}

// Download sheet — season dropdown (multi-season) + a real SOURCE/quality list
// (resolved from the season's first episode, like the player) + tappable
// thumbnail episode rows you multi-select. Returns the chosen (quality,
// episodes) via pop; the quality drives per-episode source selection.
class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({
    required this.title,
    required this.episodesBySeason,
    required this.initialSeason,
    required this.resolve,
    required this.coverUrl,
    required this.coverHeaders,
    required this.initialCategory,
    required this.availableCategories,
    required this.resolveEpisodes,
    this.minimal = false,
  });

  /// Minimal presentation: a number-wheel "how many episodes" picker instead
  /// of the per-episode thumbnail grid. Same state, same result — only the
  /// selection UI + chrome differ (see [_buildMinimal]).
  final bool minimal;
  final String title;
  final Map<int, List<Episode>> episodesBySeason;
  final int initialSeason;
  final Future<List<VideoSource>> Function(Episode) resolve;
  final String coverUrl;
  final Map<String, String>? coverHeaders;

  /// Current sub/dub category + what the title offers. The Sub/Dub toggle is
  /// only shown when [availableCategories] has more than one. Switching it
  /// re-resolves the episode list via [resolveEpisodes].
  final String initialCategory;
  final List<String> availableCategories;
  final Future<Map<int, List<Episode>>> Function(String category)
  resolveEpisodes;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  String _quality = 'best';
  late int _season;
  late String _category;
  late Map<int, List<Episode>> _episodesBySeason;
  final Set<String> _selectedIds = {};
  late Map<String, Episode> _byId;

  // Real, resolved download sources for the current season's first episode.
  List<VideoSource>? _sources; // null = loading, [] = none found
  bool _loadingSources = true;
  int _selectedSourceIdx = 0;

  // Episode search/filter (phone + TV). No autofocus so the TV leanback
  // keyboard doesn't pop the moment the sheet opens.
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  // ── Minimal (wheel) mode only ──────────────────────────────────────────
  // The wheel picks a contiguous block: [_count] episodes starting at
  // [_startIdx] in the season (both indexing [_minimalPool], sorted by number).
  // The "From E{n}" control moves the start; the wheel picks how many.
  int _count = 0;
  int _startIdx = 0;
  late final FixedExtentScrollController _wheelCtrl;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _wheelCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _season = widget.initialSeason;
    _category = widget.initialCategory;
    _episodesBySeason = widget.episodesBySeason;
    _byId = {
      for (final eps in _episodesBySeason.values)
        for (final e in eps) e.id: e,
    };
    // Default to the whole current season selected so Download is enabled
    // immediately (the common "download this season" case); the user can Clear
    // or toggle tiles to narrow it.
    _selectedIds.addAll(
      (_episodesBySeason[_season] ?? const <Episode>[]).map((e) => e.id),
    );
    // Minimal wheel starts on the whole season (matches the classic default).
    _count = _seasonEps.length;
    _wheelCtrl = FixedExtentScrollController(
      initialItem: (_count - 1).clamp(0, 1 << 30),
    );
    _resolveSources();
  }

  /// The current season's episodes, sorted by number — the wheel indexes into
  /// this so "From E{n}" and the count line up with ascending episode numbers.
  List<Episode> get _minimalPool =>
      (_episodesBySeason[_season] ?? const <Episode>[]).toList()
        ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));

  int get _maxCount => (_minimalPool.length - _startIdx).clamp(0, 1 << 30);

  /// The episode number at pool index [idx] — used for the "From E{n}" label
  /// and the wheel, so the wheel reads as real episode numbers (E8, E9 …)
  /// starting at the chosen start, not an abstract 1-based count.
  int _epNumAt(int idx) {
    final pool = _minimalPool;
    if (pool.isEmpty) return 1;
    final j = idx.clamp(0, pool.length - 1);
    return pool[j].number?.toInt() ?? (j + 1);
  }

  int get _startNum => _epNumAt(_startIdx);

  /// Re-align the wheel to [_count] after the pool/start changed underneath it
  /// (season / sub-dub / start). No-op in classic mode (wheel not built).
  void _syncWheel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_wheelCtrl.hasClients) return;
      final maxIdx = (_maxCount - 1).clamp(0, 1 << 30);
      final target = (_count - 1).clamp(0, maxIdx);
      if (_wheelCtrl.selectedItem != target) _wheelCtrl.jumpToItem(target);
    });
  }

  /// The episodes the wheel currently picks: [_count] episodes from [_startIdx]
  /// — the exact same shape (sorted by number) the classic grid returns.
  List<Episode> get _minimalEpisodes {
    final pool = _minimalPool;
    if (pool.isEmpty) return const [];
    final start = _startIdx.clamp(0, pool.length - 1);
    final n = _count.clamp(1, pool.length - start);
    return pool.sublist(start, start + n);
  }

  /// Switch sub/dub: re-resolve the episode list for [cat] (dub episodes have
  /// different URLs), keep the season if it still exists, then re-resolve the
  /// source/quality options.
  Future<void> _setCategory(String cat) async {
    if (cat == _category) return;
    setState(() {
      _category = cat;
      _loadingSources = true;
      _sources = null;
    });
    try {
      final byS = await widget.resolveEpisodes(cat);
      if (!mounted) return;
      final seasons = byS.keys.toList()..sort();
      final season = byS.containsKey(_season)
          ? _season
          : (seasons.isEmpty ? _season : seasons.first);
      setState(() {
        _episodesBySeason = byS;
        _byId = {
          for (final eps in byS.values)
            for (final e in eps) e.id: e,
        };
        _season = season;
        _selectedIds
          ..clear()
          ..addAll((byS[season] ?? const <Episode>[]).map((e) => e.id));
        _startIdx = 0;
        _count = (byS[season] ?? const <Episode>[]).length;
      });
      await _resolveSources();
      _syncWheel();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingSources = false;
          _sources = [];
        });
      }
    }
  }

  int _h(VideoSource s) {
    final m = RegExp(r'(\d{3,4})').firstMatch(s.quality ?? '');
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  /// Resolve the first episode of the current season to show the real
  /// server/quality options (the batch download applies the chosen quality to
  /// every selected episode).
  Future<void> _resolveSources() async {
    setState(() {
      _loadingSources = true;
      _sources = null;
    });
    final eps = _seasonEps;
    if (eps.isEmpty) {
      setState(() {
        _loadingSources = false;
        _sources = [];
      });
      return;
    }
    try {
      final all = await widget.resolve(eps.first);
      if (!mounted) return;
      // HLS + direct are both downloadable now; show them all, best first.
      final ranked = all.toList()..sort((a, b) => _h(b).compareTo(_h(a)));
      setState(() {
        _sources = ranked;
        _selectedSourceIdx = 0;
        _quality = ranked.isNotEmpty
            ? (ranked.first.quality ?? 'best')
            : 'best';
        _loadingSources = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingSources = false;
          _sources = [];
        });
      }
    }
  }

  List<int> get _seasons => _episodesBySeason.keys.toList()..sort();
  bool get _multiSeason => _seasons.length > 1;
  List<Episode> get _seasonEps => _episodesBySeason[_season] ?? const [];

  /// The current season's episodes narrowed by the search query. Equals
  /// [_seasonEps] when the query is empty, so every path below is unchanged
  /// when the user isn't searching.
  List<Episode> get _filtered => filterEpisodes(_seasonEps, _query);

  List<Episode> get _selectedEpisodes =>
      (_selectedIds.map((id) => _byId[id]).whereType<Episode>().toList())
        ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));

  int _epNum(Episode e, int i) => e.number?.toInt() ?? (i + 1);

  // Select-all / Clear act on the *filtered* view, so "filter to OVA →
  // Select all" grabs just the matches. With no query, _filtered == _seasonEps.
  void _selectAllInSeason() =>
      setState(() => _selectedIds.addAll(_filtered.map((e) => e.id)));

  void _clearSeason() =>
      setState(() => _selectedIds.removeAll(_filtered.map((e) => e.id)));

  bool get _allSeasonSelected =>
      _filtered.isNotEmpty &&
      _filtered.every((e) => _selectedIds.contains(e.id));

  @override
  Widget build(BuildContext context) {
    if (widget.minimal) return _buildMinimal(context);
    final count = _selectedIds.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Download', style: AppText.title),
            const SizedBox(height: 4),
            Text(
              widget.title,
              style: AppText.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),

            // ── Season dropdown ────────────────────────────────────────────
            if (_multiSeason) ...[
              const SizedBox(height: 18),
              Text('Season', style: AppText.overline),
              const SizedBox(height: 8),
              _seasonDropdown(),
            ],

            // ── Audio (Sub / Dub) — only when the title offers both ─────────
            if (widget.availableCategories.length > 1) ...[
              const SizedBox(height: 18),
              Text('Audio', style: AppText.overline),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final c in widget.availableCategories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _categoryChip(c),
                    ),
                ],
              ),
            ],

            // ── Source / quality (resolved from the first episode) ─────────
            const SizedBox(height: 18),
            Text('Source', style: AppText.overline),
            const SizedBox(height: 8),
            _sourceSection(),

            // ── Episode multi-select (horizontal thumbnail cards) ──────────
            const SizedBox(height: 20),
            // Filter box — only when there's a list long enough to be worth it.
            if (_seasonEps.length > 5) ...[
              _episodeSearchField(),
              const SizedBox(height: 14),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_selectedIds.length}/${_seasonEps.length} episodes',
                  style: AppText.overline,
                ),
                _textBtn(
                  _allSeasonSelected ? 'Clear' : 'Select all',
                  _allSeasonSelected ? _clearSeason : _selectAllInSeason,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 118,
              child: _filtered.isEmpty && _query.isNotEmpty
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'No episodes match',
                        style: AppText.body.copyWith(
                          color: AppColors.textTertiary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.zero,
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (c, i) {
                        final ep = _filtered[i];
                        // Pass the ORIGINAL season index so a numberless
                        // episode's E-number fallback stays correct.
                        return _episodeCard(ep, _seasonEps.indexOf(ep));
                      },
                    ),
            ),

            // ── Download button ────────────────────────────────────────────
            const SizedBox(height: 16),
            if (sl<AppMode>().isTv)
              TvFocusable(
                autofocus: true,
                onTap: count == 0
                    ? () {}
                    : () => Navigator.pop(context, (
                        quality: _quality,
                        category: _category,
                        episodes: _selectedEpisodes,
                      )),
                semanticLabel: count == 0
                    ? 'Select episodes'
                    : 'Download $count episode${count == 1 ? '' : 's'}',
                child: Material(
                  color: count == 0 ? AppColors.surface2 : AppColors.accent,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    height: 50,
                    width: double.infinity,
                    child: Center(
                      // Excluded — semanticLabel above already announces
                      // this same text.
                      child: ExcludeSemantics(
                        child: Text(
                          count == 0
                              ? 'Select episodes'
                              : 'Download $count episode${count == 1 ? '' : 's'}',
                          style: AppText.button.copyWith(
                            color: count == 0
                                ? AppColors.textTertiary
                                : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              Material(
                color: count == 0 ? AppColors.surface2 : AppColors.accent,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: count == 0
                      ? null
                      : () => Navigator.pop(context, (
                          quality: _quality,
                          category: _category,
                          episodes: _selectedEpisodes,
                        )),
                  child: SizedBox(
                    height: 50,
                    width: double.infinity,
                    child: Center(
                      child: Text(
                        count == 0
                            ? 'Select episodes'
                            : 'Download $count episode${count == 1 ? '' : 's'}',
                        style: AppText.button.copyWith(
                          color: count == 0
                              ? AppColors.textTertiary
                              : Colors.white,
                        ),
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

  // ════════════════════════════════════════════════════════════════════
  // Minimal (number-wheel) presentation. Shares every bit of the classic
  // state above — sub/dub, season, source/quality, search — and returns the
  // identical (quality, category, episodes) result. Only the selection widget
  // (a wheel picking "how many from the top") and the chrome differ.
  // ════════════════════════════════════════════════════════════════════

  String get _qualityLabel {
    if (_loadingSources) return '…';
    final srcs = _sources ?? const <VideoSource>[];
    if (srcs.isEmpty) return 'Auto';
    return (_quality.isEmpty || _quality == 'best') ? 'Best' : _quality;
  }

  String _rangeLabel(List<Episode> eps) {
    int numOf(Episode e, int fallback) => e.number?.toInt() ?? fallback;
    final first = numOf(eps.first, 1);
    final last = numOf(eps.last, eps.length);
    return eps.length == 1 ? 'E$first' : 'E$first – E$last';
  }

  void _toggleCategory() {
    if (widget.availableCategories.length < 2) return;
    final other = widget.availableCategories.firstWhere(
      (c) => c != _category,
      orElse: () => _category,
    );
    _setCategory(other); // resets _count + re-syncs the wheel
  }

  Future<void> _pickSeason() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SeasonSheet(seasons: _seasons, currentSeason: _season),
    );
    if (picked == null || picked == _season || !mounted) return;
    setState(() {
      _season = picked;
      _startIdx = 0;
      _count = _seasonEps.length; // _season already updated above
    });
    await _resolveSources();
    _syncWheel();
  }

  /// "From E{n}" — a searchable episode list that sets where the block starts.
  /// Picking a start defaults the count to "rest of the season from here".
  Future<void> _pickStart() async {
    final pool = _minimalPool;
    if (pool.isEmpty) return;
    var q = '';
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final matches = filterEpisodes(pool, q);
          return SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.textTertiary.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Start from', style: AppText.headline),
                    ),
                  ),
                  if (pool.length > 8)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                      child: TextField(
                        onChanged: (v) => setSheet(() => q = v),
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                        cursorColor: AppColors.accent,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Jump to episode',
                          hintStyle: AppText.body.copyWith(
                            color: AppColors.textTertiary,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            color: AppColors.textTertiary,
                            size: 20,
                          ),
                          filled: true,
                          fillColor: AppColors.surface2,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  const Divider(color: AppColors.hairline, height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: matches.length,
                      itemBuilder: (c, i) {
                        final ep = matches[i];
                        final idx = pool.indexOf(ep);
                        final n = ep.number?.toInt() ?? (idx + 1);
                        final title = ep.title.trim();
                        final hasTitle =
                            title.isNotEmpty && title != 'Episode $n';
                        return ListTile(
                          title: Text(
                            hasTitle ? 'E$n  ·  $title' : 'E$n',
                            style: AppText.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: idx == _startIdx
                              ? Icon(Icons.check_rounded, color: AppColors.accent)
                              : null,
                          onTap: () => Navigator.pop(ctx, idx),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startIdx = picked.clamp(0, pool.length - 1);
      _count = pool.length - _startIdx; // default: rest of the season from here
    });
    _syncWheel();
  }

  Future<void> _pickQuality() async {
    final srcs = _sources ?? const <VideoSource>[];
    if (srcs.isEmpty) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Source', style: AppText.headline),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (var i = 0; i < srcs.length; i++)
                    ListTile(
                      title: Text(
                        _sourceName(srcs[i], i),
                        style: AppText.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: i == _selectedSourceIdx
                          ? Icon(Icons.check_rounded, color: AppColors.accent)
                          : ((srcs[i].quality?.trim().isNotEmpty ?? false)
                                ? Text(
                                    srcs[i].quality!.trim(),
                                    style: AppText.caption,
                                  )
                                : null),
                      onTap: () => Navigator.pop(ctx, i),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedSourceIdx = picked;
      final q = srcs[picked].quality;
      _quality = (q != null && q.trim().isNotEmpty) ? q.trim() : 'best';
    });
  }

  Widget _minimalMetaSeg(String label, {VoidCallback? onTap}) {
    final txt = Text(
      label,
      style: AppText.body.copyWith(
        color: onTap == null ? AppColors.textTertiary : AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.underline,
        decorationColor: AppColors.textTertiary,
        decorationStyle: TextDecorationStyle.dotted,
      ),
    );
    if (onTap == null) return txt;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: txt,
    );
  }

  Widget _minimalMetaLine() {
    final segs = <Widget>[];
    void add(Widget w) {
      if (segs.isNotEmpty) {
        segs.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '·',
              style: AppText.body.copyWith(color: AppColors.textTertiary),
            ),
          ),
        );
      }
      segs.add(w);
    }

    if (widget.availableCategories.length > 1) {
      add(
        _minimalMetaSeg(
          _category == 'dub' ? 'Dub' : 'Sub',
          onTap: _toggleCategory,
        ),
      );
    }
    if (_multiSeason) {
      add(_minimalMetaSeg('Season $_season', onTap: _pickSeason));
    }
    // "From E{n}" — the movable start point (searchable picker).
    if (_minimalPool.length > 1) {
      add(_minimalMetaSeg('From E$_startNum', onTap: _pickStart));
    }
    final srcs = _sources ?? const <VideoSource>[];
    add(
      _minimalMetaSeg(
        _qualityLabel,
        onTap: (_loadingSources || srcs.isEmpty) ? null : _pickQuality,
      ),
    );

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: segs,
    );
  }

  Widget _wheelPicker() {
    final maxCount = _maxCount.clamp(1, 1 << 30);
    return SizedBox(
      height: 196,
      child: ShaderMask(
        // Fade the neighbours toward the sheet background so the centre number
        // reads as selected — the dimmed-neighbour look of the reference.
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.32, 0.68, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: CupertinoPicker(
          scrollController: _wheelCtrl,
          itemExtent: 62,
          squeeze: 1.15,
          useMagnifier: false,
          backgroundColor: Colors.transparent,
          selectionOverlay: Container(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.hairline, width: 1),
                bottom: BorderSide(color: AppColors.hairline, width: 1),
              ),
            ),
          ),
          onSelectedItemChanged: (i) {
            HapticFeedback.selectionClick();
            setState(() => _count = i + 1);
          },
          children: [
            // Show the END episode number (E{start}…E{last}), so picking the
            // start at E8 makes the wheel read 8, 9, 10 … not 1, 2, 3.
            for (var i = 1; i <= maxCount; i++)
              Center(
                child: Text(
                  '${_epNumAt(_startIdx + i - 1)}',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _minimalTextBtn(String label, {VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(
          label,
          style: AppText.button.copyWith(
            color: onTap == null ? AppColors.textTertiary : AppColors.accent,
          ),
        ),
      ),
    );
  }

  Widget _buildMinimal(BuildContext context) {
    final pool = _minimalPool;
    final eps = _minimalEpisodes;
    final count = eps.length;
    final preview = eps.isEmpty
        ? ''
        : '$count episode${count == 1 ? '' : 's'} · ${_rangeLabel(eps)}';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Download episodes',
              style: AppText.title.copyWith(color: AppColors.accent),
            ),
            const SizedBox(height: 4),
            Text(
              widget.title,
              style: AppText.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            _minimalMetaLine(),
            const SizedBox(height: 6),
            if (pool.isEmpty)
              SizedBox(
                height: 196,
                child: Center(
                  child: Text(
                    'No episodes',
                    style: AppText.body.copyWith(color: AppColors.textTertiary),
                  ),
                ),
              )
            else
              _wheelPicker(),
            const SizedBox(height: 2),
            Center(
              child: Text(
                preview,
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _minimalTextBtn(
                  'Cancel',
                  onTap: () => Navigator.pop(context),
                ),
                const SizedBox(width: 26),
                _minimalTextBtn(
                  'Download',
                  onTap: count == 0
                      ? null
                      : () => Navigator.pop(context, (
                          quality: _quality,
                          category: _category,
                          episodes: _minimalEpisodes,
                        )),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _episodeSearchField() {
    return TextField(
      controller: _searchCtrl,
      focusNode: _searchFocus,
      onChanged: (v) => setState(() => _query = v),
      style: AppText.body.copyWith(color: AppColors.textPrimary),
      cursorColor: AppColors.accent,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search episodes',
        hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
        prefixIcon: const Icon(
          Icons.search_rounded,
          color: AppColors.textTertiary,
          size: 20,
        ),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(
                  Icons.close_rounded,
                  color: AppColors.textTertiary,
                  size: 20,
                ),
                tooltip: 'Clear',
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
              ),
        filled: true,
        fillColor: AppColors.surface2,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _categoryChip(String c) {
    final selected = c == _category;
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Text(
        c == 'dub' ? 'Dub' : 'Sub',
        style: AppText.body.copyWith(
          color: selected ? Colors.white : AppColors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (sl<AppMode>().isTv) {
      return TvFocusable(
        onTap: () => _setCategory(c),
        semanticLabel: c == 'dub' ? 'Dub' : 'Sub',
        child: Material(
          color: selected ? AppColors.accent : AppColors.surface2,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          // label is shared with the phone branch below — exclude it here
          // instead of touching it, so semanticLabel is the only announcement.
          child: ExcludeSemantics(child: label),
        ),
      );
    }
    return Material(
      color: selected ? AppColors.accent : AppColors.surface2,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: () => _setCategory(c), child: label),
    );
  }

  Widget _sourceSection() {
    if (_loadingSources) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.accent,
            ),
          ),
        ),
      );
    }
    final srcs = _sources ?? const <VideoSource>[];
    if (srcs.isEmpty) {
      // Couldn't resolve here (e.g. HLS-only) — each episode still tries at
      // download time; fall back to best available.
      return Text(
        'Auto · best available',
        style: AppText.caption.copyWith(color: AppColors.textSecondary),
      );
    }
    final maxH = MediaQuery.of(context).size.height * 0.22;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (var i = 0; i < srcs.length; i++) _sourceRow(srcs[i], i),
          ],
        ),
      ),
    );
  }

  Widget _sourceRow(VideoSource s, int i) {
    final sel = i == _selectedSourceIdx;
    final label = _sourceName(s, i);
    final hasQuality = s.quality != null && s.quality!.trim().isNotEmpty;
    void onTap() => setState(() {
      _selectedSourceIdx = i;
      _quality = hasQuality ? s.quality!.trim() : 'best';
    });
    final content = Row(
      children: [
        Icon(
          sel ? Icons.radio_button_checked : Icons.radio_button_off,
          color: sel ? AppColors.accent : AppColors.textTertiary,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: AppText.caption.copyWith(color: AppColors.textPrimary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (hasQuality) ...[
          const SizedBox(width: 8),
          Text(
            s.quality!.trim(),
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ],
    );
    if (sl<AppMode>().isTv) {
      // Match the Sub/Dub chip: a clean Material with NO own border, and the
      // 8px gap OUTSIDE TvFocusable so its focus ring hugs the row (was offset
      // by an inner margin + fought the row's own border — the "misaligned,
      // day-and-night" highlight testers reported). Selection = accent fill +
      // checked radio; focus = TvFocusable's ring.
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TvListFocusable( // full-width row — scaling overflows the sheet edges
          onTap: onTap,
          semanticLabel: hasQuality ? '$label, ${s.quality!.trim()}' : label,
          child: Material(
            color: sel ? AppColors.accentSoft : AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              // content is shared with the phone branch below — exclude it
              // here instead of touching it.
              child: ExcludeSemantics(child: content),
            ),
          ),
        ),
      );
    }
    final visual = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: sel ? AppColors.accentSoft : AppColors.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: sel ? AppColors.accent : AppColors.hairline,
          width: sel ? 1 : 0.5,
        ),
      ),
      child: content,
    );
    return GestureDetector(onTap: onTap, child: visual);
  }

  /// Season dropdown pill — opens the shared dark season picker sheet.
  Widget _seasonDropdown() {
    Future<void> openPicker() async {
      final picked = await showModalBottomSheet<int>(
        context: context,
        backgroundColor: AppColors.surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _SeasonSheet(seasons: _seasons, currentSeason: _season),
      );
      if (picked != null && picked != _season) {
        setState(() {
          _season = picked;
          _query = ''; // don't carry a stale filter into the new season
          _searchCtrl.clear();
        });
        _resolveSources(); // sources differ per season
      }
    }

    final visual = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(child: Text('Season $_season', style: AppText.headline)),
          const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: AppColors.textPrimary,
            size: 22,
          ),
        ],
      ),
    );

    if (sl<AppMode>().isTv) {
      return TvFocusable(
        onTap: openPicker,
        semanticLabel: 'Season $_season',
        child: Material(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          // visual is shared with the phone branch below — exclude it here
          // instead of touching it.
          child: ExcludeSemantics(child: visual),
        ),
      );
    }
    return Material(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: openPicker, child: visual),
    );
  }

  /// Horizontal episode card: 16:9 thumbnail with a selection check overlay +
  /// "E{n}" and the title beneath. Tap to toggle.
  Widget _episodeCard(Episode e, int i) {
    final sel = _selectedIds.contains(e.id);
    final thumb = (e.thumbnail != null && e.thumbnail!.isNotEmpty)
        ? e.thumbnail!
        : widget.coverUrl;
    final epNum = _epNum(e, i);
    final title = e.title.trim();
    final hasTitle = title.isNotEmpty && title != 'Episode $epNum';
    void onTap() => setState(() {
      if (sel) {
        _selectedIds.remove(e.id);
      } else {
        _selectedIds.add(e.id);
      }
    });
    final card = SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            // Selection = a thin accent ring around the thumbnail (no heavy
            // colour wash).
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: sel ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  SizedBox(
                    width: 132,
                    height: 74, // 16:9
                    child: thumb.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: thumb,
                            httpHeaders: widget.coverHeaders,
                            fit: BoxFit.cover,
                            memCacheWidth: 280,
                            placeholder: (c, u) =>
                                ColoredBox(color: AppColors.surface2),
                            errorWidget: (c, u, e) =>
                                ColoredBox(color: AppColors.surface2),
                          )
                        : ColoredBox(color: AppColors.surface2),
                  ),
                  // Small check badge — filled accent only when selected, a
                  // subtle dark chip otherwise (so it reads on any thumbnail).
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Container(
                      decoration: BoxDecoration(
                        color: sel ? AppColors.accent : const Color(0x99000000),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        sel ? Icons.check_rounded : Icons.add_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'E$epNum',
            style: AppText.caption.copyWith(
              color: sel ? AppColors.accent : AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (hasTitle)
            Text(
              title,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
    if (sl<AppMode>().isTv) {
      return TvFocusable(
        onTap: onTap,
        semanticLabel: hasTitle ? 'Episode $epNum, $title' : 'Episode $epNum',
        // card is shared with the phone branch below — exclude it here
        // instead of touching it.
        child: ExcludeSemantics(child: card),
      );
    }
    return GestureDetector(onTap: onTap, child: card);
  }

  Widget _textBtn(String label, VoidCallback onTap) {
    if (sl<AppMode>().isTv) {
      return TvFocusable(
        onTap: onTap,
        semanticLabel: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          // Excluded — semanticLabel above already announces this text.
          child: ExcludeSemantics(
            child: Text(
              label,
              style: AppText.caption.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(
          color: AppColors.accent,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ThumbnailProgressBar extends StatelessWidget {
  const _ThumbnailProgressBar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 4,
      child: Stack(
        children: [
          const ColoredBox(color: Color(0x80000000), child: SizedBox.expand()),
          FractionallySizedBox(
            widthFactor: fraction,
            alignment: Alignment.centerLeft,
            child: ColoredBox(color: AppColors.accent),
          ),
        ],
      ),
    );
  }
}
