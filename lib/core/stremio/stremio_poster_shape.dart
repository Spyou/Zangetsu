import '../models/media_item.dart';

/// Only Stremio catalogue cards opt into addon-defined artwork geometry.
double? stremioPosterAspect(MediaItem item, {bool landscape = false}) {
  if (item.sourceId != 'stremio') return null;
  if (landscape) return 16 / 9;
  return switch (item.posterShape?.trim().toLowerCase()) {
    'landscape' => 16 / 9,
    'square' => 1,
    'poster' => 2 / 3,
    _ => null,
  };
}

/// Use artwork already supplied by the addon; no metadata lookup is needed.
String? stremioPosterImage(
  MediaItem item, {
  required bool landscape,
  Set<String> failedUrls = const {},
}) {
  final candidates = landscape
      ? [item.landscapePoster, item.banner, item.cover]
      : [item.cover];
  for (final url in candidates) {
    if (url != null && url.trim().isNotEmpty && !failedUrls.contains(url)) {
      return url;
    }
  }
  return null;
}
