import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/episode_title.dart';

/// Immutable display data for the portrait watch page header: the episode
/// title (UI clamps to two lines), the series/season/episode line, and the
/// synopsis (null = hide the description section, never delay playback for).
class WatchPageHeader {
  const WatchPageHeader({
    required this.title,
    required this.subtitle,
    required this.description,
  });

  final String title;
  final String subtitle;
  final String? description;
}

/// Builds the header from the current episode plus the show context the route
/// already carries. Pure so title fallbacks are unit-testable.
///
/// Movies (no episode number) get no episode label — just the title.
/// [showDescription] is the detail snapshot: used only when the episode itself
/// carries no synopsis, and never fetched here (playback never waits for it).
WatchPageHeader resolveWatchPageHeader({
  required Episode episode,
  String? showTitle,
  String? showDescription,
}) {
  final n = episodeNumberInt(episode);
  final show = (showTitle ?? '').trim();
  final title =
      episodeDisplayTitle(episode, number: n) ??
      (n != null ? 'Episode $n' : (show.isNotEmpty ? show : 'Episode'));
  final String subtitle;
  if (n == null) {
    subtitle = show;
  } else {
    final label = episode.season != null
        ? 'S${episode.season} E$n'
        : 'E$n';
    subtitle = show.isEmpty ? label : '$show · $label';
  }
  final raw =
      (episode.description?.trim().isNotEmpty ?? false)
          ? episode.description!.trim()
          : (showDescription ?? '').trim();
  return WatchPageHeader(
    title: title,
    subtitle: subtitle,
    description: raw.isEmpty ? null : raw,
  );
}
/// `mm:ss`, or `h:mm:ss` past the hour. Time labels on the watch page.
String formatWatchTime(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// One row of the inline episode list. [index] is the real episode index —
/// identity survives any filtering or reordering upstream.
class WatchPageEpisode {
  const WatchPageEpisode({
    required this.index,
    required this.label,
    required this.current,
  });
  final int index;
  final String label;
  final bool current;
}

/// Display rows for the inline episode list, in player order.
List<WatchPageEpisode> watchPageEpisodes({
  required List<Episode> episodes,
  required int currentIndex,
}) {
  return [
    for (var i = 0; i < episodes.length; i++)
      WatchPageEpisode(
        index: i,
        label:
            episodeDisplayTitle(
              episodes[i],
              number: episodeNumberInt(episodes[i]),
            ) ??
            (episodeNumberInt(episodes[i]) != null
                ? 'Episode ${episodeNumberInt(episodes[i])}'
                : episodes[i].title),
        current: i == currentIndex,
      ),
  ];
}
