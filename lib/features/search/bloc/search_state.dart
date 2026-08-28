import 'package:equatable/equatable.dart';

import '../../../core/models/media_detail.dart' show MediaStatus;
import '../../../core/models/media_item.dart';
import '../../../core/models/provider_info.dart';
import '../../../core/playback/source_health_store.dart' show SourceOutcome;

enum SearchStatus { idle, loading, success, error }

enum SearchSort {
  bestMatch('Best match'),
  newest('Newest'),
  titleAsc('Title A–Z'),
  titleDesc('Title Z–A');

  const SearchSort(this.label);
  final String label;
}

/// Content-type filter for results (CloudStream-style). The [MediaItem] model
/// only distinguishes anime vs movie, so "Movies & Series" covers everything
/// non-anime.
enum SearchContentFilter {
  all('All'),
  anime('Anime'),
  movies('Movies & Series');

  const SearchContentFilter(this.label);
  final String label;

  /// True when [item] passes this content-type filter.
  bool matches(MediaItem item) {
    switch (this) {
      case SearchContentFilter.all:
        return true;
      case SearchContentFilter.anime:
        return item.type == ProviderType.anime;
      case SearchContentFilter.movies:
        return item.type == ProviderType.movie;
    }
  }
}

/// Audio-track filter (anime mode only — see [MediaItem.subCount]/[dubCount],
/// the same real data that already drives the SUB/DUB poster badges).
enum SearchAudioFilter {
  any('Any'),
  subbed('Subbed'),
  dubbed('Dubbed');

  const SearchAudioFilter(this.label);
  final String label;

  /// True when [item] passes this audio filter.
  bool matches(MediaItem item) {
    switch (this) {
      case SearchAudioFilter.any:
        return true;
      case SearchAudioFilter.subbed:
        return (item.subCount ?? 0) > 0;
      case SearchAudioFilter.dubbed:
        return (item.dubCount ?? 0) > 0;
    }
  }
}

/// Publication-status filter. Real data: [MediaItem.status], carried from the
/// same Mihon/Aniyomi `status` field already parsed for [MediaDetail.status]
/// (see `mihon_mapping.dart`/`aniyomi_mapping.dart`) — not a title-text guess
/// like the old decade filter was. Not mode-gated: both Mihon (manga) and
/// Aniyomi (anime) sources report it.
enum SearchStatusFilter {
  any('Any'),
  ongoing('Ongoing'),
  completed('Completed');

  const SearchStatusFilter(this.label);
  final String label;

  /// True when [item] passes this status filter.
  bool matches(MediaItem item) {
    switch (this) {
      case SearchStatusFilter.any:
        return true;
      case SearchStatusFilter.ongoing:
        return item.status == MediaStatus.ongoing;
      case SearchStatusFilter.completed:
        return item.status == MediaStatus.completed;
    }
  }
}

/// Best-effort metadata helpers for [MediaItem]. [year] parses a release year
/// out of the title text (search results carry no such field) for the Newest
/// sort — [matchesGenre] does NOT parse titles, it compares against the
/// item's real, source-provided [MediaItem.genres]. Year is OPTIONAL: when it
/// can't be parsed, [SearchState]'s Newest sort treats the item as a
/// pass-through rather than dropping it.
class SearchMeta {
  SearchMeta._();

  /// Pulls a 4-digit release year out of a title (e.g. "Dune (2021)",
  /// "Some Show 2019"). Only accepts a plausible film/TV range so a stray
  /// number in a title (e.g. "Power Rangers 3000") doesn't masquerade as a year.
  static final RegExp _yearPattern = RegExp(r'(?:19|20)\d{2}');

  /// [maxYear] caps plausible years (default `DateTime.now().year + 1`).
  /// Callers sorting a whole list should compute it ONCE outside the loop
  /// instead of letting every call hit the system clock.
  static int? year(MediaItem item, {int? maxYear}) {
    final cap = maxYear ?? DateTime.now().year + 1;
    final matches = _yearPattern.allMatches(item.title);
    int? best;
    for (final m in matches) {
      final y = int.tryParse(m.group(0)!);
      if (y == null) continue;
      if (y < 1950 || y > cap) continue;
      // Prefer the latest plausible year if a title carries more than one.
      if (best == null || y > best) best = y;
    }
    return best;
  }

