// The sheet lists both settings, and puts the one matching where you are on
// top. The trap is that there is no movies tab: ContentMode.anime is
// "Streaming" and carries anime, movies and series together, so the mode alone
// cannot answer which that is — StreamKind decides between them.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/metadata_switch_sheet.dart';

class _RouteObserver extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  group('metadataAxisFor', () {
    test('Streaming on anime leads with AniList/MyAnimeList', () {
      expect(
        metadataAxisFor(ContentMode.anime, StreamKind.anime),
        MetadataAxis.anime,
      );
    });

    test('Streaming switched to movies leads with TMDB/Simkl', () {
      expect(
        metadataAxisFor(ContentMode.anime, StreamKind.movie),
        MetadataAxis.video,
      );
    });

    // Reading modes have no movie/TV metadata to switch, so the streaming kind
    // left over from the last video session must not leak into them.
    test(
      'Manga leads with the anime setting whatever the streaming kind is',
      () {
        expect(
          metadataAxisFor(ContentMode.manga, StreamKind.movie),
          MetadataAxis.anime,
        );
        expect(
          metadataAxisFor(ContentMode.manga, StreamKind.anime),
          MetadataAxis.anime,
        );
      },
    );

    test('so does Novel', () {
      expect(
        metadataAxisFor(ContentMode.novel, StreamKind.movie),
        MetadataAxis.anime,
      );
      expect(
        metadataAxisFor(ContentMode.novel, StreamKind.anime),
        MetadataAxis.anime,
      );
    });
  });

  group('the sheet writes the same setting Settings writes', () {
    test('AnimeProvider and VideoProvider each carry exactly two choices', () {
      // The sheet renders one row per enum value. A third would silently
      // appear in it with no label of its own.
      expect(AnimeProvider.values, [AnimeProvider.anilist, AnimeProvider.mal]);
      expect(VideoProvider.values, [VideoProvider.tmdb, VideoProvider.simkl]);
    });
  });

  group('source catalogue selection stays on Home', () {
    late Directory tempDir;
    late ActiveSourceCubit activeSource;
    late ContentModeCubit contentMode;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'metadata_switch_sheet_test',
      );
      Hive.init(tempDir.path);
      await ZModePrefs.init();
      activeSource = ActiveSourceCubit(fallback: 'source-a');
      contentMode = await ContentModeCubit.create(activeSource);
      sl.registerSingleton<ActiveSourceCubit>(activeSource);
      sl.registerSingleton<ContentModeCubit>(contentMode);
      sl.registerSingleton<MetadataProviderPrefs>(
        await MetadataProviderPrefs.open(),
      );
    });

    tearDown(() async {
      await sl.reset();
      await contentMode.close();
      await activeSource.close();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('returns source mode without pushing another page', (
      tester,
    ) async {
      final observer = _RouteObserver();
      HomeCatalogueSelection? selection;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  selection = await showMetadataSwitchSheet(context);
                },
                child: const Text('Choose catalogue'),
              ),
            ),
          ),
        ),
      );

      final materialPagesBefore = observer.pushed
          .whereType<MaterialPageRoute<void>>()
          .length;
      await tester.tap(find.text('Choose catalogue'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Source Catalogue'));
      await tester.tap(find.text('Source Catalogue'));
      await tester.pumpAndSettle();

      expect(selection, HomeCatalogueSelection.source);
      expect(
        observer.pushed.whereType<MaterialPageRoute<void>>().length,
        materialPagesBefore,
      );
    });

    testWidgets('source mode does not mark saved metadata choices active', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showMetadataSwitchSheet(
                  context,
                  sourceCatalogueSelected: true,
                ),
                child: const Text('Choose catalogue'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Choose catalogue'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('source switch can return Home to metadata mode', (
      tester,
    ) async {
      HomeCatalogueSelection? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  selection = await showMetadataSwitchSheet(
                    context,
                    sourceCatalogueSelected: true,
                  );
                },
                child: const Text('Choose catalogue'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Choose catalogue'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(selection, HomeCatalogueSelection.metadata);
    });
  });
}
