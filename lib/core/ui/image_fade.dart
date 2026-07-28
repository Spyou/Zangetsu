import 'package:flutter/material.dart';

/// A [frameBuilder] for [Image] that fades the picture in as it decodes, so
/// image-provider images (Aniyomi/Cloudflare sources, the hero) match the smooth
/// fade-in `CachedNetworkImage` already gives elsewhere — instead of popping in.
///
/// Already-cached images (loaded synchronously) show instantly, so scrolling
/// back over seen covers never flickers.
Widget imageFadeIn(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSynchronouslyLoaded,
) {
  if (wasSynchronouslyLoaded) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
    child: child,
  );
}
