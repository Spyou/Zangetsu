import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../anilist/anilist_service.dart';
import '../di/injector.dart';
import '../models/watch_status.dart';
import '../models/provider_info.dart';
import '../models/media_item.dart';
import '../tracker/airing_countdown.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'anilist_custom_lists_sheet.dart';
import '../tracker/tracker.dart';
import '../tracker/tracker_binding_store.dart';
import '../tracker/tracker_hub.dart';
import '../tv/tv_focusable.dart';
import 'global_messenger.dart';

/// Tracker sync sheet. Reads the user's current entry for one title from the
/// connected trackers, lets them edit status / score / episode progress in one
/// place, and on Apply writes the CHANGED fields back to every connected
/// tracker at once. Works on phone and TV (D-pad via [TvFocusable]).
///
/// Returns the episode progress the user applied (so the detail screen can grey
/// out watched episodes immediately), or null if nothing was applied.
///
/// [reading] targets manga/novel (chapters, not episodes) — it defaults to
/// `false`, reproducing today's anime/movie behaviour exactly for every
/// existing caller (including the TV detail screen, which never shows a
/// reading title and must never change).
Future<int?> showTrackerSyncSheet(
  BuildContext context, {
  required String title,
  required bool isAnime,
  bool reading = false,
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
  String? bindingKey,
  Tracker? tracker,
}) {
  return showModalBottomSheet<int?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => TrackerSyncSheet(
      title: title,
      isAnime: isAnime,
      reading: reading,
      malId: malId,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      bindingKey: bindingKey,
      tracker: tracker,
    ),
  );
}

class TrackerSyncSheet extends StatefulWidget {
  const TrackerSyncSheet({
    super.key,
    required this.title,
    required this.isAnime,
    this.reading = false,
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
    this.bindingKey,
    this.tracker,
  });

  final String title;
  final bool isAnime;

  /// Manga/novel item — chapters, not episodes. Defaults to `false`, so every
  /// call site that doesn't pass it (including the TV detail screen) behaves
  /// exactly as before.
  final bool reading;
  final int? malId;
  final int? tmdbId;
  final bool tmdbIsTv;
  final String? imdbId;

  /// `sourceId|showUrl` key for persisted match corrections, or null (no
  /// persistence — a picked match still applies for this session).
  final String? bindingKey;

  /// Edit one tracker instead of all of them. Null keeps the original
  /// behaviour — read whichever tracker answers first, write to every
  /// connected one — which is what the TV screen and "Sync all" rely on.
  final Tracker? tracker;

  @override
  State<TrackerSyncSheet> createState() => _TrackerSyncSheetState();
}

class _TrackerSyncSheetState extends State<TrackerSyncSheet> {
  final _hub = sl<TrackerHub>();
  late final bool _isTv = sl<AppMode>().isTv;

  bool _loading = true;
  bool _saving = false;

  // Manual match corrections: {trackerName: native id}. Loaded from the binding
  // store, updated by "Change match". Empty = automatic malId/title resolution.
  Map<String, String> _pinnedIds = const {};

  /// What the tracker matched this to, for the "is this even the right show?"
  /// line. Null when the tracker didn't say (or found nothing).
  String? _matchedTitle;

  /// Trackers holding DIFFERENT progress for this title, in combined mode.
  /// Empty when they agree (or only one has it), which is the normal case.
  /// Applying used to silently drag the higher one back down to the lower.
  List<TrackerEntry> _conflicts = const [];

  // Current (editable) values.
  WatchStatus? _status;
  int _score = 0; // 0 = unrated, else 1–10
  int _progress = 0;
  int? _maxEpisodes;
  int? _nextEp;
  DateTime? _nextAt;

  // Loaded baseline — Apply only pushes fields the user actually changed, so an
  // untouched field never clobbers what's already on the tracker.
  WatchStatus? _initStatus;
  int _initScore = 0;
  int _initProgress = 0;

  bool get _showEpisodes =>
      (widget.isAnime || widget.reading) &&
      (_maxEpisodes == null || _maxEpisodes! != 1);