  /// True when [item] carries [genre] among its real (source-provided)
  /// genres, case-insensitively and trimmed. Used only when a genre filter is
  /// active. Items with no genre data never match a specific genre — that's
  /// what filtering means — see [SearchState.hasItemsWithoutGenre] for the
  /// UI's disclosure of that gap.
  static bool matchesGenre(MediaItem item, String genre) {
    final wanted = genre.trim().toLowerCase();
    return item.genres.any((g) => g.trim().toLowerCase() == wanted);
  }
}

/// Results from one source (provider), for grouped cross-source search.
class SourceResultGroup extends Equatable {
  const SourceResultGroup({
    required this.sourceId,
    required this.sourceName,
    required this.items,
    this.arrivalIndex = 0,
  });

  final String sourceId;
  final String sourceName;
  final List<MediaItem> items;

  /// Monotonic rank of WHEN this source's results landed (0 = arrived first).
  /// Drives CloudStream-style section ordering — fast/non-empty sources float to
  /// the top, slow ones sink — independently of the in-section item sort.
  final int arrivalIndex;

  SourceResultGroup withItems(List<MediaItem> items) => SourceResultGroup(
    sourceId: sourceId,
    sourceName: sourceName,
    items: items,
    arrivalIndex: arrivalIndex,
  );

  @override
  List<Object?> get props => [sourceId, sourceName, items, arrivalIndex];
}

/// Sentinel source-filter value meaning "all sources".
const String kAllSources = '__all__';

/// The provider ecosystem a source belongs to. Drives the phone Search
/// ecosystem tab strip (All · Zangetsu · CloudStream · Aniyomi). [all] is the
/// default "no filter" tab, not a real ecosystem.
enum SearchEcosystem {
  all('All'),
  zangetsu('Zangetsu'),
  cloudstream('CloudStream'),
  aniyomi('Aniyomi'),
  mihon('Mihon'),
  lnreader('LNReader');

  const SearchEcosystem(this.label);
  final String label;
}

/// Maps a [sourceId] to its ecosystem from the id prefix: `ani:` → Aniyomi,
/// `cs:` → CloudStream, anything else → Zangetsu (the app's own JS providers).
/// Never returns [SearchEcosystem.all] — that's the "no filter" tab.
SearchEcosystem ecosystemOf(String sourceId) {
  if (sourceId.startsWith('ani:')) return SearchEcosystem.aniyomi;
  if (sourceId.startsWith('cs:')) return SearchEcosystem.cloudstream;
  // Manga and novel extensions carry their own prefixes and belong to their own
  // ecosystems. Without these they fell through to Zangetsu, so a MangaDex
  // result sat under a tab labelled "Zangetsu" and no Mihon tab ever appeared.
  // A future ecosystem (Mangayomi, say) is one prefix and one enum value.
  if (sourceId.startsWith('mihon:')) return SearchEcosystem.mihon;
  if (sourceId.startsWith('lnr:')) return SearchEcosystem.lnreader;
  return SearchEcosystem.zangetsu;
}

/// The ecosystem tabs to offer for the given installed [sourceIds]. Always
/// leads with [SearchEcosystem.all]; each real ecosystem (Zangetsu, then
/// CloudStream, then Aniyomi) is included only when at least one installed
/// source belongs to it — so e.g. the Aniyomi tab never appears until an
/// Aniyomi source is installed.
List<SearchEcosystem> ecosystemTabsFor(Iterable<String> sourceIds) {
  final present = {for (final id in sourceIds) ecosystemOf(id)};
  return [
    SearchEcosystem.all,
    for (final e in const [
      SearchEcosystem.zangetsu,
      SearchEcosystem.cloudstream,
      SearchEcosystem.aniyomi,
      SearchEcosystem.mihon,
      SearchEcosystem.lnreader,
    ])
      if (present.contains(e)) e,
  ];
}

