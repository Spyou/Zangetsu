import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/features/home/tv_search_input_screen.dart';

void main() {
  test(
    'TV keyboard preference survives reopening the settings store',
    () async {
      final dir = await Directory.systemTemp.createTemp('tv-keyboard-prefs-');
      Hive.init(dir.path);
      await SearchPrefs.init();
      final prefs = SearchPrefs();
      // New is the default for a fresh install.
      expect(prefs.tvSearchStyle, 'new');
      // An explicit opt-out from the earlier test build stays Classic.
      await Hive.box(SearchPrefs.boxName).put('youtubeTvKeyboard', false);
      expect(prefs.tvSearchStyle, 'classic');
      await Hive.box(SearchPrefs.boxName).put('youtubeTvKeyboard', true);
      expect(prefs.tvSearchStyle, 'new');
      await prefs.setTvSearchStyle('new');
      await Hive.close();
      await SearchPrefs.init();
      expect(SearchPrefs().tvSearchStyle, 'new');
      await SearchPrefs().setTvSearchStyle('classic');
      await Hive.close();
      await SearchPrefs.init();
      expect(SearchPrefs().tvSearchStyle, 'classic');
      await Hive.close();
      await dir.delete(recursive: true);
    },
  );

  testWidgets(
    'alphabetical keyboard switches symbols, case and retains input',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TvSearchInputScreen(
            initialQuery: '',
            compactStyle: true,
            inlineSearch: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-key-q')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-search-draft'))).data,
        'A',
      );
      await tester.tap(find.byKey(const ValueKey('tv-key-symbols')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tv-key-1')));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-search-draft'))).data,
        'A1',
      );
      await tester.tap(find.byKey(const ValueKey('tv-key-case')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tv-key-B')));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-search-draft'))).data,
        'A1B',
      );
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const ValueKey('tv-search-back-hint')), findsNothing);
    },
  );

  testWidgets('New capitalizes only the first letter and allows manual case', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TvSearchInputScreen(
          initialQuery: '',
          compactStyle: true,
          inlineSearch: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in ['S', 'O', 'L']) {
      await tester.tap(find.byKey(ValueKey('tv-key-$key')));
      await tester.pumpAndSettle();
    }
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tv-search-draft'))).data,
      'Sol',
    );
    await tester.tap(find.byKey(const ValueKey('tv-key-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-key-T')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tv-search-draft'))).data,
      'T',
    );
    await tester.tap(find.byKey(const ValueKey('tv-key-case')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-key-A')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-key-N')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tv-search-draft'))).data,
      'TAN',
    );
  });

  testWidgets('render TV keyboard preview without overflow', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final loader = FontLoader('PreviewSans')
        ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'PreviewSans',
            ),
          ),
          home: TvSearchInputScreen(
            initialQuery: 'SOL',
            loadRecommendations: (_) async => const [
              MediaItem(
                id: 'solo',
                title: 'Solo Leveling',
                url: '/solo',
                type: ProviderType.anime,
                sourceId: 'metadata',
              ),
              MediaItem(
                id: 'solanin',
                title: 'Solanin',
                url: '/solanin',
                type: ProviderType.anime,
                sourceId: 'metadata',
              ),
              MediaItem(
                id: 'sol2',
                title: 'Solo Leveling Season 2',
                url: '/solo2',
                type: ProviderType.anime,
                sourceId: 'metadata',
              ),
            ],
            compactStyle: true,
            recentQueries: [
              'Solo Leveling',
              'One Piece',
              'Attack on Titan',
              'Demon Slayer',
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(data, isNotNull);
      image.dispose();
    });
  });
  testWidgets('number switch stays on one line on a 960dp TV', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: TvSearchInputScreen(
          initialQuery: '',
          compactStyle: true,
          inlineSearch: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(find.text('&123'));
    expect(
      paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
}
