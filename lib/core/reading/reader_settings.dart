// Pure manga-reader logic that doesn't belong on the widget — mirrors how
// subtitle_style.dart splits logic out of the player sheet.

/// Pixel width to decode a manga page at. We decode at the display width times
/// a headroom factor so a pinch-zoom still looks crisp, but never below the
/// display width and never past 4096 (GPU texture ceiling + memory sanity for
/// very tall webtoon strips). Every other image in the app already downsamples;
/// the reader was the one screen decoding pages at full intrinsic resolution.
int readerDecodeWidth(int deviceWidthPx, {double zoomHeadroom = 2.0}) {
  final scaled = (deviceWidthPx * zoomHeadroom).round();
  return scaled.clamp(deviceWidthPx, 4096);
}
