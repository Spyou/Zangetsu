import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/models/media_item.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_keyboard_bridge.dart';
import '../../l10n/l10n.dart';

/// App-owned keyboard for New search, with controls and live results.
/// Used by both Android TV and Apple TV; input and focus stay in shared Flutter code.
/// Classic search uses its original system text field and does not open this.
class TvSearchInputScreen extends StatefulWidget {
  /// Configures the keyboard, query callbacks, and optional inline results.
  const TvSearchInputScreen({
    super.key,
    required this.initialQuery,
    this.compactStyle = false,
    this.recentQueries = const [],
    this.loadRecommendations,
    this.onRecommendationSelected,
    this.inlineSearch = false,
    this.controls,
    this.requestKey,
    this.onQueryChanged,
    this.onSearchSubmitted,
    this.submittedResults,
    this.submittedLoading = false,
  });

  /// Draft to restore when entering search.
  final String initialQuery;

  /// Uses the compact alphabet grid and recommendation layout.
  final bool compactStyle;

  /// Recent submitted searches shown before predictions become available.
  final List<String> recentQueries;

  /// Loads catalogue matches; failures leave the draft editable.
  final Future<List<MediaItem>> Function(String)? loadRecommendations;

  /// Opens a selected result through the owning search screen.
  final ValueChanged<MediaItem>? onRecommendationSelected;

  /// Keeps submission in the shell and delegates Back to Home navigation.
  final bool inlineSearch;

  /// Source, filter, and genre controls rendered beneath the keyboard.
  final Widget? controls;

  /// Changes when catalogue scope changes, invalidating cached matches.
  final Object? requestKey;

  /// Keeps the owning screen in sync with each draft edit.
  final ValueChanged<String>? onQueryChanged;

  /// Records explicit submissions without closing inline search.
  final ValueChanged<String>? onSearchSubmitted;

  /// Results from the owning search bloc after an explicit submission.
  final List<MediaItem>? submittedResults;
  final bool submittedLoading;

  @override
  State<TvSearchInputScreen> createState() => _TvSearchInputScreenState();
}

