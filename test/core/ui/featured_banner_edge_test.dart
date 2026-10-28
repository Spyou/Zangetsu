import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/ui/featured_banner_edge.dart';
import 'package:watch_app/core/ui/featured_carousel.dart';
import 'package:watch_app/core/ui/route_observer.dart';

MediaItem _item(String id, String title) => MediaItem(
  id: id,
  title: title,
  url: 'https://example.test/$id',
  type: ProviderType.anime,
  sourceId: 'test',
);

void main() {
  for (final edge in [true, false]) {
    testWidgets(
      'samples displayed portrait rather than unrelated backdrop (edge=$edge)',
      (tester) async {
        final sampled = <String>[];
        final item = MediaItem(
          id: 'poster-colour',
          title: 'Poster colour',
          url: 'https://example.test/title',
          type: ProviderType.anime,
          sourceId: 'test',
          cover: 'https://image.tmdb.org/t/p/w500/poster.jpg',
          banner: 'https://image.tmdb.org/t/p/w780/different-backdrop.jpg',
        );
        Future<Color?> palette(String url, Map<String, String>? headers) async {
          sampled.add(url);
          return null;
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: edge
                  ? FeaturedBannerEdge(
                      items: [item],
                      onInfo: (_) {},
                      onArtColor: (_) {},
                      paletteLoader: palette,
                    )
                  : FeaturedCarousel(
                      items: [item],
                      inList: (_) => false,
                      onPlay: (_) {},
                      onInfo: (_) {},
                      onToggleList: (_) {},
                      onArtColor: (_) {},
                      paletteLoader: palette,
                    ),
            ),
          ),
        );
        await tester.pump();
        expect(sampled, ['https://image.tmdb.org/t/p/w500/poster.jpg']);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 30));
      },
    );
  }

  testWidgets('places featured title content at the bottom', (tester) async {
    final item = _item('1', 'First Show');
    MediaItem? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturedBannerEdge(items: [item], onInfo: (m) => opened = m),
        ),
      ),
    );

    final banner = tester.getRect(
      find.byKey(const ValueKey('featuredEdgeBanner')),
    );
    final content = find.byKey(const ValueKey('edgeBannerContent-1'));
    final viewButton = find.byKey(const ValueKey('edgeBannerViewButton'));
    expect(tester.widget<Align>(content).alignment, Alignment.bottomCenter);
    expect(banner.left, 0);
    expect(
      banner.right,
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
    );
    expect(find.text('First Show'), findsOneWidget);
    expect(find.text('View Details'), findsOneWidget);
    expect(tester.getCenter(viewButton).dx, closeTo(banner.center.dx, 1));
    expect(tester.getSize(viewButton).width, lessThanOrEqualTo(150));
    expect(tester.getSize(viewButton).height, lessThanOrEqualTo(48));
    expect(find.text('Play'), findsNothing);

    await tester.tap(viewButton);
    expect(opened, item);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('swiping changes the featured title', (tester) async {
    MediaItem? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturedBannerEdge(
            items: [_item('1', 'First Show'), _item('2', 'Second Show')],
            onInfo: (m) => opened = m,
          ),
        ),
      ),
    );

    expect(find.text('First Show'), findsOneWidget);
    await tester.fling(
      find.byKey(const ValueKey('edgeBannerGesture')),
      const Offset(-300, 0),
      2000,
    );
    await tester.pumpAndSettle();
    expect(find.text('Second Show'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('edgeBannerViewButton')));
    expect(opened?.title, 'Second Show');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'adaptive tint replaces black shading without changing banner layout',
    (tester) async {
      final item = _item('adaptive-shading', 'Adaptive shading');
      final tint = ValueNotifier<Color?>(const Color(0xFF4C2424));
      addTearDown(tint.dispose);
      MediaItem? opened;
      Widget banner(bool adaptive) => MaterialApp(
        home: Scaffold(
          body: FeaturedBannerEdge(
            items: [item],
            onInfo: (value) => opened = value,
            backgroundTint: adaptive ? tint : null,
          ),
        ),
      );
      LinearGradient gradient() =>
          (tester
                          .widget<DecoratedBox>(
                            find.byKey(const ValueKey('edgeBannerScrim')),
                          )
                          .decoration
                      as BoxDecoration)
                  .gradient!
              as LinearGradient;
      await tester.pumpWidget(banner(false));
      final size = tester.getSize(
        find.byKey(const ValueKey('featuredEdgeBanner')),
      );
      final original = gradient().colors;
      expect(original, [
        const Color(0x66000000),
        const Color(0x33000000),
        const Color(0xCC0B0B0F),
        AppColors.bg,
      ]);
      await tester.pumpWidget(banner(true));
      await tester.pumpAndSettle();
      expect(gradient().colors, [
        tint.value!.withValues(alpha: 0.02),
        tint.value!.withValues(alpha: 0.12),
        tint.value!.withValues(alpha: 0.34),
        tint.value,
      ]);
      expect(
        tester.getSize(find.byKey(const ValueKey('featuredEdgeBanner'))),
        size,
      );
      await tester.tap(find.byKey(const ValueKey('edgeBannerViewButton')));
      expect(opened, item);
      await tester.pumpWidget(banner(false));
      await tester.pumpAndSettle();
      expect(gradient().colors, original);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('scrim melts into the adaptive background tint', (tester) async {
    final tint = ValueNotifier<Color?>(null);
    addTearDown(tint.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturedBannerEdge(
            items: [_item('1', 'First Show')],
            onInfo: (_) {},
            backgroundTint: tint,
          ),
        ),
      ),
    );

    Color scrimBottom() {
      final box = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('edgeBannerScrim')),
      );
      final gradient = (box.decoration as BoxDecoration).gradient!;
      return (gradient as LinearGradient).colors.last;
    }

    expect(scrimBottom(), AppColors.bg);

    tint.value = const Color(0xFF123456);
    await tester.pump();
    expect(scrimBottom(), AppColors.bg);
    await tester.pump(const Duration(milliseconds: 300));
    expect(scrimBottom(), isNot(AppColors.bg));
    expect(scrimBottom(), isNot(const Color(0xFF123456)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(scrimBottom(), const Color(0xFF123456));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ignores a colour decoded after the banner list empties', (
    tester,
  ) async {
    final pending = Completer<Color?>();
    final colors = <Color?>[];
    final item = MediaItem(
      id: 'late',
      title: 'Late Show',
      cover: 'https://example.test/late.jpg',
      url: 'https://example.test/late',
      type: ProviderType.anime,
      sourceId: 'test',
    );

    Widget banner(List<MediaItem> items) => MaterialApp(
      home: Scaffold(
        body: FeaturedBannerEdge(
          items: items,
          onInfo: (_) {},
          onArtColor: colors.add,
          paletteLoader: (_, _) => pending.future,
        ),
      ),
    );

    await tester.pumpWidget(banner([item]));
    await tester.pumpWidget(banner([]));
    pending.complete(Colors.red);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(colors, isNot(contains(Colors.red)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('does not extract colours without a tint listener', (
    tester,
  ) async {
    var loads = 0;
    final item = MediaItem(
      id: 'off',
      title: 'No Tint',
      cover: 'https://example.test/off.jpg',
      url: 'https://example.test/off',
      type: ProviderType.anime,
      sourceId: 'test',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturedBannerEdge(
            items: [item],
            onInfo: (_) {},
            paletteLoader: (_, _) {
              loads++;
              return Future.value(Colors.red);
            },
          ),
        ),
      ),
    );
    expect(loads, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturedBannerEdge(
            items: [item],
            onInfo: (_) {},
            onArtColor: (_) {},
            paletteLoader: (_, _) {
              loads++;
              return Future.value(Colors.red);
            },
          ),
        ),
      ),
    );
    expect(loads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pauses rotation and tint work while Home is inactive', (
    tester,
  ) async {
    final pending = Completer<Color?>();
    final colors = <Color?>[];
    var loads = 0;
    final items = [
      for (final id in ['first', 'second'])
        MediaItem(
          id: id,
          title: '$id show',
          cover: 'https://example.test/$id.jpg',
          url: 'https://example.test/$id',
          type: ProviderType.anime,
          sourceId: 'test',
        ),
    ];
    Widget banner(bool active) => MaterialApp(
      home: Scaffold(
        body: FeaturedBannerEdge(
          items: items,
          onInfo: (_) {},
          isActive: active,
          onArtColor: colors.add,
          paletteLoader: (_, _) {
            loads++;
            return loads == 1 ? pending.future : Future.value(Colors.blue);
          },
        ),
      ),
    );

    await tester.pumpWidget(banner(true));
    expect(loads, 1);
    await tester.pumpWidget(banner(false));
    pending.complete(Colors.red);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(colors, isNot(contains(Colors.red)));
    expect(loads, 1);
    expect(find.text('first show'), findsOneWidget);

    await tester.pumpWidget(banner(true));
    await tester.pump();
    expect(colors.last, Colors.blue);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('second show'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pauses rotation while another route covers Home', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [appRouteObserver],
        home: Scaffold(
          body: FeaturedBannerEdge(
            items: [_item('1', 'First Show'), _item('2', 'Second Show')],
            onInfo: (_) {},
          ),
        ),
      ),
    );

    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Detail')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('First Show'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Second Show'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
