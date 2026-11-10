import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/video_source.dart';
import '../../core/stremio/stremio_link_session.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/stremio/stremio_addon_icon.dart';
import '../../core/stremio/stremio_ref.dart';
import '../../core/stremio/stremio_stream_mapping.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Stremio-owned titles bypass the normal extension resolver: Play, Resume
/// and episode taps open this grouped links sheet instead.
bool usesStremioLinks(String sourceId, {VideoSource? initialSource}) =>
    sourceId == stremioSourceId && initialSource == null;

/// Links grouped by addon, ordered by installation. Returns the exact chosen
/// source (with its headers) or null when dismissed.
Future<VideoSource?> showStremioEpisodeLinksSheet(
  BuildContext context, {
  required StremioManager manager,
  required StremioRef ref,
  required String title,
  List<StremioStream> inlineStreams = const [],
  String? bannerUrl,
  Map<String, String>? bannerHeaders,
}) {
  return showModalBottomSheet<VideoSource>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _StremioLinksSheet(
      manager: manager,
      ref: ref,
      title: title,
      inlineStreams: inlineStreams,
      bannerUrl: bannerUrl,
      bannerHeaders: bannerHeaders,
    ),
  );
}

class _StremioLinksSheet extends StatefulWidget {
  const _StremioLinksSheet({
    required this.manager,
    required this.ref,
    required this.title,
    required this.inlineStreams,
    this.bannerUrl,
    this.bannerHeaders,
  });

  final StremioManager manager;
  final StremioRef ref;
  final String title;
  final List<StremioStream> inlineStreams;

  /// Wide header art. Display-only; null keeps the plain text header.
  final String? bannerUrl;
  final Map<String, String>? bannerHeaders;

  @override
  State<_StremioLinksSheet> createState() => _StremioLinksSheetState();
}