class SearchState extends Equatable {
  final SearchStatus status;
  final String query;

  /// Per-source result groups (cross-source search).
  final List<SourceResultGroup> groups;

  /// Active source-filter chip: [kAllSources] or a specific sourceId.
  final String sourceFilter;

  /// Active ecosystem tab (phone Search). [SearchEcosystem.all] (default) shows
  /// every ecosystem's groups together — identical to the pre-tabs behaviour;
  /// any other value narrows the rendered groups to that one ecosystem.
  final SearchEcosystem ecosystem;

  /// When true the search is scoped to ONLY the active Home source (the heavy
  /// search never fans out). When false the legacy multi-source search runs.
  final bool currentSourceOnly;

  final SearchSort sort;

  /// Active content-type filter (All / Anime / Movies & Series). Only
  /// meaningful — and only shown — in anime mode; see
  /// `searchTypeAudioGroupsVisible` in search_screen.dart.
  final SearchContentFilter contentFilter;

  /// Active audio filter (Any / Subbed / Dubbed). Anime mode only — see
  /// [SearchAudioFilter].
  final SearchAudioFilter audioFilter;

  /// Active genre filter, or null for "Any". Matched against
  /// [MediaItem.genres] — see [SearchMeta.matchesGenre]. A value that isn't
  /// (or is no longer) among [availableGenres] simply matches nothing rather
  /// than erroring; the UI keeps the "Any" pill reachable so it's always
  /// clearable.
  final String? genreFilter;

  /// Active publication-status filter (Any / Ongoing / Completed). Not
  /// mode-gated — see [SearchStatusFilter].
  final SearchStatusFilter statusFilter;

  final String? error;

  /// Trending titles for the idle screen (loaded once).
  final List<MediaItem> trending;

  /// Live title/history autocomplete shown under the field while typing.
  final List<String> suggestions;

  /// Per-source Aniyomi filter selections: maps `ani:` source ids to a
  /// selection JSON string produced by [AniyomiFilters.toSelectionJson].
  /// Only populated for `ani:` sources; non-Aniyomi ids are never present.
  final Map<String, String> aniFiltersBySource;

  /// Mihon twin of [aniFiltersBySource]: maps `mihon:` source ids to a
  /// selection JSON string produced by `MihonFilters.toSelectionJson`. Kept as
  /// a SEPARATE map (not a shared/renamed one) so a stored selection is always
  /// parsed back with the matching ecosystem's parser — the search screen
  /// picks `AniyomiFilters.parse` vs `MihonFilters.parse` by which map (and
  /// therefore which id prefix) the selection came from, never by guessing.
  final Map<String, String> mihonFiltersBySource;

  /// Ids of sources that have FINISHED responding for the current search run
  /// (ok, empty, or error) — independent of whether they actually produced a
  /// [SourceResultGroup]. Reset at the start of every run.
  ///
  /// [groups] alone can't drive the "still loading" skeletons: a source is
  /// only added to [groups] when it returns results, so a source that comes
  /// back empty (or errors) is indistinguishable from one that just hasn't
  /// answered yet — that gap is what left pending skeletons on screen forever
  /// for a source with zero results. This tracks completion regardless of
  /// outcome, so the UI can tell "no results yet" apart from "done, no
  /// results".
  final Set<String> respondedSources;

  /// Sources that FAILED this run, mapped to why (timeout / blocked / error).
  ///
  /// A failed source still answers, so it lands in [respondedSources] and its
  /// skeleton clears — but it contributes no [SourceResultGroup], which made a
  /// failure indistinguishable from "responded with nothing" and left the
  /// source silently missing from the results. Keeping the outcome is what lets
  /// the UI name the source and say how it broke.
  ///
  /// Reset at the start of every run, same as [respondedSources].
  final Map<String, SourceOutcome> failedSources;

