import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/poster_card.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../home/see_all_screen.dart';
import 'cubit/browse_source_cubit.dart';

/// One source's catalogue — today's Home, pinned to a chosen source.
///
/// Browsing a source is NOT selecting it: nothing here touches
/// ActiveSourceCubit, so the app's active source survives the visit.
class BrowseSourceScreen extends StatelessWidget {
  const BrowseSourceScreen({
    super.key,
    required this.sourceId,
    required this.title,
  });

  final String sourceId;
  final String title;

  @override
  Widget build(BuildContext context) => BlocProvider(
        create: (_) => BrowseSourceCubit(
          repo: sl<SourceRepository>(),
          sourceId: sourceId,
        )..load(),
        child: _BrowseSourceView(sourceId: sourceId, title: title),
      );
}

class _BrowseSourceView extends StatefulWidget {
  const _BrowseSourceView({required this.sourceId, required this.title});

  final String sourceId;
  final String title;

  @override
  State<_BrowseSourceView> createState() => _BrowseSourceViewState();
}

class _BrowseSourceViewState extends State<_BrowseSourceView> {
  // Search is view state, not screen state — whether the AppBar shows the
  // title or the field never needs to survive a rebuild of anything else.
  bool _searching = false;
  late final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openDetail(BuildContext context, MediaItem item) =>
      Navigator.of(context).push(DetailScreen.route(item));

  void _openSeeAll(BuildContext context, HomeSection section) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SeeAllScreen(
            title: section.title,
            items: section.items,
            onTap: (i) => _openDetail(context, i),
          ),
        ),
      );

  void _startSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _stopSearch(BuildContext context) {
    _controller.clear();
    context.read<BrowseSourceCubit>().clearSearch();
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: _searching
            ? TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                cursorColor: AppColors.accent,
                decoration: InputDecoration(
                  hintText: context.l10n.search2,
                  hintStyle: AppText.body,
                  border: InputBorder.none,
                ),
                onSubmitted: (q) =>
                    context.read<BrowseSourceCubit>().search(q),
              )
            : Text(widget.title, style: AppText.headline),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close_rounded : Icons.search),
            tooltip: _searching
                ? context.l10n.clear
                : context.l10n.searchThisSource,
            onPressed: _searching ? () => _stopSearch(context) : _startSearch,
          ),
        ],
      ),
      body: BlocBuilder<BrowseSourceCubit, BrowseSourceState>(
        builder: (context, state) {
          if (state.isSearchActive) {
            return _searchBody(context, state);
          }
          if (state.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.failed || state.sections.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  state.failed
                      ? context.l10n.somethingWentWrong
                      : context.l10n.noTitlesInThisList,
                  style: AppText.caption,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: state.sections.length,
            itemBuilder: (_, i) {
              final section = state.sections[i];
              final items = section.items;
              return ContentRow(
                title: section.title,
                itemWidth: 140,
                itemHeight: 236,
                itemCount: items.length,
                onSeeAll: () => _openSeeAll(context, section),
                itemBuilder: (c, j) => PosterCard(
                  title: items[j].title,
                  imageUrl: items[j].cover,
                  headers: items[j].coverHeaders,
                  cellWidth: 140,
                  qualityBadge: items[j].quality,
                  dubBadge: items[j].dubBadge,
                  onTap: () => _openDetail(context, items[j]),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// Search spinner / failure / empty / results grid — mirrors the
  /// single-source flat grid in `search_screen.dart`'s `_resultsGrid`.
  Widget _searchBody(BuildContext context, BrowseSourceState state) {
    if (state.searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.searchFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.l10n.somethingWentWrong,
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final results = state.searchResults ?? const [];
    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.l10n.noTitlesInThisList,
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: results.length,
      itemBuilder: (_, i) {
        final item = results[i];
        return PosterCard(
          title: item.title,
          imageUrl: item.cover,
          headers: item.coverHeaders,
          qualityBadge: item.quality,
          dubBadge: item.dubBadge,
          onTap: () => _openDetail(context, item),
        );
      },
    );
  }
}