  /// Reading → manga. Anime (including anime FILMS) → anime. Anything else is
  /// a TMDB movie/series, which only Simkl has a catalogue for — telling those
  /// apart is what stops a movie's "Change match" searching Simkl's anime
  /// catalogue and coming back empty.
  MediaKind get _kind {
    if (widget.reading) return MediaKind.manga;
    if (widget.isAnime) return MediaKind.anime;
    return widget.tmdbIsTv ? MediaKind.tv : MediaKind.movie;
  }

  @override
  void initState() {
    super.initState();
    final key = widget.bindingKey;
    if (key != null) {
      _pinnedIds = Map<String, String>.from(sl<TrackerBindingStore>().get(key));
    }
    _load();
  }

  /// Combined mode: read every tracker, note any progress disagreement, and
  /// return the same entry [TrackerHub.fetchEntry] would have — first one
  /// that's on a list, else the first that answered at all.
  Future<TrackerEntry?> _loadCombined() async {
    final all = await _hub.fetchEntries(
      malId: widget.malId,
      title: (widget.isAnime || widget.reading) ? widget.title : null,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
      pinnedIds: _pinnedIds,
      kind: _kind,
    );
    // Only entries actually on a list can disagree — a tracker that's never
    // seen the title has no opinion to conflict with.
    _conflicts = [
      for (final e in all)
        if (e.onList && e.progress != null && e.progress! > 0) e,
    ];
    if (_conflicts.map((e) => e.progress).toSet().length < 2) {
      _conflicts = const [];
    }
    for (final e in all) {
      if (e.onList) return e;
    }
    return all.isEmpty ? null : all.first;
  }

  Future<void> _load() async {
    final one = widget.tracker;
    final entry = one != null
        ? await one.fetchEntry(
            malId: widget.malId,
            title: (widget.isAnime || widget.reading) ? widget.title : null,
            tmdbId: widget.tmdbId,
            tmdbIsTv: widget.tmdbIsTv,
            imdbId: widget.imdbId,
            pinnedId: _pinnedIds[one.displayName],
            kind: _kind,
          )
        : await _loadCombined();
    if (!mounted) return;
    setState(() {
      _matchedTitle = entry?.title;
      _status = entry?.status;
      _score = (entry?.score ?? 0).round().clamp(0, 10);
      // When trackers disagree, start from the furthest along — pulling the
      // others up is recoverable, dragging someone backwards isn't.
      _progress = _conflicts.isEmpty
          ? (entry?.progress ?? 0)
          : _conflicts
              .map((e) => e.progress ?? 0)
              .reduce((a, b) => a > b ? a : b);
      _maxEpisodes = widget.reading ? entry?.chapters : entry?.maxEpisodes;
      _nextEp = entry?.nextAiringEpisode;
      _nextAt = entry?.nextAiringAt;
      _initStatus = _status;
      _initScore = _score;
      // Baseline is what we READ, not what we pre-filled. With a conflict the
      // two differ on purpose, so Apply sees a change and actually levels the
      // trackers up — baselining the pre-filled value made Apply a no-op and
      // left the behind tracker behind.
      _initProgress = entry?.progress ?? 0;
      _loading = false;
    });
  }

  Future<void> _apply() async {
    final statusChanged = _status != _initStatus;
    final scoreChanged = _score != _initScore;
    final progressChanged = _progress != _initProgress;
    if (!statusChanged && !scoreChanged && !progressChanged) {
      Navigator.pop(context);
      return;
    }
    setState(() => _saving = true);
    final one = widget.tracker;
    if (one != null) {
      await one.updateEntry(
        malId: widget.malId,
        title: (widget.isAnime || widget.reading) ? widget.title : null,
        tmdbId: widget.tmdbId,
        tmdbIsTv: widget.tmdbIsTv,
        imdbId: widget.imdbId,
        pinnedId: _pinnedIds[one.displayName],
        status: statusChanged ? _status : null,
        score: scoreChanged ? _score.toDouble() : null,
        progress: progressChanged ? _progress : null,
        kind: _kind,
      );
    } else {
      await _hub.updateEntry(
        malId: widget.malId,
        title: (widget.isAnime || widget.reading) ? widget.title : null,
        tmdbId: widget.tmdbId,
        tmdbIsTv: widget.tmdbIsTv,
        imdbId: widget.imdbId,
        pinnedIds: _pinnedIds,
        status: statusChanged ? _status : null,
        score: scoreChanged ? _score.toDouble() : null,
        progress: progressChanged ? _progress : null,
        kind: _kind,
      );
    }
    if (!mounted) return;
    final names = one?.displayName ??
        _hub.connected.map((t) => t.displayName).join(', ');
    showGlobalSnack('Synced to $names');
    Navigator.pop(context, progressChanged ? _progress : null);
  }

