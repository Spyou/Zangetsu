import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/source_icon_tile.dart';

/// [SourceIconTile] is the one tile every source list draws, so the rules it
/// enforces — letter fallback, no plate under a real icon — only have to hold
/// here for the picker, the Sources screen and every ecosystem screen.

Future<void> pump(WidgetTester t, Widget child) => t.pumpWidget(
  MaterialApp(home: Scaffold(body: Center(child: child))),
);

void main() {
  testWidgets('no icon url → the letter, no network image', (t) async {
    await pump(t, const SourceIconTile(name: 'AnimePahe'));

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('an empty icon url counts as no icon', (t) async {
    // An empty string handed to CachedNetworkImage is a real url to it, and
    // it draws a broken tile rather than falling back.
    await pump(t, const SourceIconTile(name: 'AnimePahe', icon: ''));

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('an icon url builds a network image for exactly that url',
      (t) async {
    await pump(
      t,
      const SourceIconTile(name: 'AnimePahe', icon: 'https://i.test/ap.png'),
    );

    final img = t.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(img.imageUrl, 'https://i.test/ap.png');
    // contain, not cover: a wide wordmark logo must shrink, not get its ends
    // cropped off.
    expect(img.fit, BoxFit.contain);
  });

  testWidgets('a failed icon falls back to a centred, plated letter',
      (t) async {
    await pump(
      t,
      const SourceIconTile(name: 'Kuramanime', icon: 'https://i.test/k.png'),
    );
    final img = t.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));

    // Drive the failure path directly — a real failed fetch needs a reachable
    // network here, and the widget's own errorWidget IS the fallback.
    final fallback = img.errorWidget!(
      t.element(find.byType(CachedNetworkImage)),
      img.imageUrl,
      Exception('network down'),
    );
    // CachedNetworkImage hands its errorWidget a bare box that aligns
    // top-left and paints nothing, so the letter must bring its own centring
    // AND its own plate or a 404 draws a naked glyph in the corner.
    expect(fallback, isA<Container>());
    final plate = fallback as Container;
    expect(plate.alignment, Alignment.center);
    expect(plate.decoration, isNotNull);
    expect((plate.child as Text).data, 'K');
  });

  testWidgets('the same letter tile stands in while the icon loads', (t) async {
    await pump(
      t,
      const SourceIconTile(name: 'Kuramanime', icon: 'https://i.test/k.png'),
    );
    final img = t.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));

    final loading = img.placeholder!(
      t.element(find.byType(CachedNetworkImage)),
      img.imageUrl,
    );
    expect(loading, isA<Container>());
    expect(((loading as Container).child as Text).data, 'K');
  });

  testWidgets('a real icon gets no plate behind it', (t) async {
    // Extension logos ship with a pixel or two of transparent margin, so a
    // plate shows through as a grey frame around every one of them.
    await pump(
      t,
      const SourceIconTile(name: 'AHottie', icon: 'https://i.test/a.png'),
    );
    final outer = t.widget<Container>(find.byType(Container).first);
    final deco = outer.decoration as BoxDecoration;
    expect(deco.color, Colors.transparent);
  });

  testWidgets('a letter tile DOES get a plate', (t) async {
    await pump(t, const SourceIconTile(name: 'AHottie'));
    final outer = t.widget<Container>(find.byType(Container).first);
    final deco = outer.decoration as BoxDecoration;
    expect(deco.color, isNot(Colors.transparent));
  });

  testWidgets('an empty name still draws something', (t) async {
    await pump(t, const SourceIconTile(name: '   '));
    expect(find.text('?'), findsOneWidget);
  });
}
