import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/episode_title.dart';
import '../detail/cubit/detail_cubit.dart' show seasonOf;

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
/// identity survives any filtering or reordering upstream. [numberLabel] is
/// the normal "EP 1" tag; [thumb] the episode art with the show cover behind.
class WatchPageEpisode {
  const WatchPageEpisode({
    required this.index,
    required this.heading,
    required this.label,
    required this.thumb,
    required this.current,
    this.number,
    this.unavailableReason,
    this.meta = '',
    this.synopsis = '',
  });
  final int index;

  /// Detail-screen heading: "1. The Fall", or "Episode 1" when nameless.
  final String heading;
  final String label;
  final String thumb;
  final bool current;

  /// The episode number for jump-to-episode. Null when the source gives none.
  final num? number;

  /// Why this row can never play (unreleased, …). Null = tappable.
  final String? unavailableReason;

  /// Runtime · air date, or the unavailable reason. Detail-screen wording.
  final String meta;

  /// Per-episode synopsis for the row's second line. Empty = hide it.
  final String synopsis;
}

/// Display rows for the inline episode list, in player order — the full list,
/// detail-screen style. The playing row is marked so it can glow and the
/// list can open on it.
List<WatchPageEpisode> watchPageEpisodes({
  required List<Episode> episodes,
  required int currentIndex,
  String? coverFallback,
  int? season,
}) {
  String artOf(Episode ep) {
    final t = (ep.thumbnail ?? '').trim();
    if (t.isNotEmpty) return t;
    return (coverFallback ?? '').trim();
  }

  String metaOf(Episode ep) {
    final reason = (ep.unavailable ?? '').trim();
    if (reason.isNotEmpty) return reason;
    return [
      if (ep.runtimeMinutes != null) '${ep.runtimeMinutes} min',
      if (ep.date != null && ep.date!.trim().isNotEmpty) ep.date!.trim(),
    ].join('  ·  ');
  }

  return [
    for (var i = 0; i < episodes.length; i++)
      if (season == null || (seasonOf(episodes[i]) ?? 1) == season)
        WatchPageEpisode(
        index: i,
        heading: _headingOf(episodes[i]),
        label:
            episodeDisplayTitle(
              episodes[i],
              number: episodeNumberInt(episodes[i]),
            ) ??
            (episodeNumberInt(episodes[i]) != null
                ? 'Episode ${episodeNumberInt(episodes[i])}'
                : episodes[i].title),
        thumb: artOf(episodes[i]),
        current: i == currentIndex,
        number: episodeNumberInt(episodes[i]),
        unavailableReason: episodes[i].unavailable,
        meta: metaOf(episodes[i]),
        synopsis: (episodes[i].description ?? '').trim(),
      ),
  ];
}

/// "1. The Fall" like the detail list; "Episode 1" when the source gave no
/// real name.
String _headingOf(Episode ep) {
  final n = episodeNumberInt(ep);
  final title =
      episodeDisplayTitle(ep, number: n) ?? (n != null ? 'Episode $n' : null);
  if (title == null || title.isEmpty) return ep.title;
  if (n == null) return title;
  if (title == 'Episode $n') return title;
  return '$n. $title';
}

/// The backdrop's mood colors: the frame's average pushed warm and lifted,
/// with a deeper twin for the wash's lower half (like the reference, which
/// glows bright up top and melts into black below). Pure and unit-testable;
/// decoding stays with the caller.
({Color top, Color bottom}) ambientGlowColor(ByteData bytes, int width, int height) {
  var r = 0, g = 0, b = 0, n = 0;
  if (width > 0 && height > 0 && bytes.lengthInBytes >= width * height * 4) {
    for (var i = 0; i < width * height; i++) {
      if (bytes.getUint8(i * 4 + 3) < 128) continue;
      r += bytes.getUint8(i * 4);
      g += bytes.getUint8(i * 4 + 1);
      b += bytes.getUint8(i * 4 + 2);
      n++;
    }
  }
  if (n == 0) {
    const black = Color(0xFF000000);
    return (top: black, bottom: black);
  }
  final l = (r + g + b) ~/ (3 * n);
  int boost(int v) => (l + (v ~/ n - l) * 1.5).round() + 22;
  final tr = boost(r).clamp(0, 255);
  final tg = boost(g).clamp(0, 255);
  final tb = boost(b).clamp(0, 255);
  return (
    top: Color.fromARGB(255, tr, tg, tb),
    bottom: Color.fromARGB(255, (tr * 0.55).round(), (tg * 0.55).round(), (tb * 0.55).round()),
  );
}
