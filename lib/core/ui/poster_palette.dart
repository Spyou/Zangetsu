import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:palette_generator/palette_generator.dart';

import '../theme/app_colors.dart';
import 'native_cover_provider.dart';
import 'adaptive_palette.dart';

/// Dominant colours already extracted, keyed by cover URL, so swiping back
/// through a carousel never re-decodes the same artwork.
final Map<(String, bool), Color> _dominantCache = {};

const adaptiveColourBlend = 0.36;
const adaptiveColourDuration = Duration(milliseconds: 600);
const detailAdaptiveColourDuration = Duration(milliseconds: 320);
const adaptiveColourCurve = Cubic(0, 0, 0.2, 1);
bool _licenseRegistered = false;

/// The dominant colour of [provider]'s artwork, cached under [cacheKey], or
/// null when it can't be read. Callers use small thumbnails: 96px for the
/// adaptive wash and 180px for decorative gradients.
Future<Color?> extractDominantColorFrom(
  ImageProvider provider, {
  required String cacheKey,
  bool adaptive = false,
}) async {
  final key = (cacheKey, adaptive);
  final cached = _dominantCache[key];
  if (cached != null) return cached;
  try {
    Color? c;
    if (adaptive) {
      final image = await _loadPaletteImage(provider);
      try {
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (bytes != null) {
          c = adaptiveDominantColor(bytes.buffer.asUint8List());
        }
      } finally {
        image.dispose();
      }
    } else {
      final pal = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(180, 270),
        maximumColorCount: 8,
      );
      c =
          pal.vibrantColor?.color ??
          pal.dominantColor?.color ??
          pal.darkVibrantColor?.color ??
          pal.mutedColor?.color;
    }
    if (c != null) _dominantCache[key] = c;
    return c;
  } catch (_) {
    return null;
  }
}

Future<ui.Image> _loadPaletteImage(ImageProvider provider) async {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      try {
        if (!completer.isCompleted) completer.complete(info.image.clone());
      } finally {
        info.dispose();
      }
    },
    onError: (Object error, StackTrace? stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  try {
    return await completer.future.timeout(const Duration(seconds: 15));
  } finally {
    stream.removeListener(listener);
  }
}

/// Background colours use the most common balanced swatch, not a vivid accent.
Future<Color?> extractAdaptiveColor(String url, Map<String, String>? headers) {
  if (!_licenseRegistered) {
    _licenseRegistered = true;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks([
        'Adaptive Palette',
      ], await rootBundle.loadString('assets/licenses/adaptive_palette.txt'));
    });
  }
  return extractDominantColorFrom(
    ResizeImage(
      nativeCoverProvider(url, headers),
      width: 96,
      height: 96,
      policy: ResizeImagePolicy.fit,
    ),
    cacheKey: url,
    adaptive: true,
  );
}

/// Palette sampling uses the same TMDB size the reference displays: w500
/// posters and w1280 backdrops. The screen still shows the original artwork;
/// only the palette copy is resized, so compression cannot flip the swatch.
String adaptiveSampleUrl(String url, {required bool backdrop}) {
  final trimmed = url.trim();
  if (!trimmed.contains('image.tmdb.org/t/p/')) return trimmed;
  final size = backdrop ? 'w1280' : 'w500';
  return trimmed.replaceFirst(
    RegExp(r'image\.tmdb\.org/t/p/[^/]+/'),
    'image.tmdb.org/t/p/$size/',
  );
}

/// The dominant colour of [url]'s artwork (covers routed through the native
/// provider so Cloudflare-walled sources work too), or null when unread.
Future<Color?> extractDominantColor(String url, Map<String, String>? headers) =>
    extractDominantColorFrom(
      ResizeImage(nativeCoverProvider(url, headers), width: 180),
      cacheKey: url,
    );

/// Lift dark chromatic tints before blending; neutral colours stay neutral.
Color tintFromDominant(Color dominant, {double blend = 0.42}) {
  final hsl = HSLColor.fromColor(dominant);
  final colour = hsl.saturation == 0
      ? dominant
      : hsl.withLightness(hsl.lightness.clamp(0.45, 0.8)).toColor();
  return Color.lerp(AppColors.bg, colour, blend)!;
}

/// Full-bleed animated colour wash for a screen's background. Sits as the
/// bottom child of the screen's body Stack; [notifier] carries the current
/// poster tint (null → the normal theme background) and colour changes morph
/// with the screen's background transition.
class PosterTintLayer extends StatelessWidget {
  const PosterTintLayer({
    super.key,
    required this.notifier,
    this.duration = adaptiveColourDuration,
  });

  final ValueNotifier<Color?> notifier;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: ValueListenableBuilder<Color?>(
            valueListenable: notifier,
            builder: (context, tint, _) => AnimatedContainer(
              duration: duration,
              curve: adaptiveColourCurve,
              color: tint ?? AppColors.bg,
            ),
          ),
        ),
      ),
    );
  }
}
