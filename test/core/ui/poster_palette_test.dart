import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/ui/poster_palette.dart';

/// 1x1 red pixel PNG, so palette extraction has real colour data to read.
final Uint8List _redPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlE'
    'QVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

/// 1x1 blue pixel PNG, a distinct image so the cache test can prove the
/// second call never even reaches the decoder. (Handcrafted: the base64
/// fixture first suggested for this failed to decode in this environment.)
final Uint8List _bluePng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC',
  ),
);

/// MemoryImage that counts how many times the decoder actually ran, so the
/// cache test can prove a second call never re-decodes the same URL.
// ignore: must_be_immutable — mutable decode counter is the point of this class.
class _CountingImage extends MemoryImage {
  _CountingImage(super.bytes);
  int loads = 0;

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    loads++;
    return super.loadImage(key, decode);
  }
}

class _HandleImage extends ImageProvider<_HandleImage> {
  const _HandleImage(this.image);
  final ui.Image image;

  @override
  Future<_HandleImage> obtainKey(ImageConfiguration configuration) async =>
      this;

  @override
  ImageStreamCompleter loadImage(
    _HandleImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    Future.value(ImageInfo(image: image.clone())),
  );
}

Future<Uint8List> _swatchImage(List<(Color, double)> swatches) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  var x = 0.0;
  for (final (color, width) in swatches) {
    canvas.drawRect(Rect.fromLTWH(x, 0, width, 10), Paint()..color = color);
    x += width;
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(x.toInt(), 10);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

Future<Uint8List> _seedImage(int seed) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  var state = seed;
  for (var i = 0; i < 32 * 32; i++) {
    final rgb = <int>[];
    for (var channel = 0; channel < 3; channel++) {
      state = (1103515245 * state + 12345) & 0x7fffffff;
      rgb.add((state >> 16) & 255);
    }
    canvas.drawRect(
      Rect.fromLTWH((i % 32).toDouble(), (i ~/ 32).toDouble(), 1, 1),
      Paint()..color = Color.fromARGB(255, rgb[0], rgb[1], rgb[2]),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 32);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('adaptive sample URL uses the reference TMDB sizes', () {
    expect(
      adaptiveSampleUrl(
        'https://image.tmdb.org/t/p/original/poster.jpg',
        backdrop: false,
      ),
      'https://image.tmdb.org/t/p/w500/poster.jpg',
    );
    expect(
      adaptiveSampleUrl(
        'https://image.tmdb.org/t/p/original/backdrop.jpg',
        backdrop: true,
      ),
      'https://image.tmdb.org/t/p/w1280/backdrop.jpg',
    );
    expect(
      adaptiveSampleUrl(
        'https://image.tmdb.org/t/p/w780/backdrop.jpg',
        backdrop: true,
      ),
      'https://image.tmdb.org/t/p/w1280/backdrop.jpg',
    );
    const other = 'https://cdn.example.test/art.jpg';
    expect(adaptiveSampleUrl(other, backdrop: true), other);
    expect(adaptiveSampleUrl(other, backdrop: false), other);
  });

  test('adaptive tint blends artwork into the current theme background', () {
    final previousBg = AppColors.bg;
    addTearDown(() => AppColors.bg = previousBg);
    AppColors.bg = AppColors.defaultBg;
    final tint = tintFromDominant(const Color(0xFFFF0000));
    expect(tint.r, closeTo((11 * 0.58 + 255 * 0.42) / 255, 0.001));
    expect(tint.g, closeTo(11 * 0.58 / 255, 0.001));
    expect(tint.b, closeTo(15 * 0.58 / 255, 0.001));

    AppColors.bg = Colors.black;
    final amoledTint = tintFromDominant(const Color(0xFFFF0000));
    expect(amoledTint.r, closeTo(0.42, 0.001));
    expect(amoledTint.g, 0);
    expect(amoledTint.b, 0);
  });

  test(
    'adaptive tint lifts dark colours while preserving hue and saturation',
    () {
      final previousBg = AppColors.bg;
      addTearDown(() => AppColors.bg = previousBg);
      AppColors.bg = Colors.black;
      final red = tintFromDominant(const Color(0xFF330000));
      expect(red.r, closeTo(0.9 * 0.42, 0.002));
      expect(red.g, 0);
      expect(red.b, 0);
      final blue = tintFromDominant(const Color(0xFF000033));
      expect(blue.r, 0);
      expect(blue.g, 0);
      expect(blue.b, closeTo(0.9 * 0.42, 0.002));
    },
  );

  test(
    'adaptive tint bounds pale colours but leaves neutral colours alone',
    () {
      final previousBg = AppColors.bg;
      addTearDown(() => AppColors.bg = previousBg);
      AppColors.bg = Colors.black;
      final paleRed = tintFromDominant(const Color(0xFFFFCCCC));
      expect(paleRed.r, closeTo(0.42, 0.002));
      expect(paleRed.g, closeTo(0.6 * 0.42, 0.002));
      expect(paleRed.b, closeTo(0.6 * 0.42, 0.002));
      final grey = tintFromDominant(const Color(0xFF333333));
      expect(grey.r, closeTo(0.2 * 0.42, 0.002));
      expect(grey.g, grey.r);
      expect(grey.b, grey.r);
      expect(tintFromDominant(Colors.black), Colors.black);
    },
  );

  test('detail can use a softer blend than the home default', () {
    final home = tintFromDominant(const Color(0xFFFF0000));
    final detail = tintFromDominant(const Color(0xFFFF0000), blend: 0.36);
    expect(detail.computeLuminance(), lessThan(home.computeLuminance()));
    expect(home.r, closeTo((11 * 0.58 + 255 * 0.42) / 255, 0.001));
  });

  test('adaptive tint retains artwork brightness instead of flattening it', () {
    final light = tintFromDominant(const Color(0xFFCCCCCC));
    final dark = tintFromDominant(const Color(0xFF333333));
    expect(light.computeLuminance(), greaterThan(dark.computeLuminance()));
  });

  test(
    'white foreground stays readable across bright adaptive backgrounds',
    () {
      for (final color in [
        Colors.white,
        Colors.red,
        Colors.green,
        Colors.blue,
        Colors.yellow,
        Colors.cyan,
        const Color(0xFFFF00FF),
        Colors.black,
      ]) {
        final tint = tintFromDominant(color);
        final contrast =
            (Colors.white.computeLuminance() + 0.05) /
            (tint.computeLuminance() + 0.05);
        expect(contrast, greaterThanOrEqualTo(4.5), reason: '$color');
      }
    },
  );

  testWidgets('adaptive palette prefers dominant colour over a vivid accent', (
    tester,
  ) async {
    final bytes = await tester.runAsync(
      () => _swatchImage([
        (const Color(0xFF805050), 80),
        (const Color(0xFFFF8000), 10),
        (Colors.black, 5),
        (Colors.white, 5),
      ]),
    );
    final provider = MemoryImage(bytes!);
    final vivid = await tester.runAsync(
      () => extractDominantColorFrom(provider, cacheKey: 'dominant-vs-accent'),
    );
    final dominant = await tester.runAsync(
      () => extractDominantColorFrom(
        provider,
        cacheKey: 'dominant-vs-accent',
        adaptive: true,
      ),
    );
    expect(vivid, isNotNull);
    expect(dominant, isNotNull);
    expect(HSLColor.fromColor(dominant!).saturation, lessThan(0.4));
    expect(HSLColor.fromColor(vivid!).saturation, greaterThan(0.7));
    expect(dominant.r, closeTo(128 / 255, 0.04));
    expect(dominant.g, closeTo(80 / 255, 0.04));
    expect(dominant.b, closeTo(80 / 255, 0.04));
  });

  testWidgets('adaptive palette filters near-black, white and grey swatches', (
    tester,
  ) async {
    final bytes = await tester.runAsync(
      () => _swatchImage([
        (Colors.black, 40),
        (Colors.white, 30),
        (const Color(0xFF888888), 20),
        (const Color(0xFF805050), 10),
      ]),
    );
    final color = await tester.runAsync(
      () => extractDominantColorFrom(
        MemoryImage(bytes!),
        cacheKey: 'adaptive-filter',
        adaptive: true,
      ),
    );
    expect(color, isNotNull);
    final hsl = HSLColor.fromColor(color!);
    expect(hsl.saturation, greaterThanOrEqualTo(0.08));
    expect(hsl.lightness, inInclusiveRange(0.22, 0.92));
    expect(color.r, greaterThan(color.g));
    expect(color.g, closeTo(color.b, 0.01));
  });

  testWidgets(
    'adaptive palette keeps the base palette filter before swatch selection',
    (tester) async {
      final bytes = await tester.runAsync(
        () => _swatchImage([
          (const Color(0xFFBF9F8F), 80),
          (const Color(0xFF805050), 15),
          (const Color(0xFFFF8000), 5),
        ]),
      );
      final color = await tester.runAsync(
        () => extractDominantColorFrom(
          MemoryImage(bytes!),
          cacheKey: 'base-filter-order',
          adaptive: true,
        ),
      );
      expect(color, isNotNull);
      expect(color!.r, closeTo(128 / 255, 0.04));
      expect(color.g, closeTo(80 / 255, 0.04));
      expect(color.b, closeTo(80 / 255, 0.04));
    },
  );

  testWidgets('adaptive quantizer matches fixed reference pixel fixtures', (
    tester,
  ) async {
    // Expected swatches were generated from identical pixels by Palette 4.0.0-beta02.
    const expected = {
      1: 0xFFB8C868,
      7: 0xFF30C0D8,
      42: 0xFF40B068,
      99: 0xFFB8C060,
      777: 0xFFC05848,
    };
    for (final entry in expected.entries) {
      final bytes = await tester.runAsync(() => _seedImage(entry.key));
      final actual = await tester.runAsync(
        () => extractDominantColorFrom(
          MemoryImage(bytes!),
          cacheKey: 'reference-pixels-${entry.key}',
          adaptive: true,
        ),
      );
      expect(actual?.toARGB32(), entry.value, reason: 'seed ${entry.key}');
    }
  });

  testWidgets(
    'adaptive extraction releases its image handles after cache eviction',
    (tester) async {
      final image = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(_redPng);
        final frame = await codec.getNextFrame();
        codec.dispose();
        return frame.image;
      });
      final provider = _HandleImage(image!);
      try {
        expect(image.debugGetOpenHandleStackTraces(), hasLength(1));
        final colour = await tester.runAsync(
          () => extractDominantColorFrom(
            provider,
            cacheKey: 'image-handle-cleanup',
            adaptive: true,
          ),
        );
        expect(colour, isNotNull);
        await tester.runAsync(() => provider.evict());
        tester.binding.scheduleFrame();
        await tester.pump();
        expect(image.debugGetOpenHandleStackTraces(), hasLength(1));
      } finally {
        await tester.runAsync(() => provider.evict());
        tester.binding.scheduleFrame();
        await tester.pump();
        image.dispose();
      }
    },
  );

  testWidgets('extractDominantColorFrom caches per key', (tester) async {
    final red = _CountingImage(_redPng);
    final blue = _CountingImage(_bluePng);
    // runAsync: palette extraction decodes via the real engine image pipeline,
    // which never delivers inside the test's fake-async zone.
    final a = await tester.runAsync(
      () => extractDominantColorFrom(red, cacheKey: 'red-blue'),
    );
    // Same cache key, DIFFERENT image: our cache must hand back red's colour
    // without ever decoding the blue artwork. Distinct providers also keep
    // the framework ImageCache out of the picture — it cannot serve red's
    // completer for blue's bytes, so `blue` never loading and `b == a` can
    // only be explained by our own cache.
    final b = await tester.runAsync(
      () => extractDominantColorFrom(blue, cacheKey: 'red-blue'),
    );
    expect(a, isNotNull);
    expect(b, a);
    expect(blue.loads, 0);
    expect(red.loads, 1);

    // Sanity-check the blue fixture really decodes blue (hue ~240) under its
    // own key, so "b == a" above means blue was genuinely ignored, not that
    // the fixture silently failed to decode.
    final blueCheck = await tester.runAsync(
      () => extractDominantColorFrom(blue, cacheKey: 'blue-fixture'),
    );
    expect(blueCheck, isNotNull);
    expect(HSLColor.fromColor(blueCheck!).hue, closeTo(240, 20));
  });

  for (final adaptive in [false, true]) {
    testWidgets(
      'extractDominantColorFrom retries a bad provider (adaptive=$adaptive)',
      (tester) async {
        final bad = _CountingImage(Uint8List.fromList([1, 2, 3]));
        // The expected decode failure is reported through FlutterError by the
        // image resource service; swallow just those, keep everything else.
        final previousOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.library != 'image resource service') {
            previousOnError?.call(details);
          }
        };
        final a = await tester.runAsync(
          () => extractDominantColorFrom(
            bad,
            cacheKey: 'bad-retry-$adaptive',
            adaptive: adaptive,
          ),
        );
        // Evict the framework ImageCache's entry for the failed completer, so the
        // second resolve genuinely re-attempts the decode instead of being served
        // the same failed completer (the framework never stores nulls either, so
        // only our cache could have prevented the retry).
        PaintingBinding.instance.imageCache.evict(bad);
        final b = await tester.runAsync(
          () => extractDominantColorFrom(
            bad,
            cacheKey: 'bad-retry-$adaptive',
            adaptive: adaptive,
          ),
        );
        FlutterError.onError = previousOnError;
        expect(a, isNull);
        expect(b, isNull);
        expect(bad.loads, 2);
      },
    );
  }

  testWidgets('PosterTintLayer paints theme bg when null, tint when set', (
    tester,
  ) async {
    final notifier = ValueNotifier<Color?>(null);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(children: [PosterTintLayer(notifier: notifier)]),
      ),
    );
    var box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    Color? layerColor() => (box.decoration as BoxDecoration?)?.color;
    expect(layerColor(), AppColors.bg);

    notifier.value = const Color(0xFF241A33);
    await tester.pumpAndSettle();
    box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    expect(layerColor(), const Color(0xFF241A33));

    notifier.dispose();
  });
}
