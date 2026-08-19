import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/media_item.dart';
import '../../core/playback/search_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_poster_tile.dart';
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
  const SearchScreenTv({super.key, this.initialQuery, this.history});
  final String? initialQuery;

  /// Recent search terms. Production [SearchScreen] passes the injector
  /// singleton; tests pass a stub (or omit it) so they don't need GetIt.
  final SearchHistory? history;

  @override
  State<SearchScreenTv> createState() => _SearchScreenTvState();
}

class _SearchScreenTvState extends State<SearchScreenTv> {
  /// 6 columns fills a 1920-wide TV at ~140 dp card width with comfortable gaps.
  static const int _crossAxisCount = 6;

  /// Native voice-search bridge (system RecognizerIntent; no plugin, no mic
  /// permission — the system dialog does the recording).
  static const _voiceChannel = MethodChannel('zangetsu/voice_search');

  /// Only show the mic when the device actually has a speech recognizer.
  /// Stays false on any error and on non-Android, so the mic simply never
  /// appears there — the screen is unchanged.
  bool _voiceAvailable = false;

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
    _checkVoice();
  }

  Future<void> _checkVoice() async {
    try {
      final ok = await _voiceChannel.invokeMethod<bool>('isAvailable') ?? false;
      if (mounted && ok) setState(() => _voiceAvailable = true);
    } catch (_) {
      // No native handler / not Android → leave the mic hidden.
    }
  }

  /// Open the system voice dialog; on a recognised phrase, fill the field and
  /// run the search (same path as pressing OK on the keyboard).
  Future<void> _startVoice() async {
    try {
      final text = await _voiceChannel.invokeMethod<String>(
        'listen',
        {'prompt': 'Speak the title'},
      );
      if (!mounted || text == null || text.isEmpty) return;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      context.read<SearchBloc>().add(SearchRunRequested(text));
    } catch (_) {
      // Recogniser cancelled / unavailable — nothing to do.
    }
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
                      cursorColor: Colors.white,
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
                        // White underline while typing — premium, not a red accent.
                        focusedBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: Colors.white,
                            width: 2,
                          ),
                        ),
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  // Voice search — D-pad RIGHT from the field reaches it. Only
                  // rendered when the device has a recogniser (see _checkVoice).
                  if (_voiceAvailable) ...[
                    const SizedBox(width: 12),
                    TvFocusable(
                      variant: TvFocusVariant.float,
                      scale: 1.08,
                      onTap: _startVoice,
                      semanticLabel: 'Voice search',
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.surface2,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.mic_none_rounded,
                          size: 26,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // ── Source scope (All sources / Current source) ─────────────────
            BlocBuilder<SearchBloc, SearchState>(
              buildWhen: (a, b) => a.currentSourceOnly != b.currentSourceOnly,
              builder: (context, state) {
                final current = state.currentSourceOnly;
                Widget chip({
                  required Key key,
                  required String label,
                  required IconData icon,
                  required bool selected,
                  required bool value,
                }) {
                  return TvFocusable(
                    key: key,
                    variant: TvFocusVariant.pill,
                    onTap: () => context
                        .read<SearchBloc>()
                        .add(SearchScopeChanged(value)),
                    builder: (focused) {
                      // Selected scope = solid white chip (black text); focus
                      // renders the white pill on top. No red.
                      final bg = selected && !focused
                          ? Colors.white
                          : Colors.transparent;
                      final fg = (focused || selected)
                          ? Colors.black
                          : AppColors.textSecondary;
                      return Container(
                        decoration: BoxDecoration(
                          color: focused ? null : bg,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 11),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 18, color: fg),
                            const SizedBox(width: 8),
                            Text(label,
                                style: TextStyle(
                                    color: fg,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      );
                    },
                  );
                }

                return Padding(
                  padding: const EdgeInsets.fromLTRB(48, 0, 48, 12),
                  child: Row(
                    children: [
                      chip(
                        key: const ValueKey('tv-search-scope-all'),
                        label: 'All sources',
                        icon: Icons.travel_explore_rounded,
                        selected: !current,
                        value: false,
                      ),
                      const SizedBox(width: 10),
                      chip(
                        key: const ValueKey('tv-search-scope-current'),
                        label: 'Current source',
                        icon: Icons.filter_center_focus_rounded,
                        selected: current,
                        value: true,
                      ),
                    ],
                  ),
                );
              },
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
                      return _idleView();
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
                      // Current source = one source → flat grid (best overview
                      // of a single source). All sources = CloudStream-style
                      // source-grouped horizontal rows.
                      return state.currentSourceOnly
                          ? _resultsGrid(state)
                          : _resultsRows(state);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Idle (recent searches + empty prompt) ───────────────────────────────────

  /// Idle body: recent terms with a D-pad-focusable Clear, matching the phone
  /// landing page. Falls back to the empty prompt when there's nothing stored
  /// (tests that omit [SearchScreenTv.history] hit this path too).
  Widget _idleView() {
    final history = widget.history;
    final recent = history?.recent() ?? const <String>[];
    if (history == null || recent.isEmpty) {
      return const EmptyState(
        icon: Icons.search_rounded,
        message: 'Search for something to watch',
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(48, 8, 48, 12),
          child: Row(
            children: [
              Expanded(
                child: Text('Recent searches', style: AppText.overline),
              ),
              TvFocusable(
                key: const ValueKey('tv-search-clear-history'),
                variant: TvFocusVariant.pill,
                scale: 1.0,
                semanticLabel: 'Clear search history',
                onTap: () async {
                  await history.clear();
                  if (mounted) setState(() {});
                },
                builder: (focused) {
                  final fg = focused ? Colors.black : AppColors.accent;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      'Clear',
                      style: TextStyle(
                        color: fg,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        for (final q in recent)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 2),
            child: TvFocusable(
              scale: 1.0,
              onTap: () {
                _controller.value = TextEditingValue(
                  text: q,
                  selection: TextSelection.collapsed(offset: q.length),
                );
                context.read<SearchBloc>().add(SearchRunRequested(q));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.history_rounded,
                      size: 18,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        q,
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
          ),
      ],
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
    if (items.isEmpty) return _noResults(state);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _crossAxisCount,
        // Poster art + title below (outline hugs the art).
        childAspectRatio: 0.56,
        crossAxisSpacing: 18,
        mainAxisSpacing: 22,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        // First result gets autofocus so D-pad DOWN from the field lands here.
        return TvPosterTile(
          autofocus: i == 0,
          title: item.title,
          imageUrl: item.cover,
          headers: item.coverHeaders,
          tags: _tagsFor(item),
          onTap: () => _openDetail(item),
        );
      },
    );
  }

  /// Shared "nothing matched" panel — used by both the flat grid (current
  /// source) and the grouped rows (all sources).
  Widget _noResults(SearchState state) {
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

  // ── Grouped rows (all-sources) ────────────────────────────────────────────────

  /// CloudStream-style source-grouped results: one horizontal row per source
  /// (header = source name + count), stacked vertically in arrival order. D-pad
  /// UP/DOWN moves between sources, LEFT/RIGHT within a source — the same feel as
  /// the TV Home rows. Only used for the "All sources" scope; a single source
  /// still renders as the flat [_resultsGrid].
  Widget _resultsRows(SearchState state) {
    final groups = state.sortedVisibleGroups;
    if (groups.isEmpty) return _noResults(state);
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 40),
      itemCount: groups.length,
      itemBuilder: (context, gi) {
        final g = groups[gi];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 18, 48, 10),
              child: Text(
                '${g.sourceName}  ·  ${g.items.length}',
                style: AppText.headline,
              ),
            ),
            SizedBox(
              // Poster (130 × 195 at 2:3) + title + focus-scale headroom.
              height: 250,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                // Don't clip the focused card's scale-up + glow.
                clipBehavior: Clip.none,
                padding: const EdgeInsets.symmetric(horizontal: 40),
                itemCount: g.items.length,
                itemBuilder: (context, i) {
                  final item = g.items[i];
                  return Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: SizedBox(
                      width: 130,
                      // First tile of the first row gets autofocus so D-pad DOWN
                      // from the field/suggestions lands on a result.
                      child: TvPosterTile(
                        autofocus: gi == 0 && i == 0,
                        title: item.title,
                        imageUrl: item.cover,
                        headers: item.coverHeaders,
                        tags: _tagsFor(item),
                        onTap: () => _openDetail(item),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
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
