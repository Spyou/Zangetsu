import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/banner_style.dart';
import 'package:watch_app/core/ui/content_row.dart';
import 'package:watch_app/core/ui/featured_carousel.dart' show heroHeightFor;
import 'package:watch_app/features/home/home_banner_header.dart';

void main() {
  testWidgets('rows move up ten pixels without resizing or moving the banner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final style = ValueNotifier<String>(BannerStyle.edgeId);
    addTearDown(style.dispose);
    late double height;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              height = heroHeightFor(context);
              return Column(
                children: [
                  HomeBannerHeader(
                    bannerStyle: style,
                    hasHero: true,
                    bannerBuilder: (_) => SizedBox(
                      key: const ValueKey('original-banner'),
                      height: height,
                    ),
                    headerBuilder: (_) => const SizedBox(
                      key: ValueKey('original-header'),
                      height: 40,
                    ),
                  ),
                  const ContentRow(
                    title: 'Continue Watching',
                    itemCount: 0,
                    itemHeight: 40,
                    itemBuilder: _unusedItem,
                  ),
                  const ContentRow(
                    title: 'Trending',
                    itemCount: 0,
                    itemHeight: 40,
                    itemBuilder: _unusedItem,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    final banner = find.byKey(const ValueKey('original-banner'));
    expect(tester.getSize(banner).height, height);
    expect(tester.getTopLeft(banner).dy, 0);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('original-header'))).dy,
      0,
    );
    expect(tester.getTopLeft(find.text('Continue Watching')).dy, height + 16);
    final first = tester.getRect(find.byType(ContentRow).first);
    final second = tester.getRect(find.byType(ContentRow).last);
    expect(second.top, first.bottom);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the row stays put when the loading hero appears', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final style = ValueNotifier<String>(BannerStyle.edgeId);
    addTearDown(style.dispose);

    Future<void> pumpHeader({required bool loading, required bool hasHero}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  HomeBannerHeader(
                    bannerStyle: style,
                    hasHero: hasHero,
                    loading: loading,
                    bannerBuilder: (_) => const Text('banner'),
                    headerBuilder: (_) => const SizedBox(height: 40),
                  ),
                  const Text('first row'),
                ],
              ),
            ),
          ),
        );

    await pumpHeader(loading: true, hasHero: false);
    final row = find.text('first row');
    final loadingTop = tester.getTopLeft(row).dy;
    for (final part in ['artwork', 'title', 'metadata', 'actions']) {
      expect(find.byKey(ValueKey('hero-skeleton-$part')), findsOneWidget);
    }
    expect(find.text('banner'), findsNothing);

    await pumpHeader(loading: false, hasHero: true);
    expect(tester.getTopLeft(row).dy, loadingTop);
    expect(find.byKey(const ValueKey('hero-skeleton-artwork')), findsNothing);

    await pumpHeader(loading: false, hasHero: false);
    expect(tester.getTopLeft(row).dy, 40);
  });

  testWidgets('loading keeps the header style selected for the banner', (
    tester,
  ) async {
    final style = ValueNotifier<String>(BannerStyle.edgeId);
    addTearDown(style.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeBannerHeader(
            bannerStyle: style,
            hasHero: false,
            bannerBuilder: (_) => const Text('banner'),
            headerBuilder: (edge) => Text(edge ? 'edge header' : 'old header'),
          ),
        ),
      ),
    );

    expect(find.text('edge header'), findsOneWidget);
    expect(find.text('old header'), findsNothing);
    expect(find.text('banner'), findsNothing);

    style.value = 'card';
    await tester.pump();
    expect(find.text('old header'), findsOneWidget);
  });
}

Widget _unusedItem(BuildContext context, int index) => const SizedBox();
