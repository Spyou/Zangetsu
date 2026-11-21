import 'dart:async';

import 'package:flutter/widgets.dart';

import '../di/injector.dart';
import '../metadata/title_logo_service.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import 'native_cover_provider.dart';

/// Resolves (and precaches) each anime item's TMDB banner independently —
/// AniList's own `bannerImage` is often missing or low-res. Shared by every
/// Home banner style (Carousel/Edge/Panels), which otherwise each ran this
/// same loop.
///
/// Skips items already in [cache] and non-anime items (every other provider's
/// own banner is already good). Calls [onResolved] per title as its banner
/// lands, so the caller can `setState` just that one entry.
void loadTmdbBanners(
  List<MediaItem> items,
  Map<String, String> cache, {
  required BuildContext context,
  required bool Function() mounted,
  required void Function(String id, String url) onResolved,
}) {
  if (!sl.isRegistered<TitleLogoService>()) return;
  final service = sl<TitleLogoService>();
  for (final item in items) {
    if (item.type != ProviderType.anime || cache.containsKey(item.id)) {
      continue;
    }
    unawaited(() async {
      try {
        final url = await service.bannerFor(item);
        if (!mounted() || !context.mounted || url == null) return;
        // Decode it before handing it back: callers crossfade on the frame
        // they're given, so a still-downloading image would crossfade to a
        // blank frame instead of the backdrop.
        try {
          await precacheImage(
            nativeCoverProvider(url, item.coverHeaders),
            context,
          );
        } catch (_) {}
        if (!mounted()) return;
        onResolved(item.id, url);
      } catch (_) {}
    }());
  }
}

/// AniList's own banner, upgraded to TMDB's backdrop/poster once [cache] has
/// resolved one for this item.
String? tmdbBannerFor(MediaItem item, Map<String, String> cache) =>
    item.type == ProviderType.anime
    ? (cache[item.id] ?? item.banner)
    : item.banner;
