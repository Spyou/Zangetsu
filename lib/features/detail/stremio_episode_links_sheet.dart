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
    ),
  );
}

class _StremioLinksSheet extends StatefulWidget {
  const _StremioLinksSheet({
    required this.manager,
    required this.ref,
    required this.title,
    required this.inlineStreams,
  });

  final StremioManager manager;
  final StremioRef ref;
  final String title;
  final List<StremioStream> inlineStreams;

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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _groups.length + 1,
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: AppText.headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  const Tab(text: 'All'),
                  for (final group in _groups)
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StremioAddonIcon(
                            url: group.installation.logo,
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                          Text(group.installation.name),
                        ],
                      ),
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _linksList(_groups),
                    for (final group in _groups) _linksList([group]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _linksList(List<StremioLinkGroup> groups) {
    final rows = <(StremioLinkGroup, StremioLinkChoice?)>[
      for (final group in groups) ...[
        (group, null),
        for (final choice in group.choices)
          if (choice.stream.kind == StremioStreamKind.direct ||
              (_allowTorrent &&
                  choice.stream.kind == StremioStreamKind.torrent))
            (group, choice),
      ],
    ];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      itemCount: rows.length + (_done ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == rows.length) {
          final hasLinks = rows.any((row) => row.$2 != null);
          if (hasLinks) return const SizedBox.shrink();
          return Column(
            children: [
              Text('No playable links found', style: AppText.caption),
              TextButton(onPressed: _start, child: const Text('Retry')),
            ],
          );
        }
        final (group, choice) = rows[index];
        if (choice == null) return _group(group);
        return ListTile(
          dense: true,
          enabled: !_picked,
          title: Text(
            choice.label,
            style: AppText.body,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: choice.stream.fileName == null
              ? null
              : Text(
                  choice.stream.fileName!,
                  style: AppText.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: const Icon(Icons.play_arrow_rounded, size: 20),
          onTap: () => _choose(choice),
        );
      },
    );
  }

  Widget _group(StremioLinkGroup group) {
    final hasChoices = group.choices.any(
      (choice) =>
          choice.stream.kind == StremioStreamKind.direct ||
          (_allowTorrent && choice.stream.kind == StremioStreamKind.torrent),
    );
    return Card(
      color: AppColors.surface2,
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    group.installation.name,
                    style: AppText.headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (group.state == StremioLinkGroupState.pending)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (group.state == StremioLinkGroupState.error)
                  Text(group.error ?? 'Failed', style: AppText.caption)
                else if (group.state == StremioLinkGroupState.stale)
                  Text(group.error ?? 'Addon changed', style: AppText.caption)
                else if (!hasChoices)
                  Text('No links', style: AppText.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