  /// The sources this run actually QUERIED. Reset at the start of every run.
  ///
  /// The screen used to work out its "still searching" skeletons itself, from
  /// the enabled-source list — a guess that silently disagreed with what the
  /// bloc did. A source dropped by [SourceHealthStore.isSkippable] is never
  /// queried, so it never responds, so its skeleton sat on screen forever: no
  /// request was in flight for the per-source timeout to cap. Publishing the
  /// real list makes pending = queried − responded, which can't drift.
  final Set<String> queriedSources;

  /// Results of a filters-only browse — source filters applied with an empty
  /// search box. Aniyomi treats "no query + filters" as a normal search request
  /// and extensions implement it that way (a source's Sort/Genre/Year filters
  /// exist precisely for browsing), so this is how those filters reach a source
  /// at all: the idle screen's "Top picks" comes from `home()`, which has no
  /// filter argument.
  ///
  /// Empty means no filtered browse is active and the idle view renders exactly
  /// as it always has.
  final List<MediaItem> filteredBrowse;

  /// Source the [filteredBrowse] results came from; '' when inactive. Kept so
  /// the idle view can name the source and offer to clear it.
  final String filteredBrowseSourceId;

  /// Last page fetched for [filteredBrowse]; paging appends from here.
  final int filteredBrowsePage;

  /// A next page is in flight — stops the scroll listener firing repeatedly.
  final bool filteredBrowseLoadingMore;

  /// The source returned nothing more, so paging stops asking.
  final bool filteredBrowseAtEnd;

  /// Whether a filters-only browse is currently showing.
  bool get hasFilteredBrowse => filteredBrowse.isNotEmpty;

  /// Whether another page is worth requesting.
  bool get canLoadMoreFilteredBrowse =>
      hasFilteredBrowse && !filteredBrowseLoadingMore && !filteredBrowseAtEnd;

  SearchState({
    this.status = SearchStatus.idle,
    this.query = '',
    this.groups = const [],
    this.sourceFilter = kAllSources,
    this.ecosystem = SearchEcosystem.all,
    this.currentSourceOnly = true,
    this.sort = SearchSort.bestMatch,
    this.contentFilter = SearchContentFilter.all,
    this.audioFilter = SearchAudioFilter.any,
    this.genreFilter,
    this.statusFilter = SearchStatusFilter.any,
    this.error,
    this.trending = const [],
    this.suggestions = const [],
    this.aniFiltersBySource = const {},
    this.mihonFiltersBySource = const {},
    this.respondedSources = const {},
    this.failedSources = const {},
    this.queriedSources = const {},
    this.filteredBrowse = const [],
    this.filteredBrowseSourceId = '',
    this.filteredBrowsePage = 1,
    this.filteredBrowseLoadingMore = false,
    this.filteredBrowseAtEnd = false,
  });

  /// True when any client-side filter narrows the results (drives the active
  /// tint on the filter button and the "no results — clear filters" hint).
  /// Deliberately excludes [sort] — a sort choice reorders, never narrows.
  bool get hasActiveFilter =>
      contentFilter != SearchContentFilter.all ||
      audioFilter != SearchAudioFilter.any ||
      genreFilter != null ||
      statusFilter != SearchStatusFilter.any;

  /// Count of non-default selections across the whole merged Filters sheet —
  /// [sort] included, unlike [hasActiveFilter] — for the sheet header/toolbar
  /// badge. Sort used to tint its own separate icon; now that it lives in the
  /// same sheet, a non-default sort still needs a visible signal somewhere.
  int get activeFilterCount =>
      (sort != SearchSort.bestMatch ? 1 : 0) +
      (contentFilter != SearchContentFilter.all ? 1 : 0) +
      (audioFilter != SearchAudioFilter.any ? 1 : 0) +
      (genreFilter != null ? 1 : 0) +
      (statusFilter != SearchStatusFilter.any ? 1 : 0);

