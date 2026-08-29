// Task E2: the search filter sheet's "search in these sources" list
// (_SearchFilterSheet in search_screen.dart) hardcoded its `sections` to
// buckets.anime/.movies/.nsfw only, so a reading mode's own bucket
// (buckets.manga/.novel) was never included — the sheet showed the bare "No
// sources installed" text even when reading sources WERE installed. And the
// "no sources" text itself was a plain Text with no install action.
//
// searchFilterSections/SearchSourcesEmptyView are pulled out as their own
// top-level function + widget (same pattern as home_screen.dart's readerFor
// and HomeLoadedEmptyView) so they're testable without pumping the full
// _SearchFilterSheet, which needs a real SearchBloc/SourceRepository.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/ui/source_switcher.dart';
import 'package:watch_app/features/home/search_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

SourceBuckets _buckets({
  List<({String id, String label, String? repo})> anime = const [],
  List<({String id, String label, String? repo})> movies = const [],
  List<({String id, String label, String? repo})> nsfw = const [],
  List<({String id, String label, String? repo})> manga = const [],
  List<({String id, String label, String? repo})> novel = const [],
}) => (anime: anime, movies: movies, nsfw: nsfw, manga: manga, novel: novel);

const _row = (id: 'js:x', label: 'X', repo: null);

AppLocalizations get _l10n =>
    lookupAppLocalizations(const Locale('en'));

void main() {
  group('searchFilterSections — anime mode regression', () {
    test('empty buckets → no sections (identical to the original literal)', () {
      expect(searchFilterSections(_buckets(), ContentMode.anime, _l10n), isEmpty);
    });

    test(
      'anime/movies/nsfw each become their own category, in order, exactly '
      'like the original hardcoded literal — reading buckets never leak in',
      () {
        final buckets = _buckets(
          anime: [_row],
          movies: [_row],
          nsfw: [_row],
          manga: [_row],
          novel: [_row],
        );
        final sections = searchFilterSections(buckets, ContentMode.anime, _l10n);
        expect(sections.map((s) => s.title).toList(), [
          'Anime',
          'Movies & Series',
          'NSFW',
        ]);
      },
    );
  });

  group('searchFilterSections — reading modes', () {
    test('manga mode with nothing installed → no sections', () {
      expect(searchFilterSections(_buckets(), ContentMode.manga, _l10n), isEmpty);
    });

    test('manga mode with a manga source installed → a single Manga section, '
        'never Anime/Movies/NSFW even if those buckets are non-empty', () {
      final buckets = _buckets(
        manga: [_row],
        anime: [_row],
        movies: [_row],
        nsfw: [_row],
      );
      final sections = searchFilterSections(buckets, ContentMode.manga, _l10n);
      expect(sections.map((s) => s.title).toList(), ['Manga']);
      expect(sections.single.rows, [_row]);
    });

    test(
      'novel mode with a novel source installed → a single Novel section',
      () {
        final buckets = _buckets(novel: [_row]);
        final sections = searchFilterSections(buckets, ContentMode.novel, _l10n);
        expect(sections.map((s) => s.title).toList(), ['Novel']);
      },
    );
  });

  group(
    'searchTypeAudioGroupsVisible — Type/Audio are anime-only concepts',
    () {
      // Both used to render unconditionally, so in manga/novel mode every
      // option (SearchContentFilter only distinguishes anime vs movie;
      // SearchAudioFilter keys off subCount/dubCount reading sources never set)
      // filtered out 100% of results — the exact bug this task removes.
      test('shown in anime mode', () {
        expect(searchTypeAudioGroupsVisible(ContentMode.anime), isTrue);
      });

      test('hidden in manga mode', () {
        expect(searchTypeAudioGroupsVisible(ContentMode.manga), isFalse);
      });

      test('hidden in novel mode', () {
        expect(searchTypeAudioGroupsVisible(ContentMode.novel), isFalse);
      });
    },
  );

  group('SearchSourcesEmptyView', () {
    testWidgets(
      'anime mode: renders the original bare "No sources installed" text, '
      'no button (regression)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SearchSourcesEmptyView(
                mode: ContentMode.anime,
                onInstallSources: () {},
              ),
            ),
          ),
        );

        expect(find.text('No sources installed'), findsOneWidget);
        expect(find.byType(FilledButton), findsNothing);
      },
    );

    testWidgets(
      'manga mode: reading-specific message + an install CTA that fires '
      'onInstallSources',
      (tester) async {
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SearchSourcesEmptyView(
                mode: ContentMode.manga,
                onInstallSources: () => tapped = true,
              ),
            ),
          ),
        );

        expect(find.text('No Manga sources yet'), findsOneWidget);
        expect(find.text('No sources installed'), findsNothing);
        final cta = find.widgetWithText(FilledButton, 'Browse repositories');
        expect(cta, findsOneWidget);

        await tester.tap(cta);
        expect(tapped, isTrue);
      },
    );
  });
}
