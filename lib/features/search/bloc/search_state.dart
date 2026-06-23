import 'package:equatable/equatable.dart';

import '../../../core/models/media_item.dart';
import '../../../core/models/provider_info.dart';

enum SearchStatus { idle, loading, success, error }

enum SearchSort {
  bestMatch('Best match'),
  newest('Newest'),
  titleAsc('Title A–Z'),
  titleDesc('Title Z–A'),
  rating('Rating');

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

/// Best-effort metadata helpers for [MediaItem]. The search-result model carries
/// no year/genre/rating fields (those only land on the on-demand [MediaDetail]),
/// so we derive what we can from the title text. Everything here is OPTIONAL:
/// when a value can't be parsed the relevant filter/sort treats the item as a
/// pass-through rather than dropping it.
class SearchMeta {
  SearchMeta._();

  /// Pulls a 4-digit release year out of a title (e.g. "Dune (2021)",
  /// "Some Show 2019"). Only accepts a plausible film/TV range so a stray
  /// number in a title (e.g. "Power Rangers 3000") doesn't masquerade as a year.
  static int? year(MediaItem item) {
    final matches = RegExp(r'(?:19|20)\d{2}').allMatches(item.title);
    int? best;
    for (final m in matches) {
      final y = int.tryParse(m.group(0)!);
      if (y == null) continue;
      if (y < 1950 || y > DateTime.now().year + 1) continue;
      // Prefer the latest plausible year if a title carries more than one.
      if (best == null || y > best) best = y;
    }
    return best;
  }

  /// Genre keywords offered in the filter sheet. Genre data isn't present on
  /// search results, so the filter is applied best-effort by matching the
  /// keyword against the title; items whose title doesn't mention the genre
  /// still pass when the filter is "Any".
  static const List<String> genres = [
    'Action',
    'Adventure',
    'Comedy',
    'Drama',
    'Fantasy',
    'Horror',
    'Romance',
    'Sci-Fi',
    'Thriller',
  ];

