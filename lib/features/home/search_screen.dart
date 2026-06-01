import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';
import '../search/bloc/search_bloc.dart';
import '../search/bloc/search_event.dart';
import '../search/bloc/search_state.dart';

/// Dedicated search screen pushed from the Home header search icon.
///
/// Provides a [SearchBloc] scoped to this screen; the inner [_SearchView]
/// holds the [TextEditingController] and reacts to bloc state via
/// [BlocBuilder].
///
/// When [initialQuery] is provided the screen pre-fills the text field and
/// fires a search immediately.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key, this.initialQuery, this.showBack = true});

  final String? initialQuery;

  /// When [false] the screen is embedded as a bottom-nav tab and the back
  /// arrow is hidden. Also suppresses autofocus so the keyboard doesn't
  /// appear on app launch.
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final bloc = SearchBloc(repo: sl<SourceRepository>());
        final q = initialQuery?.trim();
        if (q != null && q.isNotEmpty) {
          bloc.add(SearchQueryChanged(q));
        }
        return bloc;
      },
      child: _SearchView(initialQuery: initialQuery, showBack: showBack),
    );
  }
}

class _SearchView extends StatefulWidget {
  const _SearchView({this.initialQuery, required this.showBack});

  final String? initialQuery;
  final bool showBack;

  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openSortSheet(BuildContext context) {
    final bloc = context.read<SearchBloc>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return BlocProvider.value(
          value: bloc,
          child: BlocBuilder<SearchBloc, SearchState>(
            builder: (ctx, state) {
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
                      for (final opt in SearchSort.values)
                        InkWell(
                          onTap: () {
                            ctx.read<SearchBloc>().add(SearchSortChanged(opt));
                            Navigator.pop(ctx);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    opt.label,
                                    style: AppText.body.copyWith(
                                      color: state.sort == opt
                                          ? AppColors.textPrimary
                                          : AppColors.textSecondary,
                                      fontWeight: state.sort == opt
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                                if (state.sort == opt)
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
          ),
        );
      },
    );
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
              padding: EdgeInsets.fromLTRB(widget.showBack ? 4 : 16, 12, 16, 0),
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
                              onChanged: (text) => context
                                  .read<SearchBloc>()
                                  .add(SearchQueryChanged(text)),
                              onSubmitted: (text) => context
                                  .read<SearchBloc>()
                                  .add(SearchQueryChanged(text)),
                              style: AppText.body.copyWith(
                                color: AppColors.textPrimary,
                              ),
                              cursorColor: AppColors.accent,
                              decoration: const InputDecoration(
                                hintText: 'Search…',
                                hintStyle: AppText.body,
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                              ),
                            ),
                          ),
                          // Sort button — tinted coral when sort is not default
                          BlocBuilder<SearchBloc, SearchState>(
                            buildWhen: (prev, curr) => prev.sort != curr.sort,
                            builder: (context, state) => IconButton(
                              icon: Icon(
                                Icons.sort_rounded,
                                size: 20,
                                color: state.sort != SearchSort.bestMatch
                                    ? AppColors.accent
                                    : AppColors.textTertiary,
                              ),
                              tooltip: 'Sort',
                              onPressed: () => _openSortSheet(context),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
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
              child: BlocBuilder<SearchBloc, SearchState>(
                builder: (context, state) {
                  switch (state.status) {
                    case SearchStatus.idle:
                      return const Center(
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
                      );

                    case SearchStatus.loading:
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: SkeletonGrid(),
                      );

                    case SearchStatus.error:
                      return const EmptyState(
                        icon: Icons.error_outline,
                        message: 'Search failed — try again',
                      );

                    case SearchStatus.success:
                      final items = state.sortedResults;
                      if (items.isEmpty) {
                        return EmptyState(
                          icon: Icons.search_off,
                          message: 'No results for "${state.query}"',
                        );
                      }
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
                            ),
                          );
                        },
                      );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
