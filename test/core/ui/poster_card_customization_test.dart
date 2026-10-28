import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/core/tv/tv_poster_tile.dart';
import 'package:watch_app/core/ui/settings_widgets.dart';
import 'package:watch_app/features/home/home_screen_tv.dart';
import 'package:watch_app/features/settings/poster_card_settings_screen.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('poster_card_prefs');
    Hive.init(temp.path);
    await PlaybackPrefs.init();
    GetIt.I.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
  });

  tearDown(() async {
    await GetIt.I.reset();
    await Hive.close();
    await temp.delete(recursive: true);
  });

  testWidgets('poster titles fit two scaled lines without shrinking artwork', (
    tester,
  ) async {
    for (final scale in [1.0, 1.3, 2.0]) {
      for (final wide in [false, true]) {
        await tester.runAsync(() async {
          await PlaybackPrefs().setPosterCardLayout(
            wide ? PosterCardLayout.wide : PosterCardLayout.portrait,
          );
          await PlaybackPrefs().setPosterTitlePlacement(
            PosterTitlePlacement.below,
          );
        });
        late double width;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Builder(
                builder: (context) {
                  width = posterRowWidth(context);
                  return Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      height: posterRowHeight(context),
                      child: PosterCard(
                        title: 'Hunter x\nHunter (2011)',
                        cellWidth: width,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        final text = tester.widget<Text>(find.text('Hunter x\nHunter (2011)'));
        final painter = TextPainter(
          text: TextSpan(text: text.data, style: text.style),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.linear(scale),
          maxLines: 2,
        )..layout(maxWidth: width);
        expect(
          tester.getSize(find.byType(PosterCardTitle)).height,
          greaterThanOrEqualTo(painter.height - 0.01),
        );
        expect(
          tester.getSize(find.byType(ClipRSuperellipse)).height,
          closeTo(wide ? width * 9 / 16 : width * 1.5, 1),
        );
        painter.dispose();
        expect(tester.takeException(), isNull);
      }
    }
  });

  test(
    'poster geometry preserves default sizes and scales only external titles',
    () {
      expect(posterCellHeight(116), 216);
      expect(posterCellHeight(184, wide: true), 146);
      expect(posterCellHeight(116, textScaler: TextScaler.linear(2)), 250);
      expect(
        posterCellAspect(116, textScaler: TextScaler.linear(2)),
        116 / 250,
      );
      expect(
        posterCellHeight(
          116,
          titleInside: true,
          textScaler: TextScaler.linear(2),
        ),
        posterCellHeight(116, titleInside: true),
      );
    },
  );

  test('poster options preserve the existing look by default', () {
    final prefs = PlaybackPrefs();
    expect(prefs.posterCardLayout, PosterCardLayout.portrait);
    expect(prefs.posterPortraitSize, PosterCardSize.standard);
    expect(prefs.posterLandscapeSize, PosterCardSize.standard);
    expect(prefs.posterTitlePlacement, PosterTitlePlacement.adaptive);
    expect(prefs.posterTitleStyle, PosterTitleStyle.text);
    expect(prefs.posterQualityBadge, isTrue);
    expect(prefs.posterAudioBadge, isTrue);
    expect(prefs.posterScoreBadge, isTrue);
    expect(prefs.posterGenreBadge, isFalse);
    expect(prefs.posterAdultBadge, isFalse);
    expect(prefs.posterProgressBadge, isFalse);
  });

  test('poster options persist and notify visible cards', () async {
    final prefs = PlaybackPrefs();
    final before = PlaybackPrefs.posterRevision.value;

    await prefs.setPosterCardLayout(PosterCardLayout.wide);
    await prefs.setPosterPortraitSize(PosterCardSize.large);
    await prefs.setPosterLandscapeSize(PosterCardSize.small);
    await prefs.setPosterTitlePlacement(PosterTitlePlacement.inside);
    await prefs.setPosterTitleStyle(PosterTitleStyle.artwork);
    await prefs.setPosterGenreBadge(true);

    expect(PlaybackPrefs().posterCardLayout, PosterCardLayout.wide);
    expect(PlaybackPrefs().posterPortraitSize, PosterCardSize.large);
    expect(PlaybackPrefs().posterLandscapeSize, PosterCardSize.small);
    expect(PlaybackPrefs().posterTitlePlacement, PosterTitlePlacement.inside);
    expect(PlaybackPrefs().posterTitleStyle, PosterTitleStyle.artwork);
    expect(PlaybackPrefs().posterGenreBadge, isTrue);
    expect(PlaybackPrefs.posterRevision.value, before + 6);
  });

  test(
    'legacy badge preference remains the default for current badges',
    () async {
      final prefs = PlaybackPrefs();
      await prefs.setQualityBadges(false);

      expect(prefs.posterQualityBadge, isFalse);
      expect(prefs.posterAudioBadge, isFalse);
      expect(prefs.posterScoreBadge, isFalse);
    },
  );

  test('known adult status survives a source repoint', () {
    const item = MediaItem(
      id: '1',
      title: 'Example',
      url: 'url',
      type: ProviderType.anime,
      sourceId: 'a',
      isAdult: true,
    );
    expect(item.copyWith(sourceId: 'b').isAdult, isTrue);
    expect(MediaItem.fromJson(item.toJson()).isAdult, isTrue);
    expect(
      MediaItem.fromJson({...item.toJson()}..remove('isAdult')).isAdult,
      isFalse,
    );
  });

  testWidgets('genre and adult labels sit inside landscape artwork', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide);
      await PlaybackPrefs().setPosterGenreBadge(true);
      await PlaybackPrefs().setPosterAdultBadge(true);
      await PlaybackPrefs().setPosterProgressBadge(true);
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 184,
            height: 104,
            child: PosterCard(
              title: 'Example',
              genres: ['Action'],
              isAdult: true,
              progressBadge: 'EP 4/12',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final artwork = find.byType(ClipRSuperellipse);
    final artworkRect = tester.getRect(artwork);
    final actionRect = tester.getRect(find.text('Action'));
    final adultRect = tester.getRect(find.text('18+'));
    expect(
      find.descendant(of: artwork, matching: find.text('Action')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: artwork, matching: find.text('18+')),
      findsOneWidget,
    );
    expect(find.text('EP 4/12'), findsOneWidget);
    expect(actionRect.right, lessThan(adultRect.left));
    expect(adultRect.right, lessThan(artworkRect.right));
    expect(adultRect.bottom, greaterThan(artworkRect.bottom - 16));
  });

  testWidgets('portrait art hides genre but can still show adult rating', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await PlaybackPrefs().setPosterCardLayout(PosterCardLayout.portrait);
      await PlaybackPrefs().setPosterGenreBadge(true);
      await PlaybackPrefs().setPosterAdultBadge(true);
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 116,
            height: 174,
            child: PosterCard(
              title: 'Example',
              genres: ['Action'],
              isAdult: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final artwork = find.byType(ClipRSuperellipse);
    expect(
      find.descendant(of: artwork, matching: find.text('Action')),
      findsNothing,
    );
    expect(
      find.descendant(of: artwork, matching: find.text('18+')),
      findsOneWidget,
    );
  });

  testWidgets('genre setting is disabled for portrait and enabled for wide', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: PosterCardSettingsScreen()),
    );
    await tester.scrollUntilVisible(
      find.text('Genre'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    var genreTile = find.ancestor(
      of: find.text('Genre'),
      matching: find.byType(SettingsTile),
    );
    var genreSwitch = find.descendant(
      of: genreTile,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(genreSwitch).onChanged, isNull);

    await tester.runAsync(
      () => PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide),
    );
    await tester.pumpWidget(
      const MaterialApp(home: PosterCardSettingsScreen()),
    );
    await tester.scrollUntilVisible(
      find.text('Genre'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    genreTile = find.ancestor(
      of: find.text('Genre'),
      matching: find.byType(SettingsTile),
    );
    genreSwitch = find.descendant(of: genreTile, matching: find.byType(Switch));
    expect(tester.widget<Switch>(genreSwitch).onChanged, isNotNull);
  });

  testWidgets('settings preview uses real poster and logo lookup identity', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() => PlaybackPrefs().setPosterAdultBadge(true));

    await tester.pumpWidget(
      const MaterialApp(home: PosterCardSettingsScreen()),
    );
    await tester.pump();

    final previews = find.byType(PosterCard);
    expect(previews, findsNWidgets(3));
    expect(find.byType(VerticalDivider), findsOneWidget);
    final preview = tester.widget<PosterCard>(previews.first);
    expect(preview.title, 'The Boys');
    expect(
      preview.imageUrl,
      'https://image.tmdb.org/t/p/w500/in1R2dDc421JxsoRWaIIAqVI2KE.jpg',
    );
    expect(
      preview.wideImageUrl,
      'https://image.tmdb.org/t/p/w780/bq28ajZaoMyzEIm6REelqyqtEDZ.jpg',
    );
    expect(preview.logoItem?.tmdbId, 76479);
    expect(preview.logoItem?.tmdbIsTv, isTrue);
    expect(find.text('18+'), findsOneWidget);
    expect(tester.getRect(previews.first).left, closeTo(16, 0.1));
    expect(tester.getRect(previews.last).right, closeTo(344, 0.1));
    expect(
      tester.getRect(find.byType(VerticalDivider)).center.dx,
      greaterThan(tester.getRect(previews.first).right),
    );
    expect(
      tester.getRect(find.byType(VerticalDivider)).center.dx,
      lessThan(tester.getRect(previews.at(1)).left),
    );
  });

  testWidgets('wide cards use backdrops and crop fallback posters', (
    tester,
  ) async {
    await tester.runAsync(
      () => PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: SizedBox(
              width: 184,
              height: 146,
              child: const PosterCard(
                title: 'Backdrop',
                imageUrl: 'https://example.com/poster.jpg',
                wideImageUrl: 'https://example.com/backdrop.jpg',
              ),
            ),
          ),
        ),
      ),
    );
    var image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, 'https://example.com/backdrop.jpg');
    expect(image.fit, BoxFit.cover);

    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: SizedBox(
              width: 184,
              height: 146,
              child: const PosterCard(
                title: 'Fallback',
                imageUrl: 'https://example.com/poster.jpg',
              ),
            ),
          ),
        ),
      ),
    );
    image = tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(image.imageUrl, 'https://example.com/poster.jpg');
    expect(image.fit, BoxFit.cover);
  });

  testWidgets('landscape title sits on the art below its badges', (
    tester,
  ) async {
    await tester.runAsync(
      () => PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: SizedBox(
              width: 184,
              height: 104,
              child: const PosterCard(
                title: 'Actual series title',
                tags: ['SUB'],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Actual series title'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ClipRSuperellipse),
        matching: find.text('Actual series title'),
      ),
      findsOneWidget,
    );
    expect(
      tester.getRect(find.text('SUB')).bottom,
      lessThan(tester.getRect(find.text('Actual series title')).top),
    );
    expect(
      posterCellAspect(184, wide: true, titleInside: true),
      closeTo(16 / 9, 0.001),
    );
  });

  testWidgets('below placement keeps landscape title outside the image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide);
      await PlaybackPrefs().setPosterTitlePlacement(PosterTitlePlacement.below);
    });
    final height = posterCellHeight(184, wide: true);
    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: SizedBox(
              width: 184,
              height: height,
              child: const PosterCard(title: 'Outside title'),
            ),
          ),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(ClipRSuperellipse),
        matching: find.text('Outside title'),
      ),
      findsNothing,
    );
    expect(
      tester.getRect(find.text('Outside title')).top -
          tester.getRect(find.byType(ClipRSuperellipse)).bottom,
      closeTo(8, 0.5),
    );
    expect(posterCellAspect(184, wide: true), lessThan(16 / 9));
  });

  testWidgets('default portrait title remains below the art', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 116,
            height: 216,
            child: PosterCard(title: 'Portrait title'),
          ),
        ),
      ),
    );

    expect(find.text('Portrait title'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ClipRSuperellipse),
        matching: find.text('Portrait title'),
      ),
      findsNothing,
    );
  });

  testWidgets('inside title placement also applies to portrait posters', (
    tester,
  ) async {
    await tester.runAsync(
      () =>
          PlaybackPrefs().setPosterTitlePlacement(PosterTitlePlacement.inside),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 116,
            height: 174,
            child: PosterCard(title: 'Portrait title'),
          ),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(ClipRSuperellipse),
        matching: find.text('Portrait title'),
      ),
      findsOneWidget,
    );
    expect(posterCellAspect(116, titleInside: true), closeTo(2 / 3, 0.001));
  });

  testWidgets('landscape TV tile has one title inside its art', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.runAsync(
      () => PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: SizedBox(
              width: 240,
              height: 135,
              child: TvPosterTile(title: 'Actual movie title', onTap: () {}),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Actual movie title'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ClipRSuperellipse),
        matching: find.text('Actual movie title'),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Actual movie title'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('portrait TV tile can place its title inside the art', (
    tester,
  ) async {
    await tester.runAsync(
      () =>
          PlaybackPrefs().setPosterTitlePlacement(PosterTitlePlacement.inside),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: SizedBox(
              width: 240,
              height: 360,
              child: TvPosterTile(title: 'Portrait TV title', onTap: () {}),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Portrait TV title'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ClipRSuperellipse),
        matching: find.text('Portrait TV title'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('landscape TV rail has one title inside each card', (
    tester,
  ) async {
    await tester.runAsync(
      () => PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: TvRail(
              section: const HomeSection(
                title: 'Featured',
                items: [
                  MediaItem(
                    id: 'movie',
                    title: 'Actual rail title',
                    url: 'url',
                    type: ProviderType.movie,
                    sourceId: 'source',
                  ),
                ],
              ),
              onTap: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Actual rail title'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ClipRSuperellipse),
        matching: find.text('Actual rail title'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('grid geometry switches without a data reload', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: Builder(
              builder: (context) {
                return Column(
                  children: [
                    Text('${posterGridColumns(context)}'),
                    SizedBox(
                      width: 120,
                      height: 230,
                      child: TvPosterTile(title: 'TV', onTap: () {}),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('3'), findsOneWidget);
    await tester.runAsync(
      () => PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide),
    );
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    expect(
      tester
          .widget<AspectRatio>(
            find.descendant(
              of: find.byType(TvPosterTile),
              matching: find.byType(AspectRatio),
            ),
          )
          .aspectRatio,
      16 / 9,
    );
  });

  testWidgets('poster size preferences resize portrait and landscape cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  Text('grid:${posterGridColumns(context)}'),
                  Text('row:${posterRowWidth(context).toStringAsFixed(1)}'),
                  Text('tv:${tvPosterGridColumns(context)}'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('grid:3'), findsOneWidget);
    expect(find.text('row:116.0'), findsOneWidget);
    expect(find.text('tv:6'), findsOneWidget);

    Future<void> saveSize(Future<void> Function() save) async {
      await tester.runAsync(() async {
        await save();
      });
      await tester.pump();
    }

    await saveSize(
      () => PlaybackPrefs().setPosterPortraitSize(PosterCardSize.small),
    );
    expect(find.text('grid:4'), findsOneWidget);
    expect(find.text('row:98.6'), findsOneWidget);
    expect(find.text('tv:7'), findsOneWidget);

    await saveSize(
      () => PlaybackPrefs().setPosterPortraitSize(PosterCardSize.large),
    );
    expect(find.text('grid:2'), findsOneWidget);
    expect(find.text('row:133.4'), findsOneWidget);
    expect(find.text('tv:5'), findsOneWidget);

    await tester.runAsync(
      () => PlaybackPrefs().setPosterCardLayout(PosterCardLayout.wide),
    );
    await tester.pump();
    expect(find.text('grid:2'), findsOneWidget);
    expect(find.text('row:184.0'), findsOneWidget);
    expect(find.text('tv:4'), findsOneWidget);

    await saveSize(
      () => PlaybackPrefs().setPosterLandscapeSize(PosterCardSize.small),
    );
    expect(find.text('grid:3'), findsOneWidget);
    expect(find.text('row:156.4'), findsOneWidget);
    expect(find.text('tv:5'), findsOneWidget);

    await saveSize(
      () => PlaybackPrefs().setPosterLandscapeSize(PosterCardSize.large),
    );
    expect(find.text('grid:1'), findsOneWidget);
    expect(find.text('row:211.6'), findsOneWidget);
    expect(find.text('tv:3'), findsOneWidget);

    await tester.runAsync(
      () => PlaybackPrefs().setPosterCardLayout(PosterCardLayout.portrait),
    );
    await tester.pump();
    expect(find.text('grid:2'), findsOneWidget);
    expect(find.text('row:133.4'), findsOneWidget);
    expect(find.text('tv:5'), findsOneWidget);
  });

  testWidgets('Interface exposes independent portrait and landscape sizes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(child: const PosterCardSettingsScreen()),
      ),
    );

    expect(find.text('Portrait card size'), findsOneWidget);
    expect(find.text('Landscape card size'), findsOneWidget);
    expect(find.text('Small'), findsNWidgets(2));
    expect(find.text('Default'), findsNWidgets(2));
    expect(find.text('Large'), findsNWidgets(2));
    final controls = tester
        .widgetList<SegmentedButton<PosterCardSize>>(
          find.byType(SegmentedButton<PosterCardSize>),
        )
        .toList();
    expect(controls, hasLength(2));
    expect(
      controls.every((control) => control.onSelectionChanged != null),
      isTrue,
    );

    expect(controls.map((control) => control.selected), [
      {PosterCardSize.standard},
      {PosterCardSize.standard},
    ]);
  });

  testWidgets('small portrait preview fits its available sample cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(
      () => PlaybackPrefs().setPosterPortraitSize(PosterCardSize.small),
    );
    await tester.pumpWidget(
      const MaterialApp(home: PosterCardSettingsScreen()),
    );

    expect(tester.takeException(), isNull);
    final previews = find.byType(PosterCard);
    expect(previews, findsNWidgets(3));
    expect(tester.getSize(previews.first).width, closeTo(73, 0.1));
  });

  testWidgets('Interface exposes poster controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PosterCardScope(child: const PosterCardSettingsScreen()),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Landscape'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Poster cards'), findsOneWidget);
    expect(find.text('Landscape'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Title placement'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Title placement'), findsOneWidget);
    expect(find.text('Title artwork'), findsOneWidget);
  });
}
