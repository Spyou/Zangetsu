import 'package:zangetsu_source_bridge/stremio.dart';

import 'stremio_manager.dart';
import 'stremio_ref.dart';

/// Collects subtitle tracks from every enabled subtitle addon that accepts the
/// title. Bounded by [budget]; a slow or failing subtitle addon never blocks
/// playback, it just contributes no tracks.
Future<List<StremioSubtitle>> stremioSubtitlesFor(
  StremioManager manager,
  StremioRef ref,
  StremioStream stream, {
  Duration budget = const Duration(seconds: 2),
}) async {
  final installations = [
    for (final installation in manager.enabled)
      if (installation.supports('subtitles') &&
          installation.accepts(ref.type, ref.itemId, resourceName: 'subtitles'))
        installation,
  ];
  final seen = <String>{};
  final results = <StremioSubtitle>[];
  var expired = false;

  Future<void> collect() async {
    for (final installation in installations) {
      if (expired) break;
      try {
        final subtitles = await manager.subtitles(
          installation.id,
          type: ref.type,
          itemId: ref.requestId,
          filename: stream.fileName,
          videoHash: stream.videoHash,
          videoSize: stream.videoSize,
        );
        if (expired) return;
        for (final subtitle in subtitles) {
          if (seen.add(subtitle.url)) results.add(subtitle);
        }
      } catch (_) {
        // One broken subtitle addon must not cost the playable track.
      }
    }
  }

  try {
    await collect().timeout(
      budget,
      onTimeout: () {
        expired = true;
      },
    );
  } catch (_) {
    // Budget spent: keep whatever arrived before the deadline.
  }
  return List.unmodifiable(results);
}
