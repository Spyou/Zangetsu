import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/stremio/stremio_poster_shape.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/reveal_item.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';
import '../search/meta_filter_sheet.dart';
import 'see_all_screen_tv.dart';

/// Full-grid view of a single home row ("See All"). Reuses the home's tap /
/// long-press handlers so an item opens the same Detail / info card.
///
/// When [onLoadMore] is provided the grid paginates: scrolling near the bottom
/// fetches the next page and appends it (infinite scroll). When it's null the
/// grid is a fixed list over [items] — byte-for-byte the pre-pagination
/// behaviour, so search / JS / non-paginating callers are unchanged.
class SeeAllScreen extends StatefulWidget {
  const SeeAllScreen({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onLongPress,
    this.tagsFor,
    this.onLoadMore,
    this.onSearch,
    this.filterKind,
    this.initialFilters = const MetaFilters(),
  });

  final String title;
  final List<MediaItem> items;
  final void Function(MediaItem) onTap;
  final void Function(MediaItem)? onLongPress;

  /// Optional per-item poster badges (e.g. SUB/DUB/MOVIE). When null no tags are
  /// drawn — keeps the home "See All" callers unchanged.
  final List<String> Function(MediaItem)? tagsFor;

  /// Optional next-page fetcher for infinite scroll. `page` is 1-based and the
  /// initial [items] ARE page 1, so the first call requests page 2. Returning an
  /// empty list (or only already-seen items) ends pagination. Null → fixed list.
  final Future<List<MediaItem>> Function(int page)? onLoadMore;

  /// Optional query/filter fetcher. When set, the app bar exposes search and
  /// filters and the grid can be refreshed without leaving this page.
  final Future<MediaItemPage> Function(
    String query,
    MetaFilters filters,
    int page,
  )?
  onSearch;
  final ZKind? filterKind;
  final MetaFilters initialFilters;

  @override
  State<SeeAllScreen> createState() => _SeeAllScreenState();
}

class _SeeAllScreenState extends State<SeeAllScreen> {
  late final List<MediaItem> _items = [...widget.items];
  final Set<String> _seen = {};
  final ScrollController _controller = ScrollController();

  /// The last page already loaded — the initial [items] are page 1.
  int _page = 1;
  bool _loading = false;
  bool _end = false;
  bool _showNextPage = false;
  bool _searching = false;
  int _queryGeneration = 0;
  late MetaFilters _filters;
  final TextEditingController _queryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filters = widget.initialFilters;
    for (final it in _items) {
      _seen.add(_keyOf(it));
    }
    if (widget.onLoadMore != null || widget.onSearch != null) {
      _controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _queryController.dispose();
    super.dispose();
  }

  /// Dedupe key — prefer the stable id, fall back to the url.
  String _keyOf(MediaItem m) => m.id.isNotEmpty ? m.id : m.url;

  void _onScroll() {
    if (_loading || _end || !_controller.hasClients) return;
    final pos = _controller.position;
    if (pos.pixels >= pos.maxScrollExtent * 0.8) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final loader = widget.onLoadMore;
    if ((loader == null && widget.onSearch == null) || _loading || _end) {
      return;
    }
    final generation = _queryGeneration;
    setState(() {
      _loading = true;
      _showNextPage = false;
    });
    List<MediaItem> next = const [];
    MediaItemPage? searchPage;
    try {
      if (widget.onSearch != null) {
        searchPage = await widget.onSearch!(
          _queryController.text.trim(),
          _filters,
          _page + 1,
        );
        next = searchPage.items;
      } else {
        next = await loader!(_page + 1);
      }
    } catch (_) {
      next = const [];
    }
    if (!mounted || generation != _queryGeneration) return;
    final fresh = <MediaItem>[];
    for (final it in next) {
      final k = _keyOf(it);
      if (_seen.add(k)) fresh.add(it);
    }
    setState(() {
      _loading = false;
      if (searchPage != null) {
        _page += 1;
        _items.addAll(fresh);
        _end = !searchPage.hasMore;
        _showNextPage = searchPage.hasMore;
      } else if (fresh.isEmpty) {
        // Nothing new (empty page or all duplicates) → we've hit the end.
        _end = true;
      } else {
        _items.addAll(fresh);
        _page += 1;
      }
    });
  }

  Future<void> _runQuery(String query) async {
    final search = widget.onSearch;
    if (search == null) return;
    final generation = ++_queryGeneration;
    setState(() {
      _items.clear();
      _seen.clear();
      _page = 1;
      _end = false;
      _loading = true;
      _showNextPage = false;
    });
    var first = const MediaItemPage(items: <MediaItem>[], hasMore: false);
    try {
      first = await search(query.trim(), _filters, 1);
    } catch (_) {
      first = const MediaItemPage(items: <MediaItem>[], hasMore: false);
    }
    if (!mounted || generation != _queryGeneration) return;
    final fresh = <MediaItem>[];
    for (final item in first.items) {
      if (_seen.add(_keyOf(item))) fresh.add(item);
    }
    setState(() {
      _items.addAll(fresh);
      _loading = false;
      _end = !first.hasMore;
      _showNextPage = first.hasMore;
    });
  }

