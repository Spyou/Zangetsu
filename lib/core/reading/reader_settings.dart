// Pure manga-reader logic that doesn't belong on the widget — mirrors how
// subtitle_style.dart splits logic out of the player sheet.

import 'package:flutter/painting.dart';

import '../theme/app_colors.dart';

/// Pixel width to decode a manga page at. We decode at the display width times
/// a headroom factor so a pinch-zoom still looks crisp, but never below the
/// display width and never past 4096 (GPU texture ceiling + memory sanity for
/// very tall webtoon strips). Every other image in the app already downsamples;
/// the reader was the one screen decoding pages at full intrinsic resolution.
int readerDecodeWidth(int deviceWidthPx, {double zoomHeadroom = 2.0}) {
  final scaled = (deviceWidthPx * zoomHeadroom).round();
  return scaled.clamp(deviceWidthPx, 4096);
}

/// How a manga page image scales within its viewport. Mirrors
/// `ReaderPrefs.fitMode`'s string keys 1:1.
enum FitMode { contain, width, height, original, smart }

/// Maps a [FitMode] to the `BoxFit` that renders it. `smart` needs the page's
/// and screen's aspect ratios to decide: a page taller (relatively narrower)
/// than the screen reads better fit-to-width (so its full height scrolls into
/// view), otherwise fit-to-height.
BoxFit fitToBoxFit(
  FitMode mode, {
  required double pageAspect,
  required double screenAspect,
}) => switch (mode) {
  FitMode.contain => BoxFit.contain,
  FitMode.width => BoxFit.fitWidth,
  FitMode.height => BoxFit.fitHeight,
  FitMode.original => BoxFit.none,
  FitMode.smart =>
    pageAspect < screenAspect ? BoxFit.fitWidth : BoxFit.fitHeight,
};

/// Reader background colour for `ReaderPrefs.mangaBackground`'s keys:
/// 'black' | 'white' | 'gray' | 'system' (falls back to the app background).
Color readerBgColor(String key) => switch (key) {
  'black' => const Color(0xFF000000),
  'white' => const Color(0xFFFFFFFF),
  'gray' => const Color(0xFF121212),
  _ => AppColors.bg,
};

/// Reading colour filter for `ReaderPrefs.colorFilter`'s keys: 'grayscale' |
/// 'invert' | 'sepia'. 'none' (or anything unrecognized) returns null —
/// callers must skip wrapping the page in `ColorFiltered` entirely when this
/// is null, rather than pass an identity matrix, so the default reading path
/// renders exactly as it did before this feature existed.
ColorFilter? readerColorFilter(String key) => switch (key) {
  // Standard luminance weights (W3C Filter Effects grayscale-equivalent),
  // applied identically to every output channel.
  'grayscale' => const ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0, //
  ]),
  // Negates each channel and offsets by the matrix's 0..255 translation
  // column so the result lands back in range.
  'invert' => const ColorFilter.matrix(<double>[
    -1, 0, 0, 0, 255, //
    0, -1, 0, 0, 255, //
    0, 0, -1, 0, 255, //
    0, 0, 0, 1, 0, //
  ]),
  // Standard sepia coefficients (W3C Filter Effects sepia-equivalent).
  'sepia' => const ColorFilter.matrix(<double>[
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0, //
    0.272, 0.534, 0.131, 0, 0, //
    0, 0, 0, 1, 0, //
  ]),
  _ => null,
};

/// Groups page indices into the spreads shown by the landscape double-page
/// reader. Walks left-to-right, pairing each page with the next one; a page
/// listed in [wide] (a full-spread scan that already spans two pages) stands
/// alone, and so does any page that can't find a partner (the one after a wide
/// page, or an odd final page). [rtl] reverses the two indices within a pair,
/// so a right-to-left spread shows the higher-numbered page on the left.
///
/// Pure so the pairing contract is unit-testable without pumping the reader,
/// and so the widget can map page↔spread the same way in both directions.
List<List<int>> pairPages(
  int count, {
  required bool rtl,
  Set<int> wide = const {},
}) {
  final spreads = <List<int>>[];
  var i = 0;
  while (i < count) {
    if (wide.contains(i) || i + 1 >= count || wide.contains(i + 1)) {
      spreads.add([i]);
      i += 1;
    } else {
      spreads.add(rtl ? [i + 1, i] : [i, i + 1]);
      i += 2;
    }
  }
  return spreads;
}