  /// Fix a wrong auto-match: search the trackers, let the user pick the right
  /// entry, pin it (persisted via the binding store), and reload the sheet.
  Future<void> _changeMatch() async {
    final picked = await showTrackerMatchPicker(
      context,
      initialQuery: widget.title,
      // Editing one tracker → only offer that tracker's candidates, so picking
      // a match can't quietly rebind a tracker you weren't looking at.
      tracker: widget.tracker,
      // Without this the picker takes its MediaKind.anime default, and Simkl
      // searches its ANIME catalogue for a film — the picker opens and finds
      // nothing, which is exactly how this looked broken.
      kind: _kind,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pinnedIds = {..._pinnedIds, picked.trackerName: picked.id};
      _loading = true;
    });
    final key = widget.bindingKey;
    if (key != null) {
      await sl<TrackerBindingStore>().set(key, picked.trackerName, picked.id);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('Tracking', style: AppText.headline),
              const SizedBox(height: 2),
              _connectedLine(),
              const SizedBox(height: 18),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                )
              else
                ..._editor(),
            ],
          ),
        ),
      ),
    );
  }

  /// Shown when two trackers hold different progress. Applying writes ONE
  /// value to all of them, so the user should see what they're about to
  /// flatten before pressing the button, not afterwards.
  Widget _conflictBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Your trackers disagree',
            style: AppText.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          for (final e in _conflicts)
            Text(
              '${e.trackerName}  ·  ${widget.reading ? "ch" : "ep"} ${e.progress}',
              style: AppText.caption,
            ),
          const SizedBox(height: 4),
          Text(
            'Applying sets them all to the number below.',
            style: AppText.caption,
          ),
        ],
      ),
    );
  }

  List<Widget> _editor() {
    return [
      if (_conflicts.isNotEmpty) _conflictBanner(),
      _sectionLabel('STATUS'),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < WatchStatus.values.length; i++)
            _statusChip(WatchStatus.values[i], autofocus: i == 0),
        ],
      ),
      const SizedBox(height: 20),
      _sectionLabel('YOUR SCORE'),
      const SizedBox(height: 8),
      _stepperRow(
        value: _score == 0 ? 'Not rated' : '$_score / 10',
        onMinus: () => setState(() => _score = (_score - 1).clamp(0, 10)),
        onPlus: () => setState(() => _score = (_score + 1).clamp(0, 10)),
      ),
      if (_showEpisodes) ...[
        const SizedBox(height: 20),
        _sectionLabel(widget.reading ? 'CHAPTERS READ' : 'EPISODES WATCHED'),
        const SizedBox(height: 8),
        _stepperRow(
          value: '$_progress / ${_maxEpisodes ?? '?'}',
          onMinus: () => setState(
            () => _progress = (_progress - 1).clamp(0, _maxEpisodes ?? 9999),
          ),
          onPlus: () => setState(
            () => _progress = (_progress + 1).clamp(0, _maxEpisodes ?? 9999),
          ),
        ),
      ],
      if (_nextEp != null && _nextAt != null) ...[
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 15,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              'Ep $_nextEp airs in ${airsIn(_nextAt!)}',
              style: AppText.caption,
            ),
          ],
        ),
      ],
      const SizedBox(height: 24),
      _applyButton(),
      // Every kind gets this. It rendered for anime only at first, then anime
      // + reading; a movie or series matched to the wrong Simkl entry was still
      // stuck with no way to correct it. There is no kind for which "the app
      // guessed, and it can guess wrong" stops being true.
      ...[
        const SizedBox(height: 8),
        _focusable(
          onTap: _changeMatch,
          semantic: 'Change tracker match',
          scale: 1.02,
          child: Container(
            height: 42,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Naming the match is the whole point — without it there's no
                // way to tell a wrong auto-match from a right one.
                if (_matchedTitle != null)
                  Text(
                    'Matched: ${_matchedTitle!}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                Text(
                  'Wrong title?  Change match',
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ],
      ..._customListsRow(),
    ];
  }

  /// AniList's own custom lists, reachable from the detail screen's Tracking
  /// sheet as well as the library — this is where someone lands right after
  /// adding a title, which is exactly when they'd want to file it.
  ///
  /// AniList only, via an `is` check: MAL's API has no such concept and
  /// Simkl's lists are a fixed set, so the row simply isn't there for them.
  List<Widget> _customListsRow() {
    final t = widget.tracker;
    if (t is! AniListService) return const [];
    return [
      const SizedBox(height: 6),
      InkWell(
        onTap: () async {
          final rootContext =
              Navigator.of(context, rootNavigator: true).context;
          Navigator.pop(context);
          await showAniListCustomListsSheet(
            rootContext,
            t,
            // This sheet carries a title + ids rather than a MediaItem, and
            // the picker only needs enough to resolve the AniList media —
            // which is exactly malId/title, the same pair every other write
            // here resolves with.
            MediaItem(
              id: widget.title,
              title: widget.title,
              url: '',
              type: widget.reading ? ProviderType.manga : ProviderType.anime,
              sourceId: '',
              malId: widget.malId,
            ),
            const [],
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.playlist_add_rounded,
                  size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'AniList custom lists',
                  style:
                      AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    ];
  }

  /// The "AniList · MyAnimeList · Simkl" caption under the title. For a
  /// reading item, Simkl (no manga/novel API) gets a dimmed "(no manga)" note
  /// instead of being silently dropped — the same reduced-emphasis text color
  /// the rest of the app already uses for an unavailable/disabled affordance
  /// (e.g. source_health_screen.dart's "Not searched" caption), not a new
  /// pattern. Non-reading items keep the original plain joined-name Text.
  Widget _connectedLine() {
    // Editing one tracker → name only that one. Listing every connected
    // account here read as though Apply would write to all of them.
    final one = widget.tracker;
    if (one != null) {
      return Text(one.displayName, style: AppText.caption);
    }
    final names = _hub.connected.map((t) => t.displayName).toList();
    if (!widget.reading) {
      return Text(names.join('  ·  '), style: AppText.caption);
    }
    return Text.rich(
      TextSpan(
        style: AppText.caption,
        children: [
          for (var i = 0; i < names.length; i++)
            TextSpan(
              text:
                  '${i > 0 ? '  ·  ' : ''}${names[i]}'
                  '${names[i] == 'Simkl' ? ' (no manga)' : ''}',
              style: names[i] == 'Simkl'
                  ? TextStyle(color: AppColors.textTertiary)
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String s) => Text(s, style: AppText.overline);

  Widget _statusChip(WatchStatus s, {bool autofocus = false}) {
    final selected = _status == s;
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? AppColors.accent : AppColors.surface2,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        s.shortLabel,
        style: AppText.body.copyWith(
          color: selected ? Colors.white : AppColors.textSecondary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
    // Tapping the selected chip again clears the selection (null = leave the
    // tracker's status untouched on Apply).
    void toggle() => setState(() => _status = selected ? null : s);
    return _focusable(
      onTap: toggle,
      autofocus: autofocus,
      semantic: '${s.shortLabel} status',
      child: chip,
    );
  }

  Widget _stepperRow({
    required String value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    return Row(
      children: [
        _roundButton(Icons.remove_rounded, onMinus, 'Decrease'),
        Expanded(
          child: Center(
            child: Text(
              value,
              style: AppText.headline.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        _roundButton(Icons.add_rounded, onPlus, 'Increase'),
      ],
    );
  }

  Widget _roundButton(IconData icon, VoidCallback onTap, String semantic) {
    final btn = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: AppColors.textPrimary, size: 22),
    );
    return _focusable(
      onTap: onTap,
      semantic: semantic,
      variant: TvFocusVariant.box,
      scale: 1.12,
      child: btn,
    );
  }

  Widget _applyButton() {
    final child = Container(
      height: 50,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: _saving
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            )
          : Text('Apply', style: AppText.button.copyWith(color: Colors.white)),
    );
    return _focusable(
      onTap: _saving ? () {} : _apply,
      semantic: 'Apply tracking changes',
      variant: TvFocusVariant.box,
      scale: 1.03,
      child: child,
    );
  }

  /// D-pad focusable on TV, a plain ripple on touch — one call site, both worlds.
  Widget _focusable({
    required Widget child,
    required VoidCallback onTap,
    String? semantic,
    bool autofocus = false,
    TvFocusVariant variant = TvFocusVariant.box,
    double scale = 1.06,
  }) {
    if (_isTv) {
      return TvFocusable(
        onTap: onTap,
        autofocus: autofocus,
        variant: variant,
        scale: scale,
        semanticLabel: semantic,
        child: child,
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: child,
    );
  }

}

/// Search each connected tracker for the correct entry and return the picked
/// candidate (used by [TrackerSyncSheet]'s "Change match"). Null on dismiss.
Future<TrackerSearchResult?> showTrackerMatchPicker(
  BuildContext context, {
  required String initialQuery,
  Tracker? tracker,
  MediaKind kind = MediaKind.anime,
}) {
  return showModalBottomSheet<TrackerSearchResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _TrackerMatchPicker(
      initialQuery: initialQuery,
      tracker: tracker,
      kind: kind,
    ),
  );
}

class _TrackerMatchPicker extends StatefulWidget {
  const _TrackerMatchPicker({
    required this.initialQuery,
    this.tracker,
    this.kind = MediaKind.anime,
  });
  final String initialQuery;

  /// Search only this tracker. Null searches every connected one, which is
  /// what the combined sheet has always done.
  final Tracker? tracker;
  final MediaKind kind;

  @override
  State<_TrackerMatchPicker> createState() => _TrackerMatchPickerState();
}

class _TrackerMatchPickerState extends State<_TrackerMatchPicker> {
  final _hub = sl<TrackerHub>();
  late final bool _isTv = sl<AppMode>().isTv;
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );

  bool _searching = true;
  List<TrackerSearchResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final one = widget.tracker;
    // One tracker failing its own search shouldn't leave the sheet spinning —
    // the hub path already swallows per-tracker errors the same way.
    final r = one != null
        ? await one
            .searchEntries(q, kind: widget.kind)
            .catchError((_) => const <TrackerSearchResult>[])
        : await _hub.searchEntries(q, kind: widget.kind);
    if (!mounted) return;
    setState(() {
      _results = r;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.72;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: !_isTv,
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: InputDecoration(
                          hintText: 'Search the correct title…',
                          hintStyle: AppText.body,
                          filled: true,
                          fillColor: AppColors.surface2,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _searchButton(),
                  ],
                ),
              ),
              Flexible(child: _body()),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchButton() {
    final btn = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.search_rounded, color: Colors.white),
    );
    if (_isTv) {
      return TvFocusable(
        onTap: _search,
        variant: TvFocusVariant.box,
        semanticLabel: 'Search',
        child: btn,
      );
    }
    return InkWell(
      onTap: _search,
      borderRadius: BorderRadius.circular(12),
      child: btn,
    );
  }

  Widget _body() {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text('No matches found', style: AppText.body)),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _results.length,
      itemBuilder: (_, i) =>
          _resultRow(_results[i], autofocus: _isTv && i == 0),
    );
  }

  Widget _resultRow(TrackerSearchResult r, {bool autofocus = false}) {
    final subtitleParts = [
      r.trackerName,
      if (r.subtitle != null && r.subtitle!.isNotEmpty) r.subtitle!,
      if (r.maxEpisodes != null) '${r.maxEpisodes} eps',
    ];
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 42,
              height: 60,
              child: r.cover == null
                  ? Container(color: AppColors.surface2)
                  : CachedNetworkImage(
                      imageUrl: r.cover!,
                      fit: BoxFit.cover,
                      placeholder: (_, _) =>
                          Container(color: AppColors.surface2),
                      errorWidget: (_, _, _) =>
                          Container(color: AppColors.surface2),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(subtitleParts.join('  ·  '), style: AppText.caption),
              ],
            ),
          ),
        ],
      ),
    );
    void pick() => Navigator.pop(context, r);
    if (_isTv) {
      return TvFocusable(
        onTap: pick,
        autofocus: autofocus,
        variant: TvFocusVariant.box,
        scale: 1.03,
        semanticLabel: '${r.title}, ${r.trackerName}',
        child: row,
      );
    }
    return InkWell(
      onTap: pick,
      borderRadius: BorderRadius.circular(10),
      child: row,
    );
  }
}
