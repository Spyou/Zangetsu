import 'package:flutter/material.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../l10n/l10n.dart';
import '../detail/cubit/detail_cubit.dart' show seasonOf;

String _sourceName(AppLocalizations l10n, VideoSource s, int index) {
  final l = s.label?.trim();
  if (l != null && l.isNotEmpty) return l;
  final q = s.quality?.trim();
  if (q != null && q.isNotEmpty) return q;
  final host = (Uri.tryParse(s.url)?.host ?? '').replaceFirst('www.', '');
  return host.isNotEmpty
      ? l10n.serverWithHost(index + 1, host)
      : l10n.serverNumber(index + 1);
}

Future<String> resolveEpisodeDownloadShowId({
  required String sourceId,
  required String showUrl,
  String? knownId,
  required Iterable<DownloadRecord> downloads,
  required Future<String> Function() loadShowId,
}) async {
  if (knownId != null && knownId.isNotEmpty) return knownId;
  for (final record in downloads) {
    if (record.sourceId == sourceId && record.showUrl == showUrl) {
      return record.showId;
    }
  }
  final id = await loadShowId();
  if (id.isEmpty) throw StateError('Missing download title ID');
  return id;
}

Episode? matchDownloadEpisode(Episode original, List<Episode> episodes) {
  final matches = episodes
      .where(
        (candidate) =>
            (seasonOf(candidate) ?? 1) == (seasonOf(original) ?? 1) &&
            (original.number != null
                ? candidate.number == original.number
                : candidate.url == original.url ||
                      (original.title.trim().isNotEmpty &&
                          candidate.title.trim() == original.title.trim())),
      )
      .toList();
  return matches.length == 1 ? matches.single : null;
}

typedef SingleEpisodeDownloadChoice = ({
  VideoSource chosen,
  List<VideoSource> all,
  Episode episode,
  String category,
});

class EpisodeDownloadSourceSheet extends StatefulWidget {
  const EpisodeDownloadSourceSheet({
    super.key,
    required this.title,
    required this.category,
    required this.resolve,
    required this.episode,
    required this.availableCategories,
    required this.resolveEpisodes,
  });

  final String title;
  final String category;
  final Episode episode;
  final List<String> availableCategories;
  final Future<Map<int, List<Episode>>> Function(String) resolveEpisodes;
  final Future<List<VideoSource>> Function(Episode) resolve;

  @override
  State<EpisodeDownloadSourceSheet> createState() =>
      _EpisodeDownloadSourceSheetState();
}

class _EpisodeDownloadSourceSheetState
    extends State<EpisodeDownloadSourceSheet> {
  List<VideoSource>? _sources;
  bool _loading = true;
  bool _loadFailed = false;
  late String _category;
  Episode? _episode;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _category = widget.category;
    _load(_category);
  }

  Future<void> _load(String category) async {
    final request = ++_request;
    setState(() {
      _category = category;
      _episode = null;
      _sources = null;
      _loading = true;
      _loadFailed = false;
    });
    try {
      Episode? episode = widget.episode;
      if (category != widget.category) {
        final seasons = await widget.resolveEpisodes(category);
        if (!mounted || request != _request) return;
        final original = widget.episode;
        final pool = seasons[seasonOf(original) ?? 1] ?? <Episode>[];
        episode = matchDownloadEpisode(original, pool);
      }
      if (episode == null) return;
      final sources = await widget.resolve(episode);
      if (!mounted || request != _request) return;
      setState(() {
        _episode = episode;
        _sources = DownloadManager.sourcesForDownloadCategory(
          sources,
          category,
        );
      });
    } catch (_) {
      if (mounted && request == _request) setState(() => _loadFailed = true);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  bool _isHls(VideoSource s) =>
      s.container == SourceContainer.hls ||
      (Uri.tryParse(s.url)?.path ?? s.url).toLowerCase().endsWith('.m3u8');

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.6;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Text(
                context.l10n.downloadChooseServer,
                style: AppText.title,
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Text(
                widget.title,
                style: AppText.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            if (widget.availableCategories.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final category in widget.availableCategories)
                      ChoiceChip(
                        label: Text(
                          category == 'dub'
                              ? context.l10n.dub
                              : context.l10n.sub,
                        ),
                        selected: _category == category,
                        onSelected: (_) {
                          if (_category != category) _load(category);
                        },
                      ),
                  ],
                ),
              ),
            if (_loading)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              )
            else if (_loadFailed || (_sources?.isEmpty ?? true))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  _loadFailed
                      ? context.l10n.couldntLoadDownloadOptions
                      : context.l10n.noDownloadSourcesFound,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _sources!.length,
                  itemBuilder: (context, i) => _row(_sources![i], i),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(VideoSource s, int i) {
    final hls = _isHls(s);
    final label = _sourceName(context.l10n, s, i);
    final sub = [
      if (s.quality != null && s.quality!.trim().isNotEmpty) s.quality!.trim(),
      hls ? context.l10n.hls : context.l10n.direct,
    ].join(' · ');
    void onTap() {
      if (_loading || _episode == null) return;
      Navigator.pop(context, (
        chosen: s,
        all: _sources ?? <VideoSource>[s],
        episode: _episode!,
        category: _category,
      ));
    }

    if (sl<AppMode>().isTv) {
      return TvListFocusable(
        autofocus: i == 0,
        onTap: onTap,
        semanticLabel: '$label, $sub',
        // This ListTile is only built on this TV branch — exclude its own
        // title/subtitle so TalkBack doesn't hear them twice.
        child: ExcludeSemantics(
          child: ListTile(
            contentPadding: const EdgeInsetsDirectional.only(end: 8),
            leading: Icon(Icons.download_rounded, color: AppColors.accent),
            title: Text(
              label,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(sub, style: AppText.caption),
          ),
        ),
      );
    }
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(end: 8),
      leading: Icon(Icons.download_rounded, color: AppColors.accent),
      title: Text(
        label,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(sub, style: AppText.caption),
      onTap: onTap,
    );
  }
}
