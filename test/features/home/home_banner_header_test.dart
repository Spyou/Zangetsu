import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/banner_style.dart';
import 'package:watch_app/features/home/home_banner_header.dart';

void main() {
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
