import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_poster_tile.dart';
import '../../core/ui/states.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../home/home_screen_tv.dart';
import '../home/see_all_screen.dart';
import 'cubit/browse_source_cubit.dart';

/// TV layout for browsing one installed source's catalogue.
class BrowseSourceScreenTv extends StatelessWidget {
  const BrowseSourceScreenTv({
    super.key,
    required this.sourceId,
    required this.title,
  });

  final String sourceId;
  final String title;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) =>
        BrowseSourceCubit(repo: sl<SourceRepository>(), sourceId: sourceId)
          ..load(),
    child: _BrowseSourceScreenTvView(sourceId: sourceId, title: title),
  );
}

class _BrowseSourceScreenTvView extends StatefulWidget {
  const _BrowseSourceScreenTvView({
    required this.sourceId,
    required this.title,
  });

  final String sourceId;
  final String title;

  @override
  State<_BrowseSourceScreenTvView> createState() =>
      _BrowseSourceScreenTvViewState();
}

class _BrowseSourceScreenTvViewState extends State<_BrowseSourceScreenTvView> {
  static const int _crossAxisCount = 6;

  bool _searching = false;
  late final TextEditingController _controller = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _openDetail(MediaItem item) {
    Navigator.of(context).push(DetailScreen.route(item));
  }

  void _openSeeAll(HomeSection section) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SeeAllScreen(
          title: section.title,
          items: section.items,
          onTap: _openDetail,
          onLoadMore: section.more == null
              ? null
              : (page) =>
                    sl<SourceRepository>().browseMore(section.more!, page),
        ),
      ),
    );
  }

  void _startSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldFocus.requestFocus();
    });
  }

  void _stopSearch() {
    _controller.clear();
    context.read<BrowseSourceCubit>().clearSearch();
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 48, 12),
              child: Row(
                children: [
                  const TvBackButton(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _searching
                        ? TextField(
                            controller: _controller,
                            focusNode: _fieldFocus,
                            autofocus: true,
                            textInputAction: TextInputAction.search,
                            style: AppText.title.copyWith(
                              color: AppColors.textPrimary,
                            ),
                            cursorColor: Colors.white,
                            decoration: InputDecoration(
                              hintText: l10n.search2,
                              hintStyle: AppText.title.copyWith(
                                color: AppColors.textTertiary,
                              ),
                              border: InputBorder.none,
                            ),
                            onSubmitted: (q) =>
                                context.read<BrowseSourceCubit>().search(q),
                          )
                        : Text(
                            widget.title,
                            style: AppText.largeTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                  TvFocusable(
                    variant: TvFocusVariant.float,
                    semanticLabel:
                        _searching ? l10n.clear : l10n.searchThisSource,
                    onTap: _searching ? _stopSearch : _startSearch,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Icon(
                        _searching ? Icons.close_rounded : Icons.search_rounded,
                        size: 26,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: BlocBuilder<BrowseSourceCubit, BrowseSourceState>(
                builder: (context, state) {
                  if (state.isSearchActive) {
                    return _searchGrid(state);
                  }
                  if (state.loading) {
                    return Padding(
                      padding: const EdgeInsets.all(40),
                      child: SkeletonGrid(crossAxisCount: _crossAxisCount),
                    );
                  }
                  if (state.failed || state.sections.isEmpty) {
                    return Center(
                      child: Text(
                        state.failed
                            ? l10n.somethingWentWrong
                            : l10n.noTitlesInThisList,
                        style: AppText.headline.copyWith(
                          color: AppColors.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.only(bottom: 32),
                    itemCount: state.sections.length,
                    itemBuilder: (_, i) => TvRail(
                      section: state.sections[i],
                      onTap: _openDetail,
                      onSeeAll: () => _openSeeAll(state.sections[i]),
                      firstAutofocus: i == 0 && !_searching,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchGrid(BrowseSourceState state) {
    if (state.searching) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: SkeletonGrid(crossAxisCount: _crossAxisCount),
      );
    }
    if (state.searchFailed) {
      return Center(
        child: Text(
          context.l10n.somethingWentWrong,
          style: AppText.headline.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    final results = state.searchResults ?? const [];
    if (results.isEmpty) {
      return Center(
        child: Text(
          context.l10n.noTitlesInThisList,
          style: AppText.headline.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    final cubit = context.read<BrowseSourceCubit>();
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >=
            n.metrics.maxScrollExtent - n.metrics.viewportDimension) {
          cubit.loadMore();
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _crossAxisCount,
          childAspectRatio: 0.56,
          crossAxisSpacing: 18,
          mainAxisSpacing: 22,
        ),
        itemCount: results.length + (state.loadingMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= results.length) {
            return Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            );
          }
          final item = results[i];
          return TvPosterTile(
            autofocus: i == 0,
            title: item.title,
            imageUrl: item.cover,
            headers: item.coverHeaders,
            qualityBadge: item.quality,
            dubBadge: item.dubBadge,
            onTap: () => _openDetail(item),
          );
        },
      ),
    );
  }
}