  /// Best-effort genre match: true when the title mentions [genre]
  /// (case-insensitive). Used only when a genre filter is active.
  static bool titleMentionsGenre(MediaItem item, String genre) {
    return item.title.toLowerCase().contains(genre.toLowerCase());
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

class SearchState extends Equatable {
  final SearchStatus status;
  final String query;

  /// Per-source result groups (cross-source search).
  final List<SourceResultGroup> groups;

  /// Active source-filter chip: [kAllSources] or a specific sourceId.
  final String sourceFilter;

  final SearchSort sort;

  /// Active content-type filter (All / Anime / Movies & Series).
  final SearchContentFilter contentFilter;

  /// Active genre keyword filter, or null for "Any" (best-effort — see
  /// [SearchMeta.titleMentionsGenre]).
  final String? genreFilter;

  /// Active decade filter as a start year (e.g. 2020 → 2020–2029), or null for
  /// "Any". Best-effort, keyed off [SearchMeta.year].
  final int? decadeFilter;

  final String? error;

  /// Trending titles for the idle screen (loaded once).
  final List<MediaItem> trending;

  /// Live title/history autocomplete shown under the field while typing.
  final List<String> suggestions;

  const SearchState({
    this.status = SearchStatus.idle,
    this.query = '',
    this.groups = const [],
    this.sourceFilter = kAllSources,
    this.sort = SearchSort.bestMatch,
    this.contentFilter = SearchContentFilter.all,
    this.genreFilter,
    this.decadeFilter,
    this.error,
    this.trending = const [],
    this.suggestions = const [],
  });

  /// True when any client-side filter narrows the results (drives the active
  /// tint on the filter button).
  bool get hasActiveFilter =>
      contentFilter != SearchContentFilter.all ||
      genreFilter != null ||
      decadeFilter != null;

  /// Applies the content-type + genre + decade filters to [item].
  bool _passes(MediaItem item) {
    if (!contentFilter.matches(item)) return false;
    if (genreFilter != null && !SearchMeta.titleMentionsGenre(item, genreFilter!)) {
      return false;
    }
    if (decadeFilter != null) {
      final y = SearchMeta.year(item);
      // Best-effort: items with no parseable year pass through rather than
      // vanishing — only items KNOWN to be outside the decade are dropped.
      if (y != null && (y < decadeFilter! || y >= decadeFilter! + 10)) {
        return false;
      }
    }
    return true;
  }

  /// Total results across every source, honouring all client-side filters.
  int get totalCount =>
      groups.fold(0, (sum, g) => sum + g.items.where(_passes).length);

  /// Result count for one source group under the active filters.
  int countFor(SourceResultGroup g) => g.items.where(_passes).length;

  /// Result groups that have at least one item under the active filters.
  List<SourceResultGroup> get visibleGroups =>
      [for (final g in groups) if (countFor(g) > 0) g];

  /// Per-source groups, each already filtered + sorted, ordered CloudStream-style
  /// by ARRIVAL: the source that returned results first sits at the top, slower
  /// sources below. This SECTION order is independent of the in-section item
  /// sort. Honours the active source-filter chip.
  List<SourceResultGroup> get sortedVisibleGroups {
    final out = <SourceResultGroup>[];
    for (final g in groups) {
      if (sourceFilter != kAllSources && g.sourceId != sourceFilter) continue;
      final items = _sortItems(g.items.where(_passes).toList());
      if (items.isEmpty) continue;
      out.add(g.withItems(items));
    }
    // Stable arrival-order sort: earlier-arrived sources first. List.sort is not
    // guaranteed stable, so tie-break on arrivalIndex equality is moot here since
    // each source has a distinct index.
    out.sort((a, b) => a.arrivalIndex.compareTo(b.arrivalIndex));
    return out;
  }

  /// Flat results for the selected source + filters, with the current sort
  /// applied. Used by the legacy flat grid path.
  List<MediaItem> get visibleResults {
    final base = <MediaItem>[
      for (final g in groups)
        if (sourceFilter == kAllSources || g.sourceId == sourceFilter)
          for (final item in g.items)
            if (_passes(item)) item,
    ];
    return _sortItems(base);
  }

  /// Applies [sort] to a list of items. Best-match preserves source order;
  /// newest/rating fall back to title order for items lacking the data so the
  /// list stays stable rather than reshuffling unparseable items to the bottom.
  List<MediaItem> _sortItems(List<MediaItem> items) {
    switch (sort) {
      case SearchSort.bestMatch:
        return items;
      case SearchSort.titleAsc:
        return items
          ..sort((a, b) =>
              a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case SearchSort.titleDesc:
        return items
          ..sort((a, b) =>
              b.title.toLowerCase().compareTo(a.title.toLowerCase()));
      case SearchSort.newest:
        return items
          ..sort((a, b) {
            final ya = SearchMeta.year(a);
            final yb = SearchMeta.year(b);
            if (ya == null && yb == null) {
              return a.title.toLowerCase().compareTo(b.title.toLowerCase());
            }
            if (ya == null) return 1; // unknown years sink to the bottom
            if (yb == null) return -1;
            return yb.compareTo(ya);
          });
      case SearchSort.rating:
        // No rating on search results — keep deterministic (title) order so the
        // option is wired without inventing a value. Best-effort by design.
        return items
          ..sort((a, b) =>
              a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
  }

  SearchState copyWith({
    SearchStatus? status,
    String? query,
    List<SourceResultGroup>? groups,
    String? sourceFilter,
    SearchSort? sort,
    SearchContentFilter? contentFilter,
    String? genreFilter,
    bool clearGenreFilter = false,
    int? decadeFilter,
    bool clearDecadeFilter = false,
    String? error,
    bool clearError = false,
    List<MediaItem>? trending,
    List<String>? suggestions,
  }) => SearchState(
    status: status ?? this.status,
    query: query ?? this.query,
    groups: groups ?? this.groups,
    sourceFilter: sourceFilter ?? this.sourceFilter,
    sort: sort ?? this.sort,
    contentFilter: contentFilter ?? this.contentFilter,
    genreFilter: clearGenreFilter ? null : (genreFilter ?? this.genreFilter),
    decadeFilter: clearDecadeFilter ? null : (decadeFilter ?? this.decadeFilter),
    error: clearError ? null : (error ?? this.error),
    trending: trending ?? this.trending,
    suggestions: suggestions ?? this.suggestions,
  );

  @override
  List<Object?> get props => [
        status,
        query,
        groups,
        sourceFilter,
        sort,
        contentFilter,
        genreFilter,
        decadeFilter,
        error,
        trending,
        suggestions,
      ];
}
