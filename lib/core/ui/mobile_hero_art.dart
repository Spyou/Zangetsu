import 'package:flutter/painting.dart';

/// Portrait TMDB artwork suits a tall phone hero; keep other catalogues' art.
String? mobileHeroArt(String? cover, String? banner, {String? sourceId}) {
  if (sourceId == 'stremio') {
    if (banner?.trim().isNotEmpty == true) return banner;
    return cover?.trim().isNotEmpty == true ? cover : null;
  }
  if (cover != null && cover.startsWith('https://image.tmdb.org/t/p/')) {
    return cover.replaceFirst(RegExp(r'/t/p/[^/]+/'), '/t/p/original/');
  }
  return banner ?? cover;
}

/// Detail backgrounds sample the poster first, falling back to the backdrop.
String? adaptiveArtUrl(String? poster, String? backdrop) {
  if (poster != null && poster.trim().isNotEmpty) return poster;
  return backdrop != null && backdrop.trim().isNotEmpty ? backdrop : null;
}

/// Wide Stremio backdrops need their detail preserved before a tall hero crops them.
int mobileHeroDecodeWidth(String sourceId, int screenWidth) =>
    sourceId == 'stremio' && screenWidth < 1920 ? 1920 : screenWidth;

/// The hero's artwork, on Home and in Detail: the plain wide backdrop when there
/// is one, so the title is not printed into the picture (the logo or name is
/// drawn on top), and the poster only when there is no backdrop.
///
/// A TMDB backdrop comes as w780 in the catalogues, far too small for a tall
/// card, so it is asked for at full size, as the poster fallback already is.
String? homeHeroArt(String? cover, String? banner) {
  if (banner == null || banner.trim().isEmpty) {
    return mobileHeroArt(cover, null);
  }
  return banner.startsWith('https://image.tmdb.org/t/p/')
      ? banner.replaceFirst(RegExp(r'/t/p/[^/]+/'), '/t/p/original/')
      : banner;
}

/// The widest a hero picture is decoded. A wide backdrop needs about 2400 px to
/// fill a tall card without being stretched, so it is decoded at that size on
/// every phone rather than at a smaller size and then enlarged.
const int heroDecodeMaxWidth = 2400;

/// Hero art decoded to fit a tall card: a wide backdrop keeps enough pixels to
/// fill the card, a tall poster is not blown up to the same width. The fit is
/// bounded in both directions, so neither can cost more than about 13 MB.
ImageProvider heroImage(
  ImageProvider provider, {
  required int screenWidth,
  required int cardHeight,
}) => ResizeImage(
  provider,
  width: screenWidth < heroDecodeMaxWidth ? heroDecodeMaxWidth : screenWidth,
  height: cardHeight,
  policy: ResizeImagePolicy.fit,
);

/// The card's height in pixels, with a little room to crop into.
int heroCardDecodeHeight(double screenHeightDp, double pixelRatio) =>
    ((screenHeightDp * 0.62).clamp(380.0, 560.0) * pixelRatio * 1.15).round();