  /// Applies the content-type + audio + genre + status filters to [item].
  bool _passes(MediaItem item) {
    if (!contentFilter.matches(item)) return false;
    if (!audioFilter.matches(item)) return false;
    if (genreFilter != null && !SearchMeta.matchesGenre(item, genreFilter!)) {
      return false;
    }
    if (!statusFilter.matches(item)) return false;
    return true;
  }

  /// True when [sourceId]'s ecosystem matches the active tab. The default "All"
  /// tab matches every ecosystem, so nothing is filtered — keeping the All view
  /// byte-for-byte identical to the pre-tabs behaviour.
  bool _inEcosystem(String sourceId) =>
      ecosystem == SearchEcosystem.all || ecosystemOf(sourceId) == ecosystem;

  /// Total results across every source in the active ecosystem, honouring all
  /// client-side filters.
  int get totalCount => groups.fold(
    0,
    (sum, g) =>
        sum + (_inEcosystem(g.sourceId) ? g.items.where(_passes).length : 0),
  );

  /// Result count for one source group under the active filters.
  int countFor(SourceResultGroup g) => g.items.where(_passes).length;

  /// Genre pills to offer in the filter sheet, derived from the actual result
  /// set instead of a fixed list — a genre is only worth offering if some
  /// result can actually match it. De-duplicated case-insensitively (first-seen
  /// capitalisation wins), sorted alphabetically, capped at 20 so an unusually
  /// genre-rich result set can't turn the sheet into a wall of chips.
  List<String> get availableGenres {
    final byLower = <String, String>{};
    for (final g in groups) {
      for (final item in g.items) {
        for (final genre in item.genres) {
          final trimmed = genre.trim();
          if (trimmed.isEmpty) continue;
          byLower.putIfAbsent(trimmed.toLowerCase(), () => trimmed);
        }
      }
    }
    final sorted = byLower.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted.take(20).toList();
  }

  /// True when at least one result across all groups has no genre data.
  /// Sources vary in whether they supply genres at all, so when a genre
  /// filter is active this drives a small disclosure under the pills — an
  /// active filter silently drops whole sources with no genre data, and this
  /// says so instead of leaving that unexplained.
  bool get hasItemsWithoutGenre =>
      groups.any((g) => g.items.any((item) => item.genres.isEmpty));

  /// True when at least one result across all groups carries a (real, source-
  /// reported) publication status — see [MediaItem.status]. Drives whether the
  /// filter sheet's Status group shows at all: most sources never set it, and a
  /// filter that mostly matches nothing is exactly what this group must avoid.
  bool get hasAnyStatus =>
      groups.any((g) => g.items.any((item) => item.status != null));

  /// True when at least one result reports a sub or dub count. Same reasoning
  /// as [hasAnyStatus]: movie-oriented sources never set these, so on a result
  /// set built from them the Audio group would sit there offering Subbed and
  /// Dubbed and empty the list either way.
  bool get hasAnyAudio => groups.any(
    (g) => g.items.any(
      (item) => (item.subCount ?? 0) > 0 || (item.dubCount ?? 0) > 0,
    ),
  );

  /// Result groups (in the active ecosystem) that have at least one item under
  /// the active filters.
  List<SourceResultGroup> get visibleGroups => [
    for (final g in groups)
      if (_inEcosystem(g.sourceId) && countFor(g) > 0) g,
  ];

