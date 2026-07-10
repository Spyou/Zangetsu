import 'package:flutter/material.dart';

import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/ui/poster_card.dart';

/// TV variant of [SeeAllScreen]: a full-screen D-pad-navigable poster grid.
///
/// Constructor is byte-compatible with [SeeAllScreen] so the caller's
/// `if (isTv)` branch is a one-line forwarding return.
///
/// When [onLoadMore] is provided the grid paginates: as D-pad focus / scroll
/// approaches the last rows the next page is fetched and appended. When it's
/// null the grid is a fixed list over [items] — identical to the pre-pagination
/// behaviour, so search / JS / non-paginating callers are unchanged.
class SeeAllScreenTv extends StatefulWidget {
  const SeeAllScreenTv({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onLongPress,
    this.tagsFor,
    this.onLoadMore,
  });

  final String title;
  final List<MediaItem> items;
  final void Function(MediaItem) onTap;
  final void Function(MediaItem)? onLongPress;

  /// Optional per-item poster badges (e.g. SUB/DUB/MOVIE). Mirrors
  /// [SeeAllScreen.tagsFor] so callers are unchanged.
  final List<String> Function(MediaItem)? tagsFor;

  /// Optional next-page fetcher for infinite scroll. `page` is 1-based and the
  /// initial [items] ARE page 1, so the first call requests page 2. Returning an
  /// empty list (or only already-seen items) ends pagination. Null → fixed list.
  final Future<List<MediaItem>> Function(int page)? onLoadMore;

  @override
  State<SeeAllScreenTv> createState() => _SeeAllScreenTvState();
}

class _SeeAllScreenTvState extends State<SeeAllScreenTv> {
  /// 5 columns matches a typical 1080p TV at ~140 dp card width + margins.
  static const int _crossAxisCount = 6;
  static const double _cardWidth = 140;

  late final List<MediaItem> _items = [...widget.items];
  final Set<String> _seen = {};
  final ScrollController _controller = ScrollController();

  /// The last page already loaded — the initial [items] are page 1.
  int _page = 1;
  bool _loading = false;
  bool _end = false;

  @override
  void initState() {
    super.initState();
    for (final it in _items) {
      _seen.add(_keyOf(it));
    }
    if (widget.onLoadMore != null) {
      _controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
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

  /// Index-based trigger: when a cell within the last two rows is BUILT (D-pad
  /// focus scrolled the grid enough to lazily build it), fetch the next page.
  /// Complements [_onScroll] for the case where the first page fits without
  /// scrolling. Scheduled post-frame so it never calls setState during build.
  void _maybeLoadFromIndex(int index) {
    if (widget.onLoadMore == null || _loading || _end) return;
    if (index < _items.length - _crossAxisCount * 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadMore();
    });
  }

  Future<void> _loadMore() async {
    final loader = widget.onLoadMore;
    if (loader == null || _loading || _end) return;
    setState(() => _loading = true);
    List<MediaItem> next = const [];
    try {
      next = await loader(_page + 1);
    } catch (_) {
      next = const [];
    }
    if (!mounted) return;
    final fresh = <MediaItem>[];
    for (final it in next) {
      final k = _keyOf(it);
      if (_seen.add(k)) fresh.add(it);
    }
    setState(() {
      _loading = false;
      if (fresh.isEmpty) {
        _end = true;
      } else {
        _items.addAll(fresh);
        _page += 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final paginating = widget.onLoadMore != null;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        // Suppress the touch-only auto back arrow; TvBackButton in the body
        // Stack provides a D-pad-focusable alternative.
        automaticallyImplyLeading: false,
        title: Text(widget.title, style: AppText.headline),
      ),
      body: Stack(
        children: [
          GridView.builder(
            controller: paginating ? _controller : null,
            padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
            cacheExtent: 800,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _crossAxisCount,
              childAspectRatio: 0.62,
              crossAxisSpacing: 16,
              mainAxisSpacing: 20,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) {
              if (paginating) _maybeLoadFromIndex(i);
              final item = _items[i];
              return TvFocusable(
                autofocus: i == 0,
                onTap: () => widget.onTap(item),
                focusLabel: item.title,
                child: PosterCard(
                  title: item.title,
                  imageUrl: item.cover,
                  headers: item.coverHeaders,
                  tags: widget.tagsFor?.call(item) ?? const [],
                  cellWidth: _cardWidth,
                  showTitle: false,
                  // Touch gestures are disabled on TV; [TvFocusable] handles
                  // OK-key selection.
                  onTap: null,
                  onLongPress: null,
                ),
              );
            },
          ),
          // D-pad-focusable back button at top-left — reachable via D-pad up/left
          // from the first poster without stealing the initial autofocus.
          const Positioned(top: 8, left: 8, child: TvBackButton()),
          // Bottom loading indicator while the next page is in flight (only in
          // the paginating configuration, so non-paginating callers are unchanged).
          if (paginating && _loading)
            const Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
