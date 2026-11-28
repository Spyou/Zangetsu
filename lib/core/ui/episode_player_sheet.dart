import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/video_source.dart';
import 'copy_playback_link.dart';
import '../playback/external_player.dart';
import '../playback/source_selection.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// What a long-press on an episode chose: which player to open it in, this
/// once. An empty [package] means the built-in player.
typedef PlayerChoice = ({String package, String label});

/// What the long-press menu was asked to do. The player pick is its own sheet,
/// so this only carries the actions that don't need further input.
enum EpisodeAction {
  /// Open the "play this episode with" sheet.
  pickPlayer,

  /// Drop this episode's cached links and play again. For when a mirror has
  /// expired and every attempt fails on links that looked fine 20 minutes ago.
  reloadLinks,

  /// Flip this episode's watched state by hand, and move any connected
  /// tracker with it.
  toggleWatched,

  /// Mark this episode and everything before it watched — the "came back
  /// mid-season" case, where marking twelve episodes one at a time is the
  /// reason people give up and edit their list on the website instead.
  markAboveWatched,

  /// Resolve the episode's mirrors and pick one before anything plays, rather
  /// than starting on whichever the app chose and switching afterwards.
  playMirror,

  /// Open this chapter's page on the source's own site, in the in-app
  /// browser. Reading only — for when the reader can't render it.
  openInBrowser,

  /// Ask every installed source whether it has THIS episode, and watch them
  /// answer. Different from [playMirror]: that picks between mirrors within
  /// the one source already matched, this is about which SOURCE to use at all.
  whereToWatch,
}

