import 'package:zangetsu_source_bridge/stremio.dart';

import '../models/video_source.dart';
import '../playback/subtitle_language.dart';
import 'stremio_manager.dart';
import 'stremio_ref.dart';

/// Collects subtitle tracks from every enabled subtitle addon that accepts the
/// title. Bounded by [budget]; a slow or failing subtitle addon never blocks
/// playback, it just contributes no tracks.
Future<List<Subtitle>> stremioSubtitlesFor(
  StremioManager manager,
  StremioRef ref,
  StremioStream stream, {
  Duration budget = const Duration(seconds: 12),
}) async {
  final installations = [
    for (final installation in manager.enabled)
      if (installation.supports('subtitles') &&
          installation.accepts(ref.type, ref.itemId, resourceName: 'subtitles'))
        installation,
  ];
  final seen = <String>{};
  final results = <Subtitle>[];
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
          if (seen.add(subtitle.url)) {
            results.add(
              Subtitle(
                url: subtitle.url,
                lang: subtitle.lang,
                label: languageOfSource(subtitle.lang)?.name ?? subtitle.lang,
                format:
                    subtitle.format ??
                    (installation.manifestId == 'org.stremio.opensubtitlesv3'
                        ? 'srt'
                        : null),
                providerName: installation.name,
              ),
            );
          }
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

Future<VideoSource> stremioSourceWithSubtitles(
  StremioManager manager,
  StremioRef ref,
  VideoSource source,
) async {
  final extra = await stremioSubtitlesFor(
    manager,
    ref,
    manager.subtitleStream(ref, source.url),
  );
  final seen = <String>{};
  return source.withSubtitles([
    for (final track in [...source.subtitles, ...extra])
      if (seen.add(track.url)) track,
  ]);
}
