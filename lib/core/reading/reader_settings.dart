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