  Future<void> _openFilters() async {
    final kind = widget.filterKind;
    if (kind == null) return;
    final picked = await showMetaFilterSheet(
      context,
      kind,
      _filters,
      showStatus: false,
    );
    if (!mounted || picked == null) return;
    setState(() => _filters = picked);
    await _runQuery(_queryController.text);
  }

  void _toggleSearch() {
    if (!_searching) {
      setState(() => _searching = true);
      return;
    }
    final hadQuery = _queryController.text.trim().isNotEmpty;
    _queryController.clear();
    FocusScope.of(context).unfocus();
    setState(() => _searching = false);
    if (hadQuery) _runQuery('');
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) {
      return SeeAllScreenTv(
        title: widget.title,
        items: widget.items,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        tagsFor: widget.tagsFor,
        onLoadMore: widget.onLoadMore,
        onSearch: widget.onSearch,
        filterKind: widget.filterKind,
        initialFilters: widget.initialFilters,
      );
    }
    final cellW = posterGridCellWidth(context);
    final aspects = [
      for (final item in _items)
        stremioPosterAspect(
          item,
          landscape: posterLayout(context) == PosterCardLayout.wide,
        ),
    ];
    final heights = [
      for (var i = 0; i < aspects.length; i++)
        aspects[i] == null
            ? cellW / posterGridAspect(context)
            : posterCellHeight(
                cellW,
                artAspectRatio: aspects[i],
                textScaler: MediaQuery.textScalerOf(context),
                titleInside: posterTitleInside(
                  context,
                  wide: aspects[i]! > 1,
                  item: _items[i],
                ),
              ),
    ];
    final gridHeight = heights.fold<double>(0, (a, b) => a > b ? a : b);

    final paginating = widget.onLoadMore != null || widget.onSearch != null;
    // A trailing spinner cell spanning the full row while a page is loading.
    final showSpinner = paginating && _loading;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: _searching
            ? TextField(
                key: const ValueKey('see-all-search-field'),
                controller: _queryController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: context.l10n.search2,
                  border: InputBorder.none,
                  isDense: true,
                ),
                onSubmitted: _runQuery,
              )
            : Text(widget.title, style: AppText.headline),
        actions: widget.onSearch == null
            ? null
            : [
                IconButton(
                  key: const ValueKey('see-all-search'),
                  tooltip: context.l10n.search2,
                  onPressed: _toggleSearch,
                  icon: Icon(
                    _searching ? Icons.close_rounded : Icons.search_rounded,
                  ),
                ),
                IconButton(
                  key: const ValueKey('see-all-filter'),
                  tooltip: context.l10n.filters,
                  onPressed: _openFilters,
                  icon: Icon(
                    Icons.filter_list_rounded,
                    color: _filters.isEmpty ? null : AppColors.accent,
                  ),
                ),
              ],
      ),
      body: widget.onSearch != null && _items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loading)
                    const CircularProgressIndicator()
                  else
                    Text(context.l10n.noResults),
                  if (_showNextPage && !_loading) ...[
                    const SizedBox(height: 12),
                    TextButton.icon(
                      key: const ValueKey('see-all-next-page'),
                      onPressed: _loadMore,
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: Text(context.l10n.next),
                    ),
                  ],
                ],
              ),
            )
          : GridView.builder(
              controller: paginating ? _controller : null,
              padding: const EdgeInsets.all(16),
              cacheExtent: 800,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: posterGridColumns(context),
                childAspectRatio: gridHeight > 0
                    ? cellW / gridHeight
                    : posterGridAspect(context),
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
              ),
              itemCount: _items.length,
              itemBuilder: (context, i) {
                final item = _items[i];
                return RevealItem(
                  index: i,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      height: heights[i],
                      child: PosterCard(
                        title: item.title,
                        logoItem: item,
                        imageUrl: item.cover,
                        wideImageUrl: item.banner,
                        genres: item.genres,
                        isAdult: item.isAdult,
                        headers: item.coverHeaders,
                        tags: widget.tagsFor?.call(item) ?? const [],
                        qualityBadge: item.quality,
                        scoreBadge: item.score,
                        dubBadge: item.dubBadge,
                        cellWidth: cellW,
                        wideOverride: aspects[i] == null
                            ? null
                            : aspects[i]! > 1,
                        onTap: () => widget.onTap(item),
                        onLongPress: widget.onLongPress == null
                            ? null
                            : () => widget.onLongPress!(item),
                      ),
                    ),
                  ),
                );
              },
            ),
      // Bottom loading indicator while the next page is in flight. Only rendered
      // in the paginating configuration, so non-paginating callers are unchanged.
      bottomNavigationBar: showSpinner && _items.isNotEmpty
          ? const SizedBox(
              height: 48,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : _showNextPage && _items.isNotEmpty
          ? SizedBox(
              height: 56,
              child: Center(
                child: TextButton.icon(
                  key: const ValueKey('see-all-next-page'),
                  onPressed: _loadMore,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: Text(context.l10n.next),
                ),
              ),
            )
          : null,
    );
  }
}