/// Owns draft input, remote focus, and cancellable recommendation requests.
class _TvSearchInputScreenState extends State<TvSearchInputScreen>
    implements TvKeyboardTarget {
  static const _rows = ['1234567890', 'qwertyuiop', 'asdfghjkl-', "zxcvbnm'.?"];
  late String _query = widget.initialQuery;
  bool _confirmBack = false;
  bool _closing = false;
  bool _symbols = false;
  late bool _uppercase = !RegExp(r'[A-Za-z]').hasMatch(widget.initialQuery);
  bool _automaticCase = true;
  Timer? _recommendDebounce;
  int _recommendSeq = 0;
  List<MediaItem> _recommendations = const [];
  bool _loadingRecommendations = false;
  bool _recommendationError = false;
  final _recommendCache = <String, List<MediaItem>>{};
  bool _submitted = false;
  bool _seededKeyboardFocus = false;
  final _firstKeyFocus = FocusNode(debugLabel: 'tv-new-search-first-key');

  // Match words anywhere in a title, including mistyped or swapped keys.
  int _prefixScore(String title) {
    final query = _query.trim().toLowerCase();
    final text = title.trim().toLowerCase();
    if (text.startsWith(query)) return 0;
    if (text.contains(query)) return 1;
    var best = _fuzzyPrefix(text);
    for (final match in RegExp(r'\s+|[-:,.!?]').allMatches(text)) {
      final score = _fuzzyPrefix(text.substring(match.end));
      if (score < best) best = score;
    }
    return best < 999 ? best + 2 : 999;
  }

  /// Scores prefix edits, including adjacent swaps, with a short-query limit.
  int _fuzzyPrefix(String title) {
    final query = _query.trim().toLowerCase();
    final text = title.trim().toLowerCase();
    if (text.startsWith(query)) return 0;
    final limit = query.length >= 6 ? 2 : 1;
    var best = query.length + text.length;
    for (
      var length = query.length - limit;
      length <= query.length + limit && length <= text.length;
      length++
    ) {
      if (length < 1) continue;
      final prefix = text.substring(0, length);
      final d = List.generate(
        query.length + 1,
        (i) => List.generate(
          prefix.length + 1,
          (j) => i == 0
              ? j
              : j == 0
              ? i
              : 0,
        ),
      );
      for (var i = 1; i <= query.length; i++) {
        for (var j = 1; j <= prefix.length; j++) {
          final values = [
            d[i - 1][j] + 1,
            d[i][j - 1] + 1,
            d[i - 1][j - 1] + (query[i - 1] == prefix[j - 1] ? 0 : 1),
          ];
          if (i > 1 &&
              j > 1 &&
              query[i - 1] == prefix[j - 2] &&
              query[i - 2] == prefix[j - 1]) {
            values.add(d[i - 2][j - 2] + 1);
          }
          d[i][j] = values.reduce((a, b) => a < b ? a : b);
        }
      }
      final score = d[query.length][prefix.length];
      if (score < best) best = score;
    }
    return best <= limit ? best : 999;
  }

  /// Ranks both display and English titles without discarding provider aliases.
  int _itemScore(MediaItem item) {
    final title = _prefixScore(item.title);
    final english = item.englishTitle == null
        ? 999
        : _prefixScore(item.englishTitle!);
    return title < english ? title : english;
  }

  /// Replaces recent queries with distinct title predictions after three letters.
  List<String> get _predictions {
    final seen = <String>{};
    final values = [
      ..._recommendations.map(_recommendationTitle),
      ...widget.recentQueries.where((q) => _prefixScore(q) < 999),
    ].where((q) => seen.add(q.toLowerCase())).toList();
    values.sort((a, b) => _prefixScore(a).compareTo(_prefixScore(b)));
    return values.take(4).toList();
  }

  /// Non-focusable wrapper whose subtree focus marks the keyboard as selected.
  final _rootFocus = FocusNode(
    debugLabel: 'tv-search-root',
    canRequestFocus: false,
    skipTraversal: true,
  );

  // Phone keyboard target: the whole New search screen is one search box.
  // The TvKeyboardBridge reads these to mirror the draft on a paired phone.

  /// True while focus is anywhere on this screen, so the phone offers typing.
  @override
  bool get focused => _rootFocus.hasFocus;

  /// True while the on-screen key grid itself has focus.
  @override
  bool get editing => _keyboardFocus.hasFocus;

  @override
  String get text => _query;

  @override
  String get hint => 'Search';

  @override
  bool get secure => false;

  @override
  TextInputAction? get inputAction => TextInputAction.search;

  @override
  TextInputType? get inputType => TextInputType.text;

  @override
  bool get multiline => false;

  @override
  int? get maxLength => 200;

  /// Replaces the draft with text typed on the phone and refreshes results,
  /// the same way an on-screen key press does. Ignored after dispose.
  @override
  void setText(String text) {
    if (!mounted || text == _query) return;
    setState(() {
      _confirmBack = false;
      _query = text;
      _submitted = false;
      _syncAutomaticCase();
    });
    widget.onQueryChanged?.call(_query);
    _refreshRecommendations();
    _bridgeChanged();
  }

  /// The phone pressed its search key: run the search as if Done was chosen.
  @override
  void submit() {
    if (mounted) _finish();
  }

  @override
  void dismiss() {
    // The app-owned grid has no IME to hide.
  }

  /// Tells the bridge the draft or focus changed, so the phone resyncs.
  void _bridgeChanged() => TvKeyboardBridge.instance.changed();

  @override
  void initState() {
    super.initState();
    _rootFocus.addListener(_bridgeChanged);
    _keyboardFocus.addListener(_bridgeChanged);
    TvKeyboardBridge.instance.register(this);
    _refreshRecommendations();
  }

  @override
  void didUpdateWidget(TvSearchInputScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.requestKey != widget.requestKey) {
      _submitted = true;
      _recommendCache.clear();
      _refreshRecommendations(immediate: true, force: true);
    }
  }

  final _keyboardFocus = FocusScopeNode(
    debugLabel: 'tv-search-keyboard',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );

  @override
  void dispose() {
    TvKeyboardBridge.instance.unregister(this);
    _rootFocus.removeListener(_bridgeChanged);
    _keyboardFocus.removeListener(_bridgeChanged);
    _recommendDebounce?.cancel();
    _recommendSeq++;
    _rootFocus.dispose();
    _keyboardFocus.dispose();
    _firstKeyFocus.dispose();
    super.dispose();
  }

  /// Submits inline results in place; standalone callers receive the draft.
  void _finish() {
    if (widget.inlineSearch) {
      _submitted = true;
      widget.onSearchSubmitted?.call(_query);
      _recommendCache.remove(_query.trim().toLowerCase());
      setState(() {});
      if (widget.submittedResults == null) {
        _refreshRecommendations(immediate: true, force: true);
      }
      return;
    }
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(_query);
  }

  /// Delegates inline Back to the shell so it returns directly to Home.
  void _back() {
    if (widget.inlineSearch) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_confirmBack) {
      _finish();
    } else {
      setState(() => _confirmBack = true);
    }
  }

  /// Updates the draft and invalidates submitted results before requesting hints.
  void _insert(String text) {
    setState(() {
      _confirmBack = false;
      _query += text;
      _submitted = false;
      _syncAutomaticCase();
    });
    widget.onQueryChanged?.call(_query);
    _refreshRecommendations();
    _bridgeChanged();
  }

  /// Removes one grapheme cluster so composed characters stay intact.
  void _delete() {
    setState(() {
      _confirmBack = false;
      _query = _query.characters.skipLast(1).toString();
      _submitted = false;
      _syncAutomaticCase();
    });
    widget.onQueryChanged?.call(_query);
    _refreshRecommendations();
    _bridgeChanged();
  }

  /// Clears input and restores automatic initial-letter capitalization.
  void _clear() {
    setState(() {
      _query = '';
      _confirmBack = false;
      _submitted = false;
      _automaticCase = true;
      _syncAutomaticCase();
    });
    widget.onQueryChanged?.call(_query);
    _refreshRecommendations();
    _bridgeChanged();
  }

  /// Capitalizes the first letter until the user explicitly chooses a case.
  void _syncAutomaticCase() {
    if (_automaticCase) _uppercase = !RegExp(r'[A-Za-z]').hasMatch(_query);
  }

  /// Displays the title variant that best matches the current query.
  String _recommendationTitle(MediaItem item) {
    if (item.englishTitle != null &&
        _prefixScore(item.englishTitle!) < _prefixScore(item.title)) {
      return item.englishTitle!;
    }
    return item.title;
  }

  /// Debounces queries and rejects stale responses using a request sequence.
  void _refreshRecommendations({bool immediate = false, bool force = false}) {
    _recommendDebounce?.cancel();
    final sequence = ++_recommendSeq;
    final query = _query.trim();
    if (!widget.compactStyle ||
        widget.loadRecommendations == null ||
        (!force && query.characters.length < 3)) {
      _recommendations = const [];
      _loadingRecommendations = false;
      _recommendationError = false;
      return;
    }
    final key = query.toLowerCase();
    final cached = _recommendCache[key];
    _recommendations = cached ?? const [];
    _loadingRecommendations = cached == null;
    _recommendationError = false;
    if (cached != null) return;
    _recommendDebounce = Timer(Duration(milliseconds: immediate ? 0 : 350), () async {
      try {
        final items = await widget.loadRecommendations!(query).timeout(
          const Duration(seconds: 18),
        );
        if (!mounted || sequence != _recommendSeq) return;
        final candidates = [
          ...items,
          ..._recommendCache.values.expand((v) => v),
        ];
        if (query.length >= 3 && !items.any((item) => _itemScore(item) < 999)) {
          // A short prefix supplies candidates when the catalogue cannot correct typos.
          try {
            final recentMatches = widget.recentQueries
                .where((q) => _prefixScore(q) < 999)
                .toList();
            final fallback = recentMatches.isNotEmpty
                ? recentMatches.first
                : query.substring(0, 2);
            candidates.addAll(
              await widget.loadRecommendations!(fallback).timeout(
                const Duration(seconds: 4),
              ),
            );
          } catch (_) {
            /* Keep available matches when the fallback is unavailable. */
          }
          if (!mounted || sequence != _recommendSeq) return;
        }
        final seen = <String>{};
        final providerIds = items.map((i) => '${i.sourceId}:${i.id}').toSet();
        final matching = candidates.where((item) {
          // Provider results can match synonyms/translated titles we do not have
          // locally. Rank them, but never discard them for not starting with the query.
          final match =
              (widget.inlineSearch &&
                  providerIds.contains('${item.sourceId}:${item.id}')) ||
              _itemScore(item) < 999;
          return match && seen.add('${item.sourceId}:${item.id}');
        }).toList();
        matching.sort((a, b) => _itemScore(a).compareTo(_itemScore(b)));
        if (_recommendCache.length >= 20) {
          _recommendCache.remove(_recommendCache.keys.first);
        }
        _recommendCache[key] = matching
            .take(widget.inlineSearch ? 30 : 8)
            .toList();
        setState(() {
          _recommendations = _recommendCache[key]!;
          _loadingRecommendations = false;
        });
      } catch (_) {
        if (!mounted || sequence != _recommendSeq) return;
        setState(() {
          _loadingRecommendations = false;
          _recommendationError = true;
        });
      }
    });
  }

  /// Shows recent queries, predictions, and consistently sized poster results.
  Widget _recommendationPanel(BuildContext context) {
    final panelHeight = widget.inlineSearch ? 200.0 : 150.0;
    final cardWidth = widget.inlineSearch ? 90.0 : 150.0;
    final externalResults = _submitted && widget.submittedResults != null;
    final results = externalResults
        ? widget.submittedResults!
        : _recommendations;
    final loading = externalResults
        ? widget.submittedLoading
        : _loadingRecommendations;
    if ((!_submitted && _query.trim().characters.length < 3) ||
        widget.loadRecommendations == null) {
      return SizedBox(height: panelHeight);
    }
    return SizedBox(
      height: panelHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.inlineSearch
                ? (_submitted ? 'Results' : 'Suggested titles')
                : 'Recommendations',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: loading
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : results.isEmpty
                ? Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      _recommendationError
                          ? 'Recommendations unavailable'
                          : context.l10n.noResultsFor(_query.trim()),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 15,
                      ),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final item = results[index];
                      // Search uses the same cover as the mobile poster cards.
                      // A hero banner is a different image, not a wider poster.
                      final artwork = item.cover;
                      final title = _recommendationTitle(item);
                      return SizedBox(
                        width: cardWidth,
                        child: TvFocusable(
                          key: ValueKey(
                            'tv-recommendation-${item.sourceId}-${item.id}',
                          ),
                          waitForKeyUp: true,
                          requireKeyDown: widget.inlineSearch,
                          scale: 1,
                          semanticLabel: title,
                          onTap: () {
                            widget.onRecommendationSelected?.call(item);
                            if (widget.inlineSearch) {
                              if (widget.submittedResults == null) {
                                widget.onSearchSubmitted?.call(_query);
                              }
                              return;
                            }
                            _query = title;
                            _finish();
                          },
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey('${_query.trim()}:${item.id}'),
                            tween: Tween(begin: 0, end: 1),
                            duration: Duration(
                              milliseconds:
                                  MediaQuery.disableAnimationsOf(context)
                                  ? 0
                                  : 180,
                            ),
                            builder: (_, value, child) =>
                                Opacity(opacity: value, child: child),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AspectRatio(
                                  key: ValueKey(
                                    'tv-recommendation-art-${item.sourceId}-${item.id}',
                                  ),
                                  aspectRatio: widget.inlineSearch
                                      ? 2 / 3
                                      : 16 / 9,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: SizedBox(
                                      width: cardWidth,
                                      child: artwork == null
                                          ? ColoredBox(
                                              color: AppColors.surface2,
                                              child: Icon(
                                                Icons.movie_outlined,
                                                color: AppColors.textSecondary,
                                              ),
                                            )
                                          : Image.network(
                                              artwork,
                                              headers: item.coverHeaders,
                                              cacheWidth: 320,
                                              fit: BoxFit.cover,
                                              alignment: Alignment.topCenter,
                                              errorBuilder: (_, _, _) =>
                                                  ColoredBox(
                                                    color: AppColors.surface2,
                                                    child: Icon(
                                                      Icons.movie_outlined,
                                                      color: AppColors
                                                          .textSecondary,
                                                    ),
                                                  ),
                                            ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                SizedBox(
                                  height: 34,
                                  child: Text(
                                    title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.2,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Handles remote Back and physical typing without opening a system IME.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      if (event is KeyUpEvent) _back();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.backspace) {
        _delete();
        return KeyEventResult.handled;
      }
      // Physical keyboards can also type, without creating an IME connection.
      final text = event.character;
      if (text != null && text.isNotEmpty && text.runes.every((c) => c >= 32)) {
        _insert(text);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Builds a remote key that requires its own press before accepting release.
  Widget _key(
    String id,
    String label,
    VoidCallback action, {
    bool autofocus = false,
    bool compact = false,
    bool actionKey = false,
    IconData? icon,
  }) => Expanded(
    child: Padding(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2)
          : const EdgeInsets.all(5),
      child: TvFocusable(
        key: ValueKey('tv-key-$id'),
        focusNode: widget.inlineSearch && autofocus ? _firstKeyFocus : null,
        autofocus: autofocus,
        waitForKeyUp: true,
        requireKeyDown: widget.inlineSearch,
        scale: 1,
        variant: compact ? TvFocusVariant.none : TvFocusVariant.box,
        semanticLabel: label,
        onTap: action,
        builder: (focused) => AnimatedContainer(
          duration: Duration(
            milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 110,
          ),
          curve: Curves.easeOutCubic,
          height: compact ? (widget.inlineSearch ? 24 : 34) : 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: focused
                ? Colors.white
                : compact && !actionKey
                ? (widget.inlineSearch
                      ? AppColors.surface2.withValues(alpha: 0.45)
                      : Colors.transparent)
                : AppColors.surface2,
            borderRadius: BorderRadius.circular(compact && !actionKey ? 10 : 8),
          ),
          child: icon != null
              ? Icon(
                  icon,
                  size: widget.inlineSearch ? 20 : 24,
                  color: focused ? Colors.black : AppColors.textPrimary,
                )
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: compact
                          ? (actionKey ? 12 : (widget.inlineSearch ? 16 : 17))
                          : 22,
                      fontWeight: compact ? FontWeight.w600 : FontWeight.normal,
                      color: focused ? Colors.black : AppColors.textPrimary,
                    ),
                  ),
                ),
        ),
      ),
    ),
  );

  /// Shows that the draft is being typed from a connected phone.
  Widget _phoneTypingPill() => Container(
    key: const ValueKey('tv-search-phone-typing'),
    margin: const EdgeInsets.only(left: 12),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.smartphone_rounded, color: AppColors.accent, size: 15),
        const SizedBox(width: 6),
        Text(
          'Typing from phone',
          style: TextStyle(
            color: AppColors.accent,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  /// Fits the alphabet grid above filters beside history and predictions.
  Widget _compactBody(BuildContext context) {
    final rows = _symbols
        ? ['1234567', '890@#&+', '!?/:;()', '[]{}=_-']
        : ['ABCDEFG', 'HIJKLMN', 'OPQRSTU', "VWXYZ-'"];
    final keyboard = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < rows.length; row++)
          Row(
            children: [
              for (final letter in rows[row].split(''))
                _key(
                  letter,
                  _uppercase ? letter : letter.toLowerCase(),
                  () => _insert(_uppercase ? letter : letter.toLowerCase()),
                  compact: true,
                  autofocus: !_symbols && letter == 'A',
                ),
              if (row == 0)
                _key(
                  'delete',
                  context.l10n.delete,
                  _delete,
                  compact: true,
                  icon: Icons.backspace_outlined,
                )
              else if (row == 1)
                _key(
                  'symbols',
                  _symbols ? 'ABC' : '&123',
                  () => setState(() {
                    _symbols = !_symbols;
                    _confirmBack = false;
                  }),
                  compact: true,
                )
              else if (row == 2)
                _key(
                  'case',
                  'aA',
                  () => setState(() {
                    _uppercase = !_uppercase;
                    _automaticCase = false;
                    _symbols = false;
                    _confirmBack = false;
                  }),
                  compact: true,
                )
              else
                _key('.', '.', () => _insert('.'), compact: true),
            ],
          ),
        const SizedBox(height: 4),
        Row(
          children: [
            _key(
              'space',
              'SPACE',
              () => _insert(' '),
              compact: true,
              actionKey: true,
            ),
            _key(
              'clear',
              context.l10n.clear.toUpperCase(),
              _clear,
              compact: true,
              actionKey: true,
            ),
            _key(
              'done',
              context.l10n.search.toUpperCase(),
              _finish,
              compact: true,
              actionKey: true,
            ),
          ],
        ),
      ],
    );
    final keyboardPanel = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(key: const ValueKey('tv-search-keyboard'), child: keyboard),
        if (widget.controls != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            key: const ValueKey('tv-search-keyboard-controls'),
            child: widget.controls!,
          ),
        ],
      ],
    );
    final predicting = _query.trim().characters.length >= 3;
    final suggestions = predicting
        ? _predictions
        : widget.recentQueries.take(4).toList();
    final history = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          predicting ? 'Search suggestions' : context.l10n.recentSearches,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 15),
        ),
        const SizedBox(height: 10),
        if (suggestions.isEmpty)
          Text(
            predicting
                ? (_loadingRecommendations
                      ? 'Finding suggestions…'
                      : 'Keep typing to refine your search')
                : context.l10n.searchForSomethingToWatch,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 15,
            ),
          ),
        for (final query in suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: TvFocusable(
              key: ValueKey('tv-search-suggestion-$query'),
              waitForKeyUp: true,
              requireKeyDown: widget.inlineSearch,
              scale: 1,
              onTap: () {
                setState(() {
                  _query = query;
                  _syncAutomaticCase();
                });
                widget.onQueryChanged?.call(_query);
                _bridgeChanged();
                _finish();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
                child: Row(
                  children: [
                    Icon(
                      predicting ? Icons.search_rounded : Icons.history_rounded,
                      color: AppColors.textSecondary,
                      size: 19,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
    return Align(
      alignment: widget.inlineSearch ? Alignment.topCenter : Alignment.center,
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: widget.inlineSearch ? 28 : 48,
          vertical: 16,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.search_rounded,
                      color: AppColors.textSecondary,
                      size: 24,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _query.isEmpty ? context.l10n.search : _query,
                        key: const ValueKey('tv-search-draft'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 22,
                        ),
                      ),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: TvKeyboardBridge.instance.phoneTyping,
                      builder: (context, typing, _) =>
                          typing ? _phoneTypingPill() : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 640
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.inlineSearch)
                            SizedBox(
                              key: const ValueKey('tv-search-history-column'),
                              width: (constraints.maxWidth - 324).clamp(
                                0.0,
                                360.0,
                              ),
                              child: history,
                            )
                          else
                            Expanded(flex: 4, child: history),
                          const SizedBox(width: 24),
                          if (widget.inlineSearch)
                            SizedBox(width: 300, child: keyboardPanel)
                          else
                            Expanded(flex: 6, child: keyboard),
                        ],
                      )
                    : Column(
                        children: [
                          if (widget.inlineSearch)
                            Align(
                              alignment: Alignment.centerRight,
                              child: SizedBox(width: 300, child: keyboardPanel),
                            )
                          else
                            keyboard,
                          const SizedBox(height: 24),
                          history,
                        ],
                      ),
              ),
              const SizedBox(height: 8),
              if (!widget.inlineSearch && widget.controls != null) ...[
                widget.controls!,
                const SizedBox(height: 10),
              ],
              _recommendationPanel(context),
              if (!widget.inlineSearch)
                Text(
                  _confirmBack ? context.l10n.pressBackAgainToExitTv : '',
                  key: const ValueKey('tv-search-back-hint'),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 16,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      key: const ValueKey('tv-search-input-screen'),
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: FocusScope(
          node: _keyboardFocus,
          onFocusChange: (focused) {
            // The shell seeds a traversal leaf when entering from the rail.
            // Start New on the keyboard even if it picks a control below it.
            if (!focused || !widget.inlineSearch || _seededKeyboardFocus) {
              return;
            }
            _seededKeyboardFocus = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  _keyboardFocus.hasFocus &&
                  _firstKeyFocus.canRequestFocus) {
                _firstKeyFocus.requestFocus();
              }
            });
          },
          child: Focus(
            skipTraversal: true,
            onKeyEvent: _onKey,
            child: widget.compactStyle
                ? _compactBody(context)
                : Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 48,
                        vertical: 20,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 860),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              context.l10n.search,
                              style: const TextStyle(
                                fontSize: 28,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _query.isEmpty ? '|' : _query,
                                key: const ValueKey('tv-search-draft'),
                                style: const TextStyle(
                                  fontSize: 26,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            for (final row in _rows)
                              Row(
                                children: [
                                  for (final letter in row.split(''))
                                    _key(
                                      letter,
                                      letter,
                                      () => _insert(letter),
                                      autofocus: letter == 'q',
                                    ),
                                ],
                              ),
                            Row(
                              children: [
                                _key('space', '␣', () => _insert(' ')),
                                _key('delete', '⌫', _delete),
                                _key('clear', context.l10n.clear, _clear),
                                _key('done', context.l10n.done, _finish),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _confirmBack
                                  ? context.l10n.pressBackAgainToExitTv
                                  : '',
                              key: const ValueKey('tv-search-back-hint'),
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
    // Observed by the phone keyboard bridge; never takes focus itself.
    final page = Focus(focusNode: _rootFocus, child: scaffold);
    // Inline New search is the destination itself. Back belongs to the shell,
    // which returns to Home; there is no classic search route underneath it.
    if (widget.inlineSearch) return page;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: page,
    );
  }
}