/// The long-press menu itself. Kept separate from the player sheet so the
/// player list doesn't push the actions off-screen once several players are
/// installed.
Future<EpisodeAction?> showEpisodeActionSheet(
  BuildContext context, {
  required String episodeLabel,
  required String currentPlayerLabel,

  /// Offers the "Where to watch" row. Only true for metadata titles: a
  /// source-backed one already IS a single source, so there is nothing to
  /// survey.
  bool canSurveySources = false,

  /// Drives the watched row's wording — the same row unmarks when the episode
  /// is already watched, so a mis-tap isn't a one-way door.
  required bool isWatched,

  /// Whether any tracker is linked. Only used for the subtitle, so nobody is
  /// surprised that marking an episode moved their AniList progress.
  required bool tracksToServices,

  /// Whether this chapter has a page that can be opened on the source's own
  /// site. Reading only; hidden rather than greyed, because a source that keys
  /// chapters by an internal id has nothing to open.
  bool canOpenInBrowser = false,

  /// Manga/novel. Leaves ONLY the two marking rows, reworded as read rather
  /// than watched. Everything above them is about playback — a chapter
  /// resolves to the reader, so there is no player to pick, no mirror to
  /// choose, no stream to reload, and no point surveying sources for one.
  bool reading = false,
}) {
  // Without isScrollControlled a sheet is capped at 9/16 of the screen
  // (_kDefaultScrollControlDisabledMaxHeightRatio) and anything past that is
  // simply clipped — no scrolling, no warning. These rows come to ~493dp once
  // the tracker subtitle is on, which needs an ~876dp-tall screen to clear the
  // cap. Most phones are shorter, so "Mark this and all above as watched" was
  // cut off the bottom edge. Same treatment showEpisodePlayerSheet below
  // already gets, for the same reason.
  return showModalBottomSheet<EpisodeAction>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        // Not full height: the list is short, and keeping the episode list
        // visible behind it is what makes this read as a menu.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    episodeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.headline,
                  ),
                ),
              ),
              if (!reading) ...[
                _PlayerRow(
                  icon: Icons.play_circle_outline_rounded,
                  label: 'Play with…',
                  trailingText: currentPlayerLabel,
                  onTap: () =>
                      Navigator.pop(sheetContext, EpisodeAction.pickPlayer),
                ),
                _PlayerRow(
                  icon: Icons.swap_horiz_rounded,
                  label: 'Play mirror',
                  subtitle: 'Choose the source before it starts',
                  onTap: () =>
                      Navigator.pop(sheetContext, EpisodeAction.playMirror),
                ),
              ],
              // Streaming only, like the two rows above it: reading gets the
              // marking rows and nothing else.
              if (canSurveySources && !reading)
                _PlayerRow(
                  icon: Icons.travel_explore_rounded,
                  label: 'Where to watch',
                  subtitle: 'See which of your sources has this episode',
                  onTap: () =>
                      Navigator.pop(sheetContext, EpisodeAction.whereToWatch),
                ),
              if (!reading)
                _PlayerRow(
                  icon: Icons.refresh_rounded,
                  label: 'Reload links',
                  subtitle: 'Fetch fresh streams if playback keeps failing',
                  onTap: () =>
                      Navigator.pop(sheetContext, EpisodeAction.reloadLinks),
                ),
              Divider(height: 1, color: AppColors.hairline),
              _PlayerRow(
                icon: isWatched
                    ? Icons.remove_done_rounded
                    : Icons.check_circle_outline_rounded,
                label: reading
                    ? (isWatched ? 'Mark as unread' : 'Mark as read')
                    : (isWatched ? 'Mark as unwatched' : 'Mark as watched'),
                subtitle: tracksToServices
                    ? 'Also updates your connected trackers'
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, EpisodeAction.toggleWatched),
              ),
              _PlayerRow(
                icon: Icons.done_all_rounded,
                label: reading
                    ? 'Mark this and all above as read'
                    : 'Mark this and all above as watched',
                onTap: () =>
                    Navigator.pop(sheetContext, EpisodeAction.markAboveWatched),
              ),
              if (reading && canOpenInBrowser)
                _PlayerRow(
                  icon: Icons.public_rounded,
                  label: 'Open in browser',
                  subtitle: "Read it on the source's own site",
                  onTap: () =>
                      Navigator.pop(sheetContext, EpisodeAction.openInBrowser),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Long-press an episode → pick where it plays, for this episode only.
///
/// Deliberately doesn't touch [PlaybackPrefs.externalPlayerPackage]: Settings
/// stays the place that says "always use X", and trying VLC once shouldn't
/// quietly rewire every future tap.
///
/// Returns null when dismissed — a long-press that starts playback on its own
/// would be a trap.
Future<PlayerChoice?> showEpisodePlayerSheet(
  BuildContext context, {
  required String episodeLabel,
  required String defaultPackage,
}) async {
  final installed = await ExternalPlayer().installed();
  if (!context.mounted) return null;

  return showModalBottomSheet<PlayerChoice>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    // The list is short, but a device with several players installed plus a
    // long episode title shouldn't push the last row off-screen.
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    'Play this episode with',
                    style: AppText.headline,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    episodeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              _PlayerRow(
                icon: Icons.play_circle_outline_rounded,
                label: 'Built-in player',
                isDefault: defaultPackage.isEmpty,
                onTap: () => Navigator.pop(sheetContext, (
                  package: '',
                  label: 'Built-in player',
                )),
              ),
              for (final p in installed.where((p) => p.known))
                _PlayerRow(
                  icon: Icons.open_in_new_rounded,
                  label: p.label,
                  isDefault: defaultPackage == p.package,
                  onTap: () => Navigator.pop(sheetContext, (
                    package: p.package,
                    label: p.label,
                  )),
                ),
              // Everything else on the device that answers a video intent. They
              // play — header-gated streams too, via the local proxy — but we
              // don't know which intent extras they read, so external subtitles
              // and the resume position may be ignored. Under their own heading
              // because some are galleries or browsers rather than players at
              // all, hence "apps", not "players".
              if (installed.any((p) => !p.known)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      'Other apps',
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                for (final p in installed.where((p) => !p.known))
                  _PlayerRow(
                    icon: Icons.open_in_new_rounded,
                    label: p.label,
                    isDefault: defaultPackage == p.package,
                    onTap: () => Navigator.pop(sheetContext, (
                      package: p.package,
                      label: p.label,
                    )),
                  ),
              ],
              // Opening an empty sheet on long-press reads as a broken gesture,
              // so say why there's only one row rather than showing nothing.
              if (installed.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Text(
                    'No other video apps installed. VLC, MX Player and '
                    'Just Player all show up here once installed.',
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Pick one of an episode's mirrors.
///
/// Opens at once, even with nothing resolved yet: an empty [sources] with
/// [loadingMore] true shows placeholder rows, and links fill in as [live]
/// grows. [loadingMore] drives the status line at the bottom; when it ends on
/// an empty list the sheet offers [onRetry]. [lastUsedLabel] pins the server
/// remembered for this title to the top.
Future<VideoSource?> showMirrorSheet(
  BuildContext context, {
  required String episodeLabel,
  List<VideoSource> sources = const [],
  ValueListenable<List<VideoSource>>? live,
  ValueListenable<bool>? loadingMore,
  String? lastUsedLabel,
  VoidCallback? onRetry,
}) {
  return showModalBottomSheet<VideoSource>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    isScrollControlled: true,
    builder: (sheetContext) => _MirrorSheet(
      episodeLabel: episodeLabel,
      initial: sources,
      live: live,
      loadingMore: loadingMore,
      lastUsedLabel: lastUsedLabel?.trim(),
      onRetry: onRetry,
    ),
  );
}

class _MirrorSheet extends StatefulWidget {
  const _MirrorSheet({
    required this.episodeLabel,
    required this.initial,
    this.live,
    this.loadingMore,
    this.lastUsedLabel,
    this.onRetry,
  });

  final String episodeLabel;
  final List<VideoSource> initial;
  final ValueListenable<List<VideoSource>>? live;
  final ValueListenable<bool>? loadingMore;
  final String? lastUsedLabel;
  final VoidCallback? onRetry;

  @override
  State<_MirrorSheet> createState() => _MirrorSheetState();
}

class _MirrorSheetState extends State<_MirrorSheet> {
  // Sorted rows are rebuilt only when the list changes, not on every repaint.
  List<VideoSource>? _forList;
  List<({AudioKind kind, VideoSource source})> _rows = const [];

  List<({AudioKind kind, VideoSource source})> _rowsFor(
    List<VideoSource> list,
  ) {
    if (!identical(list, _forList)) {
      _forList = list;
      _rows = [
        for (final k in availableKinds(list))
          for (final s in sortByQuality(sourcesForKind(list, k)))
            (kind: k, source: s),
      ];
    }
    return _rows;
  }

  bool _isLastUsed(VideoSource s) =>
      widget.lastUsedLabel != null &&
      widget.lastUsedLabel!.isNotEmpty &&
      (s.label ?? '').trim() == widget.lastUsedLabel;

  Widget _header(String? count) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Choose a link', style: AppText.headline),
              Text(
                widget.episodeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        if (count != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              count,
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
      ],
    ),
  );

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
    child: Text(
      text.toUpperCase(),
      style: AppText.caption.copyWith(
        color: AppColors.textTertiary,
        letterSpacing: 1.1,
        fontSize: 11,
      ),
    ),
  );

  Widget _row(AudioKind k, VideoSource s) {
    final hasLabel = s.label?.trim().isNotEmpty == true;
    final container = s.container == SourceContainer.unknown
        ? null
        : s.container.name.toUpperCase();
    final sub = [
      ?container,
      if (k != AudioKind.unknown) k.name.toUpperCase(),
    ].join(' · ');
    // No label: the quality (or container) is the name, so it isn't repeated
    // on the right.
    final quality = hasLabel ? s.quality : null;
    return InkWell(
      onTap: () => Navigator.pop(context, s),
      onLongPress: () => copyPlaybackLink(context, s.url),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasLabel
                        ? s.label!.trim()
                        : (s.quality ?? s.container.name.toUpperCase()),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (quality != null)
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Text(
                  quality,
                  style: AppText.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _divider() =>
      Divider(height: 1, thickness: 1, color: AppColors.hairline);

  Widget _status() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _rows.isEmpty ? 'Finding links…' : 'Finding more links…',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
      ],
    ),
  );

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off_rounded, size: 30, color: AppColors.textSecondary),
        const SizedBox(height: 8),
        Text(
          'No links for this episode',
          style: AppText.body.copyWith(color: AppColors.textSecondary),
        ),
        if (widget.onRetry != null) ...[
          const SizedBox(height: 12),
          TextButton(onPressed: widget.onRetry, child: const Text('Retry')),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final loadingListenable = widget.loadingMore ?? ValueNotifier<bool>(false);
    return SafeArea(
      child: ConstrainedBox(
        // A floor so the sheet doesn't jump taller as links arrive.
        constraints: BoxConstraints(
          minHeight: height * 0.45,
          maxHeight: height * 0.75,
        ),
        child: ValueListenableBuilder<List<VideoSource>>(
          valueListenable:
              widget.live ?? ValueNotifier<List<VideoSource>>(widget.initial),
          builder: (context, list, _) => ValueListenableBuilder<bool>(
            valueListenable: loadingListenable,
            builder: (context, loading, _) {
              final rows = _rowsFor(list);
              final last = [
                for (final r in rows)
                  if (_isLastUsed(r.source)) r,
              ];
              final rest = [
                for (final r in rows)
                  if (!_isLastUsed(r.source)) r,
              ];
              Iterable<Widget> rowsOf(
                List<({AudioKind kind, VideoSource source})> items,
              ) sync* {
                for (var i = 0; i < items.length; i++) {
                  if (i > 0) yield _divider();
                  yield _row(items[i].kind, items[i].source);
                }
              }

              final children = <Widget>[
                if (last.isNotEmpty) ...[
                  _section('Last used'),
                  ...rowsOf(last),
                  if (rest.isNotEmpty) _section('More links'),
                ],
                ...rowsOf(rest),
                if (loading) ...[
                  for (var i = 0; i < (rows.isEmpty ? 3 : 1); i++)
                    const _SkeletonRow(),
                ],
              ];
              // Count top right once it's final; while loading the bottom
              // line carries the state instead.
              final count = !loading && rows.isNotEmpty
                  ? '${rows.length} ${rows.length == 1 ? 'link' : 'links'}'
                  : null;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  _header(count),
                  Flexible(
                    child: rows.isEmpty && !loading
                        ? _empty()
                        : ListView(
                            shrinkWrap: true,
                            padding: const EdgeInsets.only(bottom: 4),
                            children: children,
                          ),
                  ),
                  if (loading) _status(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A row-shaped placeholder: two text bars and a small quality box, with a
/// light sweep across them.
class _SkeletonRow extends StatefulWidget {
  const _SkeletonRow();

  @override
  State<_SkeletonRow> createState() => _SkeletonRowState();
}

class _SkeletonRowState extends State<_SkeletonRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _bar(double w, double h) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment(-1.5 + _c.value * 3, 0),
          end: Alignment(-0.5 + _c.value * 3, 0),
          colors: [
            AppColors.surface2,
            AppColors.surface2.withValues(alpha: 0.5),
            AppColors.surface2,
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_bar(140, 12), const SizedBox(height: 8), _bar(84, 9)],
          ),
        ),
        _bar(38, 12),
      ],
    ),
  );
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDefault = false,
    this.subtitle,
    this.trailingText,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Marks the row a plain tap would have used. Marked rather than sorted to
  /// the top, so the list doesn't reshuffle when the Settings default changes.
  final bool isDefault;
  final String? subtitle;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final trailing = trailingText ?? (isDefault ? 'Default' : null);
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(label, style: AppText.body),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
      trailing: trailing == null
          ? null
          : Text(
              trailing,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
      onTap: onTap,
    );
  }
}
