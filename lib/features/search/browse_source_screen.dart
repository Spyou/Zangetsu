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
import '../../core/ui/source_switcher.dart' show categorizedSources;
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../home/see_all_screen.dart';
import 'cubit/browse_source_cubit.dart';

/// The "ecosystem · language" tag [BrowseSourcesList] already shows as a row
/// subtitle — same [categorizedSources] row, found here by id so the identity
/// header can reuse it rather than inventing a new lookup. Null when the id
/// isn't in any bucket (nothing installed with that id any more) or carries
/// no tag.
String? _repoTagFor(String sourceId) {
  final b = categorizedSources();
  for (final list in [b.anime, b.movies, b.manga, b.novel, b.nsfw]) {
    for (final row in list) {
      if (row.id == sourceId) return row.repo;
    }
  }
  return null;
}

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

  // Identity header content — computed once, it never changes for the life
  // of this screen. [_displayName] is the source's clean name (unlike
  // [widget.title], which can carry an ecosystem prefix baked into the
  // picker's label); [_repoTag] is the same "ecosystem · lang" string
  // [BrowseSourcesList] already shows as a row subtitle.
  late final String _displayName =
      sl<SourceRepository>().displayName(widget.sourceId);
  late final String? _repoTag = _repoTagFor(widget.sourceId);

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
      body: Column(
        children: [
          // Above the rows, not the search field — matches the mockup, and
          // keeps the search AppBar exactly as it was.
          if (!_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: _SourceIdentityHeader(name: _displayName, tag: _repoTag),
            ),
          Expanded(
            child: BlocBuilder<BrowseSourceCubit, BrowseSourceState>(
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
          ),
        ],
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

/// Rounded-square initial + name + muted "ecosystem · lang" line, above the
/// rows — so a source's own catalogue reads as its own place rather than a
/// bare list under an AppBar title.
class _SourceIdentityHeader extends StatelessWidget {
  const _SourceIdentityHeader({required this.name, required this.tag});

  final String name;
  final String? tag;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              initial,
              style: AppText.headline.copyWith(fontSize: 19, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: AppText.body.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (tag != null && tag!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(tag!, style: AppText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