class _StremioLinksSheetState extends State<_StremioLinksSheet> {
  StremioLinkSession? _session;
  StreamSubscription<StremioLinkGroup>? _subscription;
  List<StremioLinkGroup> _groups = const [];
  var _done = false;
  var _picked = false;
  var _dismissed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _subscription?.cancel();
    _session?.dispose();
    final session = widget.manager.openLinks(
      widget.ref,
      inlineStreams: widget.inlineStreams,
    );
    _session = session;
    _groups = session.currentGroups;
    _done = false;
    _subscription = session.groups.listen((group) {
      if (!mounted) return;
      setState(() {
        _groups = [
          for (final current in _groups)
            if (current.installation.id == group.installation.id)
              group
            else
              current,
        ];
      });
    });
    session.done.then((_) {
      if (mounted && identical(_session, session)) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _dismissed = true;
    _subscription?.cancel();
    _session?.dispose();
    super.dispose();
  }

  bool get _allowTorrent =>
      Platform.isAndroid && !(sl.isRegistered<AppMode>() && sl<AppMode>().isTv);

  void _choose(StremioLinkChoice choice) {
    if (_picked || _dismissed) return;
    if (_session?.isCurrent(choice) != true) {
      setState(_start);
      return;
    }
    if (stremioVideoSource(choice, allowTorrent: _allowTorrent) == null) {
      return;
    }
    final source = stremioVideoSource(
      choice,
      streamAddonName: widget.manager.byId(choice.installationId)?.name,
      allowTorrent: _allowTorrent,
    );
    if (source == null) {
      return;
    }
    widget.manager.rememberSubtitleStream(
      choice.ref,
      source.url,
      choice.stream,
    );
    _picked = true;
    Navigator.of(context).pop(source);
  }

  int _tab = 0;

  /// Playable choices of one group, in session order (TV hides torrents).
  List<StremioLinkChoice> _playable(StremioLinkGroup group) => [
    for (final choice in group.choices)
      if (choice.stream.kind == StremioStreamKind.direct ||
          (_allowTorrent && choice.stream.kind == StremioStreamKind.torrent))
        choice,
  ];

  @override
  Widget build(BuildContext context) {
    // Groups only ever resolve in place, so the tab index can't dangle —
    // clamp anyway so a removed addon can't point past the end.
    final tab = _tab.clamp(0, _groups.length);
    final visible = tab == 0
        ? _groups
        : [_groups[tab - 1]];
    // One flat row list for a single virtualized ListView: headers, cards,
    // placeholders and footers are all items, so a 300-link addon still only
    // builds what's on screen.
    final rows = <_SheetRow>[];
    final playable = [
      for (final group in visible)
        for (final choice in _playable(group)) choice,
    ];
    // Best match first.
    if (playable.isNotEmpty && tab == 0) {
      final first = playable.first;
      rows.add(
        _BestRow(
          choice: first,
          installationName: _groups
              .firstWhere((g) => g.installation.id == first.installationId)
              .installation
              .name,
        ),
      );
    }
    for (final group in visible) {
      rows.add(_HeaderRow(group: group, count: _playable(group).length));
      final choices = _playable(group);
      if (group.state == StremioLinkGroupState.pending && choices.isEmpty) {
        rows.add(const _PendingRow());
      }
      if ((group.state == StremioLinkGroupState.error ||
              group.state == StremioLinkGroupState.stale) &&
          choices.isEmpty) {
        rows.add(_ErrorRow(group: group));
      }
      for (final choice in choices) {
        rows.add(
          _CardRow(
            group: group,
            choice: choice,
            key: ValueKey('link:${choice.installationId}:${choice.label}'),
          ),
        );
      }
      if (choices.isEmpty &&
          group.state != StremioLinkGroupState.pending &&
          group.state != StremioLinkGroupState.error &&
          group.state != StremioLinkGroupState.stale) {
        rows.add(const _EmptyRow());
      }
    }
    if (_done && playable.isEmpty) {
      // An error row already carries its own retry; the footer button is
      // only for the silent-empty case.
      final hasErrorRow = visible.any(
        (group) =>
            (group.state == StremioLinkGroupState.error ||
                group.state == StremioLinkGroupState.stale) &&
            _playable(group).isEmpty,
      );
      rows.add(_DoneEmptyRow(showRetry: !hasErrorRow));
    }
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          children: [
            if (widget.bannerUrl == null || widget.bannerUrl!.isEmpty) ...[
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
            if (widget.bannerUrl != null &&
                widget.bannerUrl!.isNotEmpty)
              _BannerHeader(
                bannerUrl: widget.bannerUrl!,
                bannerHeaders: widget.bannerHeaders,
                title: widget.title,
                subtitle: _countsLine(playable.length, _groups.length),
                onClose: () {
                  _dismissed = true;
                  Navigator.of(context).pop();
                },
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: AppText.headline,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _countsLine(playable.length, _groups.length),
                            style: AppText.caption.copyWith(
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _dismissed = true;
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                children: [
                  _FilterChip(
                    label: 'All',
                    selected: tab == 0,
                    onTap: () => setState(() => _tab = 0),
                  ),
                  for (var i = 0; i < _groups.length; i++)
                    _FilterChip(
                      icon: StremioAddonIcon(
                        url: _groups[i].installation.logo,
                        size: 16,
                      ),
                      label: _groups[i].installation.name,
                      selected: tab == i + 1,
                      onTap: () => setState(() => _tab = i + 1),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  switch (row) {
                    case _BestRow(:final choice, :final installationName):
                      return _Entrance(
                        index: 0,
                        child: _BestCard(
                          choice: choice,
                          installationName: installationName,
                          onTap: () => _choose(choice),
                        ),
                      );
                    case _HeaderRow(:final group, :final count):
                      return _SectionHeader(group: group, count: count);
                    case _PendingRow():
                      return const Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [_SkeletonCard(), _SkeletonCard()],
                      );
                    case _ErrorRow(:final group):
                      return Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppColors.textTertiary.withValues(
                              alpha: 0.4,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                group.error ?? 'Failed',
                                style: AppText.body,
                              ),
                            ),
                            TextButton(
                              onPressed: _start,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    case _CardRow(:final group, :final choice):
                      return _Entrance(
                        // Identity on the wrapper: rebuilds never replay the
                        // entrance, late answers still fade in once.
                        key: ValueKey(
                          'link:${choice.installationId}:${choice.label}',
                        ),
                        index: index,
                        child: _LinkCard(
                          choice: choice,
                          installationName: group.installation.name,
                          title: widget.title,
                          onTap: () => _choose(choice),
                        ),
                      );
                    case _EmptyRow():
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('No links', style: AppText.caption),
                      );
                    case _DoneEmptyRow(:final showRetry):
                      return Column(
                        children: [
                          const SizedBox(height: 12),
                          Text(
                            'No playable links found',
                            style: AppText.caption,
                          ),
                          if (showRetry)
                            TextButton(
                              onPressed: _start,
                              child: const Text('Retry'),
                            ),
                        ],
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

/// One virtualized row of the links list (headers, cards, placeholders,
/// footers) so a 300-link addon only builds what's on screen.
sealed class _SheetRow {
  const _SheetRow({this.key});
  final Key? key;
}

class _BestRow extends _SheetRow {
  const _BestRow({required this.choice, required this.installationName});
  final StremioLinkChoice choice;
  final String installationName;
}

class _HeaderRow extends _SheetRow {
  const _HeaderRow({required this.group, required this.count});
  final StremioLinkGroup group;
  final int count;
}

class _PendingRow extends _SheetRow {
  const _PendingRow();
}

class _ErrorRow extends _SheetRow {
  const _ErrorRow({required this.group});
  final StremioLinkGroup group;
}

class _CardRow extends _SheetRow {
  const _CardRow({super.key, required this.group, required this.choice});
  final StremioLinkGroup group;
  final StremioLinkChoice choice;
}

class _EmptyRow extends _SheetRow {
  const _EmptyRow();
}

class _DoneEmptyRow extends _SheetRow {
  const _DoneEmptyRow({this.showRetry = true});
  final bool showRetry;
}

/// One-shot entrance: fade + slight rise, staggered by row index.
/// Stable keys keep rebuilds from replaying it; always settles.
class _Entrance extends StatelessWidget {
  const _Entrance({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = Duration(milliseconds: (index.clamp(0, 8)) * 30);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Interval(
        delay.inMilliseconds / 500,
        1,
        curve: Curves.easeOutCubic,
      ),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Human-readable size with GB support, e.g. "8.4 GB" / "512 MB" / "0 B".
/// Local to this sheet: the shared cache formatter caps at MB.
String _formatStreamSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// One filter pill: All or a single addon with its live link count.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final Widget? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? AppColors.accent : AppColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        key: ValueKey('filter-chip:$label'),
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSoft : AppColors.surface2,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppColors.accent : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (icon != null) ...[icon!, const SizedBox(width: 5)],
              Text(
                label,
                style: AppText.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
                softWrap: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The first playable choice, one tap to play — same pick path as its card.
class _BestCard extends StatelessWidget {
  const _BestCard({
    required this.choice,
    required this.installationName,
    required this.onTap,
  });

  final StremioLinkChoice choice;
  final String installationName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.4),
            ),
            color: AppColors.surface2,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'BEST MATCH',
                      style: AppText.caption.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      choice.label,
                      style: AppText.body.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _metaLine(choice, installationName),
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accent,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slim addon header; cards are sibling rows so long groups stay virtualized.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.group, required this.count});

  final StremioLinkGroup group;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
      child: Row(
        children: [
          StremioAddonIcon(url: group.installation.logo, size: 18),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              group.installation.name.toUpperCase(),
              style: AppText.caption.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.textTertiary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (group.state == StremioLinkGroupState.pending && count == 0)
            const SizedBox.shrink()
          else if (group.state == StremioLinkGroupState.error ||
              group.state == StremioLinkGroupState.stale)
            // With no choices the error row below carries the message;
            // repeating it here would double it.
            if (count > 0)
              Text(
                group.error ?? 'Failed',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              )
            else
              const SizedBox.shrink()
          else
            Text(
              '$count',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
        ],
      ),
    );
  }
}

/// Card-shaped loading skeleton: headline-width and meta-width bars echoing
/// a real link card's shape, with a shine sweep while it is visible.
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    final bar = AppColors.textTertiary.withValues(alpha: 0.22);
    Widget line(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: bar,
      ),
    );
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surface2,
      ),
      child: _Shine(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            line(150, 14),
            const SizedBox(height: 8),
            line(double.infinity, 11),
            const SizedBox(height: 6),
            line(200, 11),
            const SizedBox(height: 6),
            line(110, 11),
          ],
        ),
      ),
    );
  }
}

/// A shine band sweeping left to right across [child]. Runs a few sweeps
/// then parks: a looping ticker would never settle and would hang widget
/// tests on pumpAndSettle. Disposal (rows resolving) stops it sooner.
class _Shine extends StatefulWidget {
  const _Shine({required this.child});

