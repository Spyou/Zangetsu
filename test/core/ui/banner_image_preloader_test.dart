import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/metadata/title_logo_service.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/ui/banner_image_preloader.dart';

class _Logos extends TitleLogoService {
  _Logos() : super(Dio());
  final requested = <String>[];
  Completer<String?>? pending;

  @override
  Future<String?> logoFor(MediaItem item) {
    requested.add(item.id);
    return pending?.future ??
        Future.value('https://example.test/${item.id}.png');
  }
}

void main() {
  tearDown(() => sl.reset());

  for (final source in ['stremio', 'tmdb', 'mihon:one']) {
    testWidgets('warms only neighbours and logos for $source', (tester) async {
      final logos = _Logos();
      sl.registerSingleton<TitleLogoService>(logos);
      final loaded = <ImageProvider>[];
      final images = List.generate(
        4,
        (i) => MemoryImage(Uint8List.fromList([i])),
      );
      final items = List.generate(
        4,
        (i) => MediaItem(
          id: '$i',
          title: 'Title $i',
          url: '/$i',
          type: ProviderType.anime,
          sourceId: source,
        ),
      );
      final preloader = BannerImagePreloader(
        loadImage: (image, context) async {
          loaded.add(image);
        },
      );
      Widget page() => MaterialApp(
        home: Builder(
          builder: (context) {
            preloader.warm(
              context,
              items,
              0,
              artwork: (item) => images[int.parse(item.id)],
            );
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(page());
      await tester.pump();
      expect(loaded.whereType<MemoryImage>(), [images[1], images[3]]);
      expect(logos.requested, ['1', '3']);
      expect(loaded, hasLength(4));
      await tester.pumpWidget(page());
      await tester.pump();
      expect(loaded, hasLength(4));
      preloader.dispose();
    });
  }

  testWidgets('disposal stops late logo downloads', (tester) async {
    final logos = _Logos()..pending = Completer<String?>();
    sl.registerSingleton<TitleLogoService>(logos);
    final loaded = <ImageProvider>[];
    final items = List.generate(
      2,
      (i) => MediaItem(
        id: '$i',
        title: '$i',
        url: '/$i',
        type: ProviderType.anime,
        sourceId: 'test',
      ),
    );
    final preloader = BannerImagePreloader(
      loadImage: (image, context) async {
        loaded.add(image);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            preloader.warm(
              context,
              items,
              0,
              artwork: (_) => MemoryImage(Uint8List(1)),
            );
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    expect(logos.requested, ['1']);
    preloader.dispose();
    logos.pending!.complete('https://example.test/logo.png');
    await tester.pump();
    expect(loaded, hasLength(1));
  });
}
