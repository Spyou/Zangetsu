import 'dart:async';

import '../di/injector.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../privacy/incognito_mode.dart';
import '../zmode/zmode_ids.dart';
import 'list_status_store.dart';
import 'my_list.dart';
import 'playback_prefs.dart';
import 'skip_service.dart';

/// TV playback helpers: speed/scrobble/skip decisions plus play-session
/// identity and auto-add. [shouldScrobble] mirrors PlayerCubit._maybeScrobble;
/// session tracking lives in [TvPlaybackTracker].

/// User-selectable playback rates (UI order).
const List<double> kTvSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// LoudnessEnhancer target gain in millibels for a volume-boost percentage.
/// 100% -> 0 dB, 200% -> +6 dB (~double amplitude, matching mpv volume=2.0).
int volumeBoostToMillibels(int percent) =>
    (((percent.clamp(100, 200) - 100) / 100) * 600).round();

/// Whether to push episode progress now: at/after 92% watched, once.
/// Mirrors PlayerCubit._maybeScrobble; used by [TvPlaybackTracker].
bool shouldScrobble({
  required int positionMs,
  required int durationMs,
  required bool alreadyScrobbled,
}) => !alreadyScrobbled && durationMs > 0 && positionMs >= durationMs * 0.92;

/// The OP/ED interval whose [start, end) contains [positionMs], else null.
SkipInterval? activeSkipInterval(List<SkipInterval> intervals, int positionMs) {
  for (final i in intervals) {
    if (positionMs >= i.start.inMilliseconds &&
        positionMs < i.end.inMilliseconds) {
      return i;
    }
  }
  return null;
}

/// Same guards as the phone detail play path: auto-add on, not incognito,
/// not already listed. Status is written first so the cloud upsert carries
/// Watching instead of a null.
bool shouldAutoAddToMyList({
  required bool autoAddEnabled,
  required bool incognito,
  required bool alreadyListed,
}) => autoAddEnabled && !incognito && !alreadyListed;

/// Fire-and-forget auto-add used by [launchTvPlayback]. No-op when DI isn't
/// wired (widget tests) or the user opted out / is already listed.
void maybeAutoAddToMyList(MediaItem item) {
  if (!sl.isRegistered<PlaybackPrefs>() ||
      !sl.isRegistered<MyListStore>() ||
      !sl.isRegistered<ListStatusStore>()) {
    return;
  }
  final list = sl<MyListStore>();
  if (!shouldAutoAddToMyList(
    autoAddEnabled: sl<PlaybackPrefs>().autoAddToMyList,
    incognito: IncognitoMode.on,
    alreadyListed: list.contains(item),
  )) {
    return;
  }
  final status = sl<ListStatusStore>();
  unawaited(() async {
    await status.setStatus(item, WatchStatus.watching);
    await list.add(item);
  }());
}

/// Identity for a TV play session when the caller didn't hand us a
/// [MediaItem]. Z-mode urls use the catalogue id (`mal:123`) so the row
/// matches a title saved from Detail.
MediaItem? mediaItemForPlayback({
  required String sourceId,
  String? showUrl,
  String? showTitle,
  String? cover,
  Map<String, String>? coverHeaders,
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
  ProviderType? type,
}) {
  final url = showUrl ?? '';
  final title = showTitle?.trim() ?? '';
  if (url.isEmpty && title.isEmpty) return null;
  final z = url.isEmpty ? null : ZmodeIds.parseShow(url);
  return MediaItem(
    id: z?.id ?? (url.isNotEmpty ? url : sourceId),
    title: title.isNotEmpty ? title : url,
    url: url.isNotEmpty ? url : sourceId,
    sourceId: sourceId,
    type: type ?? _typeForZ(z?.kind) ?? ProviderType.anime,
    cover: cover,
    coverHeaders: coverHeaders,
    malId: malId,
    tmdbId: tmdbId,
    tmdbIsTv: tmdbIsTv,
    imdbId: imdbId,
  );
}

ProviderType? _typeForZ(ZKind? kind) => switch (kind) {
  ZKind.anime => ProviderType.anime,
  ZKind.movie || ZKind.tv => ProviderType.movie,
  ZKind.manga => ProviderType.manga,
  ZKind.novel => ProviderType.novel,
  null => null,
};
