import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/stremio/stremio_poster_shape.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/features/home/home_screen_tv.dart';
import 'package:watch_app/features/home/see_all_screen.dart';

MediaItem item(String? shape, {String source = 'stremio'}) => MediaItem(
  id: 'a',
  title: 'Title',
  url: 'stremio://a',
  sourceId: source,
  type: ProviderType.movie,
  posterShape: shape,
);

void main() {
  setUp(() => sl.registerSingleton<AppMode>(const AppMode(isTv: false)));
  tearDown(() => sl.unregister<AppMode>());

  test('landscape artwork uses addon art before backdrop and poster', () {
    const media = MediaItem(
      id: 'a',
      title: 'A',
      url: 'stremio://a',
      sourceId: 'stremio',
      type: ProviderType.movie,
      cover: 'poster',
      banner: 'backdrop',
      landscapePoster: 'landscape',
    );
    expect(stremioPosterImage(media, landscape: true), 'landscape');
    expect(stremioPosterImage(media, landscape: false), 'poster');
    expect(stremioPosterImage(item(null), landscape: true), isNull);
    expect(stremioPosterAspect(item('square'), landscape: true), 16 / 9);
    expect(media.copyWith().landscapePoster, 'landscape');
    expect(media.toJson().containsKey('landscapePoster'), isFalse);
    const backdrop = MediaItem(
      id: 'b',
      title: 'B',
      url: '',
      sourceId: 'stremio',
      type: ProviderType.movie,
      cover: 'poster',
      banner: 'backdrop',
    );
    expect(stremioPosterImage(backdrop, landscape: true), 'backdrop');
    const poster = MediaItem(
      id: 'c',
      title: 'C',
      url: '',
      sourceId: 'stremio',
      type: ProviderType.movie,
      cover: 'poster',
      banner: '  ',
    );
    expect(stremioPosterImage(poster, landscape: true), 'poster');
  });
  testWidgets('see all preserves mixed artwork shapes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SeeAllScreen(
          title: 'Catalogue',
          items: [item('landscape'), item('square'), item('poster')],
          onTap: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final arts = tester
        .elementList(find.byType(ClipRSuperellipse))
        .map((e) => (e.renderObject as RenderBox).size)
        .toList();
    expect(arts.length, 3);
    expect(arts[0].width / arts[0].height, closeTo(16 / 9, 0.01));
    expect(arts[1].width / arts[1].height, closeTo(1, 0.01));
    expect(arts[2].width / arts[2].height, closeTo(2 / 3, 0.01));
    expect(tester.takeException(), isNull);
  });
  test('declared artwork ratios preserve card geometry', () {
    expect(
      posterCellHeight(160, artAspectRatio: 16 / 9, titleInside: true),
      90,
    );
    expect(posterCellHeight(160, artAspectRatio: 1, titleInside: true), 160);
    expect(
      posterCellHeight(160, artAspectRatio: 2 / 3, titleInside: true),
      240,
    );
  });

  testWidgets(
    'landscape shaped addon cards keep the supplied poster outside landscape mode',
    (tester) async {
      const media = MediaItem(
        id: 'a',
        title: 'A',
        url: '',
        sourceId: 'stremio',
        type: ProviderType.movie,
        cover: 'https://img.example/poster',
        banner: 'https://img.example/backdrop',
        landscapePoster: 'https://img.example/wide',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 184,
            height: 150,
            child: PosterCard(title: 'A', logoItem: media, wideOverride: true),
          ),
        ),
      );
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .imageUrl,
        'https://img.example/poster',
      );
    },
  );
  testWidgets(
    'addon shape uses its poster rather than replacing it with backdrop',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 184,
              height: 150,
              child: PosterCard(
                title: 'Title',
                imageUrl: 'https://img.example/poster.jpg',
                wideImageUrl: 'https://img.example/background.jpg',
                wideOverride: true,
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .imageUrl,
        'https://img.example/poster.jpg',
      );
    },
  );
  test('only known Stremio poster shapes override the existing layout', () {
    expect(stremioPosterAspect(item('landscape')), 16 / 9);
    expect(stremioPosterAspect(item('square')), 1);
    expect(stremioPosterAspect(item('poster')), 2 / 3);
    expect(stremioPosterAspect(item(' LANDSCAPE ')), 16 / 9);
    for (final shape in [null, '', 'unknown']) {
      expect(stremioPosterAspect(item(shape)), isNull);
    }
    expect(
      stremioPosterAspect(item('landscape', source: 'cs:Example')),
      isNull,
    );
  });

  testWidgets(
    'TV Home honours mixed addon artwork without changing other cards',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvRail(
              section: HomeSection(
                title: 'Catalogue',
                items: [item('landscape'), item('square'), item(null)],
              ),
              onTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      final cards = find.byType(PosterCard);
      expect(cards, findsNWidgets(3));
      final sizes = tester
          .elementList(cards)
          .map((e) => (e.renderObject as RenderBox).size)
          .toList();
      expect(sizes[0].width / sizes[0].height, closeTo(16 / 9, 0.01));
      expect(sizes[1].width / sizes[1].height, closeTo(1, 0.01));
      expect(sizes[2].width / sizes[2].height, closeTo(2 / 3, 0.01));
      expect(tester.takeException(), isNull);
    },
  );
}