  /// Groups in the active ecosystem whose SOURCE returned at least one result,
  /// IGNORING the content/audio/genre filters. Drives the source-filter chip
  /// row so it (and the selected chip) stays put even when a filter empties the
  /// current view — otherwise selecting a chip that yields nothing would hide
  /// the very chips you'd use to change or clear it.
  ///
  /// Whenever there's a query, chips are ordered best-matching-source first —
  /// the SAME order as [sortedVisibleGroups] — so the first chip lines up with
  /// the top row. This is independent of [sort]: item sort governs the order
  /// of items INSIDE a section, not which source's chip/section leads. Ties
  /// keep arrival order; an empty query keeps pure arrival order.
  List<SourceResultGroup> get sourceChipGroups {
    final raw = [
      for (final g in groups)
        if (_inEcosystem(g.sourceId) && g.items.isNotEmpty) g,
    ];
    if (query.trim().isEmpty) return raw;
    final m = _queryMatch;
    final score = {for (final g in raw) g.sourceId: _bestScore(g.items, m)};
    // Decorate with the original (arrival) index so equal scores stay put.
    final indexed = [for (var i = 0; i < raw.length; i++) (g: raw[i], i: i)];
    indexed.sort((a, b) {
      final c = score[b.g.sourceId]!.compareTo(score[a.g.sourceId]!);
      return c != 0 ? c : a.i.compareTo(b.i);
    });
    return [for (final e in indexed) e.g];
  }

  /// Per-source groups, each already filtered + sorted. With a query, SECTION
  /// order leads with the best-matching source (see below); with an empty
  /// query it's CloudStream-style ARRIVAL order — the source that returned
  /// results first sits at the top, slower sources below. Either way this
  /// section order is independent of the in-section item sort. Honours the
  /// active source-filter chip.
  List<SourceResultGroup> get sortedVisibleGroups {
    final out = <SourceResultGroup>[];
    for (final g in groups) {
      if (!_inEcosystem(g.sourceId)) continue;
      if (sourceFilter != kAllSources && g.sourceId != sourceFilter) continue;
      final items = _sortItems(g.items.where(_passes).toList());
      if (items.isEmpty) continue;
      out.add(g.withItems(items));
    }
    // Section order. Whenever there's a query, lead with the source whose best
    // result most closely matches it (relevance-first), and fall back to
    // arrival order for sources that match equally well — so the common case
    // where several sources all have the exact title keeps today's
    // fast-source-first feel and nothing reshuffles. This is independent of
    // [sort]: item sort governs the order of items INSIDE a section (applied
    // above via _sortItems), not section order — see [sourceChipGroups],
    // which this stays in lockstep with. An empty query keeps pure arrival
    // order.
    if (query.trim().isNotEmpty) {
      // Score each section's best match ONCE, then sort — cheaper than
      // rescoring inside the comparator.
      final m = _queryMatch;
      final score = <String, double>{
        for (final g in out) g.sourceId: _bestScore(g.items, m),
      };
      out.sort((a, b) {
        final ra = score[a.sourceId]!;
        final rb = score[b.sourceId]!;
        if (ra != rb) return rb.compareTo(ra); // better-matching source first
        return a.arrivalIndex.compareTo(b.arrivalIndex); // else fastest first
      });
    } else {
      out.sort((a, b) => a.arrivalIndex.compareTo(b.arrivalIndex));
    }
    return out;
  }

  /// A section's relevance = the best [_scoreItem] among its items.
  double _bestScore(
    List<MediaItem> items,
    ({String q, List<String> tokens}) m,
  ) {
    var best = 0.0;
    for (final e in items) {
      final s = _scoreItem(e, m);
      if (s > best) best = s;
    }
    return best;
  }

  /// Flat results for the selected source + filters, with the current sort
  /// applied. Used by the legacy flat grid path.
  List<MediaItem> get visibleResults {
    final base = <MediaItem>[
      for (final g in groups)
        if (_inEcosystem(g.sourceId) &&
            (sourceFilter == kAllSources || g.sourceId == sourceFilter))
          for (final item in g.items)
            if (_passes(item)) item,
    ];
    return _sortItems(base);
  }

  static final RegExp _wordSplit = RegExp(r'[^a-z0-9]+');

  /// The query normalised for exact/prefix/substring checks plus its word
  /// tokens — computed ONCE per sort pass and reused across items, instead of
  /// re-normalising the query for every result on every rebuild.
  ({String q, List<String> tokens}) get _queryMatch => (
    q: normalizeTitle(query),
    tokens: query
        .toLowerCase()
        .split(_wordSplit)
        .where((w) => w.isNotEmpty)
        .toList(),
  );

