import 'media_item.dart';

/// One named row on the Home screen, CloudStream-style: the provider decides
/// what sections exist and what they are called (e.g. "Trending Now",
/// "Action & Adventure"), and the UI renders whatever it returns. A provider
/// that returns no sections (or has no `getHome`) falls back to a default set
/// built from `popular()` — see [SourceRepository.home].
class HomeSection {
  const HomeSection({required this.title, required this.items, this.more});

  final String title;
  final List<MediaItem> items;

  /// Optional paging descriptor. When non-null the "See all" grid for this row
  /// can fetch further pages (infinite scroll) via [SourceRepository.browseMore].
  /// Null means the row is NOT paginable (search results, JS providers, the
  /// synthesized fallback rows) → the "See all" grid stays a fixed list, exactly
  /// as before this feature existed.
  final BrowseMore? more;
}

/// Describes how to fetch the NEXT page of a paginable [HomeSection], so the
/// "See all" browse grid can append more items as the user scrolls.
///
/// It's an opaque handle the repository knows how to route: [sourceId] selects
/// the provider, [kind] selects the paging endpoint, and [categoryId] carries
/// any extra identifier that endpoint needs.
class BrowseMore {
  const BrowseMore({
    required this.sourceId,
    required this.kind,
    this.categoryId,
  });

  /// The provider that owns this row (e.g. `ani:<id>` or `cs:<name>`).
  final String sourceId;

  /// Which paging endpoint to call:
  ///   * `ani_popular`  — Aniyomi popular feed
  ///   * `ani_latest`   — Aniyomi latest feed
  ///   * `cs_mainpage`  — a CloudStream `mainPage` category
  final String kind;

  /// For `cs_mainpage`: the packed mainPage category (`"<name> <data>"`).
  /// Null for the Aniyomi kinds, which need no extra identifier.
  final String? categoryId;
}