  final Widget child;

  @override
  State<_Shine> createState() => _ShineState();
}

class _ShineState extends State<_Shine>
    with SingleTickerProviderStateMixin {
  static const _maxSweeps = 4;
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 1000),
    vsync: this,
  );
  var _sweeps = 0;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_onStatus);
    _controller.forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (++_sweeps >= _maxSweeps) {
      _controller.stop();
      return;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) {
          // A soft white band sliding across a window wider than the card
          // so it enters and exits cleanly.
          final slide =
              -rect.width + _controller.value * rect.width * 3;
          return LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.35),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(
            Rect.fromLTWH(slide, 0, rect.width, rect.height),
          );
        },
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// One stream as a card: addon headline, title, spec and size lines, plus
/// a SIZE pill when the addon sends a size. The whole card taps to play.
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.choice,
    required this.installationName,
    required this.title,
    required this.onTap,
  });

  final StremioLinkChoice choice;
  final String installationName;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final stream = choice.stream;
    final size = stream.videoSize;
    final subCount = stream.subtitles.length;
    final isTorrent = stream.kind == StremioStreamKind.torrent;
    // The addon's own headline; addon name as fallback.
    final headline = stream.name != null && stream.name!.isNotEmpty
        ? stream.name!
        : installationName;
    final metaBits = [
      if (size != null) _formatStreamSize(size),
      if (subCount > 0)
        '$subCount subtitle${subCount == 1 ? '' : 's'}'
      else if (size == null)
        'no size info',
      isTorrent ? 'torrent' : 'direct',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surface2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                headline,
                style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
              const SizedBox(height: 2),
              Text(
                '🍿 $title',
                style: AppText.body.copyWith(color: AppColors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '🎞️ ${choice.label}',
                style: AppText.body.copyWith(color: AppColors.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (stream.fileName != null &&
                  stream.fileName!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '📄 ${stream.fileName}',
                  style: AppText.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 2),
              Text(
                '💾 ${metaBits.join(' · ')}',
                style: AppText.body.copyWith(color: AppColors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (size != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      color: AppColors.surface,
                    ),
                    child: Text(
                      'SIZE ${_formatStreamSize(size)}',
                      style: AppText.caption.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _countsLine(int links, int addons) =>
    '$links link${links == 1 ? '' : 's'} · '
    '$addons addon${addons == 1 ? '' : 's'}';

/// Full-bleed header art melting into the background; title sits over
/// the fade, close floats top-right.
class _BannerHeader extends StatelessWidget {
  const _BannerHeader({
    required this.bannerUrl,
    required this.title,
    required this.subtitle,
    required this.onClose,
    this.bannerHeaders,
  });

  final String bannerUrl;
  final Map<String, String>? bannerHeaders;
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final surface = AppColors.surface;
    // Explicit top rounding: the banner bleeds to the sheet's top edge, so
    // it must carry the sheet's own corner radius itself.
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: SizedBox(
        height: 142,
        child: Stack(
          fit: StackFit.expand,
          children: [
          Image.network(
            bannerUrl,
            headers: bannerHeaders,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                ColoredBox(color: AppColors.surface2),
          ),
          // Legibility scrim up top, then a melt into the sheet background
          // along the bottom edge — no line where the image ends.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.45),
                  surface.withValues(alpha: 0.85),
                  surface,
                ],
                stops: const [0.0, 0.55, 0.85, 1.0],
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Tooltip(
              message: 'Close',
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onClose,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.45),
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppText.headline.copyWith(color: Colors.white),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: AppText.caption.copyWith(
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

String _metaLine(StremioLinkChoice choice, String installationName) {
  final size = choice.stream.videoSize;
  final subCount = choice.stream.subtitles.length;
  return [
    installationName,
    if (size != null) _formatStreamSize(size),
    if (subCount > 0) '$subCount subs',
  ].join(' · ');
}