  /// Memo of [_scoreItem] results for this SearchState instance. Three
  /// separate passes (sortedVisibleGroups' item sort, its section-order pass,
  /// and sourceChipGroups) each score the same items from scratch per
  /// rebuild — this makes the 2nd and 3rd pass free.
  ///
  /// Keyed on (sourceId, url) rather than the MediaItem itself: MediaItem is
  /// Equatable and usable as a map key, but its hashCode walks all 16 props
  /// via equatable's Jenkins-hash combiner, including `coverHeaders` (a Map —
  /// the combiner SORTS its keys on every single hashCode call) and `genres`
  /// (a List, hashed element-by-element). That's real work on every lookup.
  /// (sourceId, url) is a Dart record of two Strings — cheap structural
  /// hashing — and already uniquely identifies a result within one state.
  ///
  /// Safe to scope to the instance: SearchState is immutable and rebuilt (a
  /// new instance via copyWith) on every emission, and `query` — which
  /// `_queryMatch`/[m] is derived from — never changes on an existing
  /// instance, so a score cached here can't go stale under it.
  final Map<(String, String), double> _scoreCache = {};

  /// Relevance of [item] to a precomputed query match [m], 0–100 (higher =
  /// better). Scores against BOTH the source title and the English title and
  /// keeps the best: exact match wins, then prefix, then substring, then the
  /// fraction of query words present. An empty (e.g. non-Latin) query scores 0,
  /// so nothing reshuffles.
  double _scoreItem(MediaItem item, ({String q, List<String> tokens}) m) =>
      _scoreCache[(item.sourceId, item.url)] ??= _scoreItemUncached(item, m);

  double _scoreItemUncached(
    MediaItem item,
    ({String q, List<String> tokens}) m,
  ) {
    if (m.q.isEmpty) return 0;
    double scoreOf(String? cand) {
      if (cand == null) return 0;
      final t = normalizeTitle(cand);
      if (t.isEmpty) return 0;
      if (t == m.q) return 100; // exact
      if (t.startsWith(m.q)) return 80; // prefix
      if (t.contains(m.q)) return 60; // substring
      if (m.tokens.isEmpty) return 0;
      final matched = m.tokens.where(t.contains).length;
      if (matched == m.tokens.length) return 40; // all words present
      return matched / m.tokens.length * 30; // partial word overlap
    }

    final a = scoreOf(item.title);
    final b = scoreOf(item.englishTitle);
    return a > b ? a : b;
  }

