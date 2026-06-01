import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';

// ── Sort options ────────────────────────────────────────────────────────────

enum _SortOrder { bestMatch, titleAsc, titleDesc }

extension _SortLabel on _SortOrder {
  String get label {
    switch (this) {
      case _SortOrder.bestMatch:
        return 'Best match';
      case _SortOrder.titleAsc:
        return 'Title A–Z';
      case _SortOrder.titleDesc:
        return 'Title Z–A';
    }
  }
}

/// Dedicated search screen pushed from the Home header search icon.
///
/// Preserves the exact search behavior from the original [HomeScreen]:
/// block-body [setState] that assigns the [Future] (not arrow-body),
/// controller [dispose], results grid with [SkeletonGrid]/[EmptyState]/
/// 3-col [PosterCard] [GridView].
///
/// When [initialQuery] is provided the screen pre-fills the text field and
/// fires a search immediately so genre chips can seed it without extra taps.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    this.initialQuery,
    this.showBack = true,
  });

  final String? initialQuery;

  /// When [false] the screen is embedded as a bottom-nav tab and the back
  /// arrow is hidden. Also suppresses autofocus so the keyboard doesn't
  /// appear on app launch.
  final bool showBack;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _repo = sl<SourceRepository>();
  final _controller = TextEditingController();
  Future<List<MediaItem>>? _results;
  _SortOrder _sort = _SortOrder.bestMatch;

  // The raw query that produced _results — used for empty-state message.
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim();
    if (q != null && q.isNotEmpty) {
      _controller.text = q;
      // Fire the search after the first frame so the widget tree is mounted.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(q);
      });
    }
  }

  void _search(String q) {
    if (q.trim().isEmpty) return;
    // Block-body setState: the closure must return void. An arrow body here
    // would return the Future from the assignment, which setState forbids.
    setState(() {
      _lastQuery = q.trim();
      _results = _repo.search(q.trim());
    });
  }

  void _openSortSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Handle
                    Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.hairline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    for (final opt in _SortOrder.values)
                      InkWell(
                        onTap: () {
                          setState(() => _sort = opt);
                          Navigator.pop(ctx);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(opt.label,
                                    style: AppText.body.copyWith(
                                      color: _sort == opt
                                          ? AppColors.textPrimary
                                          : AppColors.textSecondary,
                                      fontWeight: _sort == opt
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    )),
                              ),
                              if (_sort == opt)
                                const Icon(
                                  Icons.check_rounded,
                                  size: 20,
                                  color: AppColors.accent,
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<MediaItem> _sorted(List<MediaItem> items) {
    switch (_sort) {
      case _SortOrder.bestMatch:
        return items;
      case _SortOrder.titleAsc:
        return [...items]..sort((a, b) => a.title.compareTo(b.title));
      case _SortOrder.titleDesc:
        return [...items]..sort((a, b) => b.title.compareTo(a.title));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // cellWidth = (screenWidth - 40 px screen padding - 24 px for 2 gaps) / 3
    final cellW = (mq.size.width - 40 - 24) / 3;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row: back arrow (optional) + search field + sort ────
            Padding(
              padding: EdgeInsets.fromLTRB(
                  widget.showBack ? 4 : 16, 12, 16, 0),
              child: Row(
                children: [
                  if (widget.showBack)
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new,
                        color: Colors.white,
                        size: 20,
                      ),
                      onPressed: () => Navigator.pop(context),
                      tooltip: 'Back',
                    ),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.search,
                            size: 20,
                            color: AppColors.textTertiary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              autofocus: widget.showBack,
                              textInputAction: TextInputAction.search,
                              onSubmitted: _search,
                              style: AppText.body
                                  .copyWith(color: AppColors.textPrimary),
                              cursorColor: AppColors.accent,
                              decoration: const InputDecoration(
                                hintText: 'Search…',
                                hintStyle: AppText.body,
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                    vertical: 14),
                              ),
                            ),
                          ),
                          // Sort button — only meaningful once there are results
                          IconButton(
                            icon: Icon(
                              Icons.sort_rounded,
                              size: 20,
                              color: _sort != _SortOrder.bestMatch
                                  ? AppColors.accent
                                  : AppColors.textTertiary,
                            ),
                            tooltip: 'Sort',
                            onPressed: _openSortSheet,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // ── Results area ────────────────────────────────────────────────
            Expanded(
              child: _results == null
                  // Idle state — no query yet
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.search_rounded,
                            size: 48,
                            color: AppColors.textTertiary,
                          ),
                          SizedBox(height: 12),
                          Text(
                            'Search for something to watch',
                            textAlign: TextAlign.center,
                            style: AppText.body,
                          ),
                        ],
                      ),
                    )
                  : FutureBuilder<List<MediaItem>>(
                      future: _results,
                      builder: (context, snap) {
                        if (snap.connectionState == ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.all(20),
                            child: SkeletonGrid(),
                          );
                        }
                        if (snap.hasError) {
                          return const EmptyState(
                            icon: Icons.error_outline,
                            message: 'Search failed — try again',
                          );
                        }
                        final raw = snap.data ?? const [];
                        if (raw.isEmpty) {
                          return EmptyState(
                            icon: Icons.search_off,
                            message: 'No results for "$_lastQuery"',
                          );
                        }
                        final items = _sorted(raw);
                        return GridView.builder(
                          padding: const EdgeInsets.all(16),
                          cacheExtent: 800,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 0.62,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 16,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final item = items[i];
                            return PosterCard(
                              title: item.title,
                              imageUrl: item.cover,
                              headers: item.coverHeaders,
                              cellWidth: cellW,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => DetailScreen(item: item),
                                ),
                              ).then((_) {
                                if (mounted) setState(() {});
                              }),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
