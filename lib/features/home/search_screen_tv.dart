import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';
import '../search/bloc/search_bloc.dart';
import '../search/bloc/search_event.dart';
import '../search/bloc/search_state.dart';

/// TV Search: D-pad-navigable layout backed by the same [SearchBloc] provided
/// by the parent [SearchScreen].
///
/// When the screen is pushed, [autofocus] on the [TextField] immediately
/// triggers the Android TV leanback on-screen keyboard — the user types via
/// remote, then presses OK/Enter on the keyboard to submit. [onSubmitted]
/// dispatches [SearchRunRequested] to the bloc, identical to the phone path.
///
/// Results render as a 6-column focusable poster grid using the existing
/// [PosterCard] widget (touch callbacks disabled) wrapped in [TvFocusable].
/// D-pad DOWN from the search field moves focus into the grid; OK on a card
/// opens the Detail screen via the same [DetailScreen.route] the phone uses.
///
/// The phone [SearchScreen] is unchanged except for the one-line
/// `if (sl<AppMode>().isTv) return SearchScreenTv(...)` branch added in its
/// [SearchScreen.build] method.
class SearchScreenTv extends StatefulWidget {
  const SearchScreenTv({super.key, this.initialQuery});
  final String? initialQuery;

  @override
  State<SearchScreenTv> createState() => _SearchScreenTvState();
}

class _SearchScreenTvState extends State<SearchScreenTv> {
  /// 6 columns fills a 1920-wide TV at ~140 dp card width with comfortable gaps.
  static const int _crossAxisCount = 6;
  static const double _cardWidth = 130.0;

  late final TextEditingController _controller;
  // DOWN from the field must LEAVE it (which closes the TV keyboard) and drop
  // onto the first suggestion/result. Without this the keyboard trapped focus
  // and the recommendations below were unreachable (tester report).
  late final FocusNode _fieldFocus = FocusNode(onKeyEvent: _onFieldKey);

  KeyEventResult _onFieldKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (node.focusInDirection(TraversalDirection.down)) {
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  List<String> _tagsFor(MediaItem m) {
    final t = <String>[];
    if ((m.dubCount ?? 0) > 0) t.add('DUB');
    if ((m.subCount ?? 0) > 0 && t.length < 2) t.add('SUB');
    return t;
  }

  void _openDetail(MediaItem item) {
    Navigator.push(context, DetailScreen.route(item));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Search field ──────────────────────────────────────────────────
            // autofocus=true means Flutter immediately requests focus on this
            // TextField when the screen is first built. On Android TV that focus
            // request triggers the system leanback on-screen keyboard so the
            // user can start typing with the remote right away.
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 28, 48, 20),
              child: Row(
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 28,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _fieldFocus,
                      // Requests focus on first build → Android TV shows keyboard.
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      // Typing updates suggestions (same as phone onChanged).
                      onChanged: (text) => context
                          .read<SearchBloc>()
                          .add(SearchQueryChanged(text)),
                      // OK on the TV keyboard / Enter runs the full search
                      // (identical to the phone's onSubmitted handler).
                      onSubmitted: (text) => context
                          .read<SearchBloc>()
                          .add(SearchRunRequested(text)),
                      style: AppText.title.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w400,
                      ),
                      cursorColor: AppColors.accent,
                      decoration: InputDecoration(
                        hintText: 'Search…',
                        hintStyle: AppText.title.copyWith(
                          color: AppColors.textTertiary,
                          fontWeight: FontWeight.w400,
                        ),
                        border: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: AppColors.hairline,
                            width: 1,
                          ),
                        ),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: AppColors.hairline,
                            width: 1,
                          ),
                        ),
                        focusedBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: AppColors.accent,
                            width: 2,
                          ),
                        ),
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ── Results / states ──────────────────────────────────────────────
            Expanded(
              child: BlocBuilder<SearchBloc, SearchState>(
                builder: (context, state) {
                  // Show live suggestions while the user is typing but before
                  // a full search has run (same logic as the phone).
                  if (state.status != SearchStatus.success &&
                      state.suggestions.isNotEmpty) {
                    return _suggestionList(state.suggestions);
                  }
                  switch (state.status) {
                    case SearchStatus.idle:
                      return const EmptyState(
                        icon: Icons.search_rounded,
                        message: 'Search for something to watch',
                      );
                    case SearchStatus.loading:
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(40, 8, 40, 40),
                        child: SkeletonGrid(crossAxisCount: _crossAxisCount),
                      );
                    case SearchStatus.error:
                      return const EmptyState(
                        icon: Icons.error_outline,
                        message: 'Search failed — try again',
                      );
                    case SearchStatus.success:
                      return _resultsGrid(state);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Results grid ─────────────────────────────────────────────────────────────

  /// Flat D-pad-navigable poster grid of all visible results across all sources.
  ///
  /// Source grouping (phone's horizontal rows) doesn't translate to TV D-pad
  /// navigation; a flat grid lets the user move through all results with a
  /// single D-pad sweep. The data comes from [SearchState.visibleResults] which
  /// honours the active sort + content-type / genre / decade filters — identical
  /// to what the phone's flat-grid path uses.
  Widget _resultsGrid(SearchState state) {
    final items = state.visibleResults;
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search_off_rounded,
              size: 52,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 14),
            Text(
              'No results for "${state.query}"',
              textAlign: TextAlign.center,
              style: AppText.headline,
            ),
            const SizedBox(height: 6),
            const Text(
              'Check the spelling or try a different title.',
              textAlign: TextAlign.center,
              style: AppText.body,
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _crossAxisCount,
        childAspectRatio: 0.62,
        crossAxisSpacing: 16,
        mainAxisSpacing: 20,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return TvFocusable(
          // First result gets autofocus so D-pad DOWN from the search field
          // lands here immediately after results populate.
          autofocus: i == 0,
          onTap: () => _openDetail(item),
          child: PosterCard(
            title: item.title,
            imageUrl: item.cover,
            headers: item.coverHeaders,
            tags: _tagsFor(item),
            cellWidth: _cardWidth,
            // Touch gestures disabled on TV; [TvFocusable] handles OK-key.
            onTap: null,
            onLongPress: null,
          ),
        );
      },
    );
  }

  // ── Suggestion list ───────────────────────────────────────────────────────────

  /// D-pad-navigable suggestion list shown while the user is typing.
  ///
  /// Each suggestion is wrapped in [TvFocusable] so the user can D-pad down
  /// from the field and OK to fill + run that query without re-opening the
  /// keyboard.
  Widget _suggestionList(List<String> suggestions) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: suggestions.length,
      itemBuilder: (context, i) {
        final s = suggestions[i];
        // The 48px gap lives OUTSIDE TvFocusable and scale is 1.0 — a full-width
        // row otherwise makes the focus ring overflow off the right edge and
        // overlap the field above (tester report).
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 2),
          child: TvFocusable(
            scale: 1.0,
            onTap: () {
              _controller.value = TextEditingValue(
                text: s,
                selection: TextSelection.collapsed(offset: s.length),
              );
              context.read<SearchBloc>().add(SearchRunRequested(s));
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      s,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