  /// Applies [sort] to a list of items. Best-match ranks by query relevance;
  /// newest falls back to title order for items lacking a parseable year so
  /// the list stays stable rather than reshuffling unparseable items around.
  List<MediaItem> _sortItems(List<MediaItem> items) {
    switch (sort) {
      case SearchSort.bestMatch:
        // Rank by how well each title matches the query, keeping the source's
        // own order on ties (source order is itself a relevance signal). An
        // empty query leaves the list untouched.
        if (query.trim().isEmpty) return items;
        final m = _queryMatch;
        final scored = [
          for (var i = 0; i < items.length; i++)
            (item: items[i], index: i, score: _scoreItem(items[i], m)),
        ];
        scored.sort((a, b) {
          final c = b.score.compareTo(a.score);
          return c != 0 ? c : a.index.compareTo(b.index);
        });
        return [for (final s in scored) s.item];
      case SearchSort.titleAsc:
        return items..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case SearchSort.titleDesc:
        return items..sort(
          (a, b) => b.title.toLowerCase().compareTo(a.title.toLowerCase()),
        );
      case SearchSort.newest:
        // Computed once for the whole sort instead of once per comparison —
        // SearchMeta.year() no longer hits DateTime.now() internally.
        final maxYear = DateTime.now().year + 1;
        return items..sort((a, b) {
          final ya = SearchMeta.year(a, maxYear: maxYear);
          final yb = SearchMeta.year(b, maxYear: maxYear);
          if (ya == null && yb == null) {
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          if (ya == null) return 1; // unknown years sink to the bottom
          if (yb == null) return -1;
          return yb.compareTo(ya);
        });
    }
  }

  /// Stored per-source filter selection JSON for [sourceId], regardless of
  /// ecosystem — looks in [mihonFiltersBySource] for `mihon:` ids and
  /// [aniFiltersBySource] for everything else (only ever Aniyomi ids in
  /// practice). Used by the bloc's cross-source search fan-out and filtered
  /// browse, which forward whatever selection is stored without caring which
  /// ecosystem it came from.
  String? filterSelectionFor(String sourceId) => sourceId.startsWith('mihon:')
      ? mihonFiltersBySource[sourceId]
      : aniFiltersBySource[sourceId];

  SearchState copyWith({
    SearchStatus? status,
    String? query,
    List<SourceResultGroup>? groups,
    String? sourceFilter,
    SearchEcosystem? ecosystem,
    bool? currentSourceOnly,
    SearchSort? sort,
    SearchContentFilter? contentFilter,
    SearchAudioFilter? audioFilter,
    String? genreFilter,
    bool clearGenreFilter = false,
    SearchStatusFilter? statusFilter,
    String? error,
    bool clearError = false,
    List<MediaItem>? trending,
    List<String>? suggestions,
    Map<String, String>? aniFiltersBySource,
    Map<String, String>? mihonFiltersBySource,
    Set<String>? respondedSources,
    Map<String, SourceOutcome>? failedSources,
    Set<String>? queriedSources,
    List<MediaItem>? filteredBrowse,
    String? filteredBrowseSourceId,
    int? filteredBrowsePage,
    bool? filteredBrowseLoadingMore,
    bool? filteredBrowseAtEnd,
  }) => SearchState(
    status: status ?? this.status,
    query: query ?? this.query,
    groups: groups ?? this.groups,
    sourceFilter: sourceFilter ?? this.sourceFilter,
    ecosystem: ecosystem ?? this.ecosystem,
    currentSourceOnly: currentSourceOnly ?? this.currentSourceOnly,
    sort: sort ?? this.sort,
    contentFilter: contentFilter ?? this.contentFilter,
    audioFilter: audioFilter ?? this.audioFilter,
    genreFilter: clearGenreFilter ? null : (genreFilter ?? this.genreFilter),
    statusFilter: statusFilter ?? this.statusFilter,
    error: clearError ? null : (error ?? this.error),
    trending: trending ?? this.trending,
    suggestions: suggestions ?? this.suggestions,
    aniFiltersBySource: aniFiltersBySource ?? this.aniFiltersBySource,
    mihonFiltersBySource: mihonFiltersBySource ?? this.mihonFiltersBySource,
    respondedSources: respondedSources ?? this.respondedSources,
    failedSources: failedSources ?? this.failedSources,
    queriedSources: queriedSources ?? this.queriedSources,
    filteredBrowse: filteredBrowse ?? this.filteredBrowse,
    filteredBrowseSourceId:
        filteredBrowseSourceId ?? this.filteredBrowseSourceId,
    filteredBrowsePage: filteredBrowsePage ?? this.filteredBrowsePage,
    filteredBrowseLoadingMore:
        filteredBrowseLoadingMore ?? this.filteredBrowseLoadingMore,
    filteredBrowseAtEnd: filteredBrowseAtEnd ?? this.filteredBrowseAtEnd,
  );

  @override
  List<Object?> get props => [
    status,
    query,
    groups,
    sourceFilter,
    ecosystem,
    currentSourceOnly,
    sort,
    contentFilter,
    audioFilter,
    genreFilter,
    statusFilter,
    error,
    trending,
    suggestions,
    aniFiltersBySource,
    mihonFiltersBySource,
    respondedSources,
    failedSources,
    queriedSources,
    filteredBrowse,
    filteredBrowseSourceId,
    filteredBrowsePage,
    filteredBrowseLoadingMore,
    filteredBrowseAtEnd,
  ];
}
