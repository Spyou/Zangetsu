import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/detail/detail_screen.dart';
import 'package:watch_app/features/detail/title_search_popup.dart';

void main() {
  test(
    'Stremio Search stays in addons while Search all sources stays explicit',
    () {
      for (final choice in TitleSearchChoice.values) {
        final screen = detailTitleSearchScreen(
          title: 'Nimona',
          sourceId: 'stremio',
          choice: choice,
        );
        expect(screen.initialQuery, 'Nimona');
        expect(
          screen.fixedSourceId,
          choice == TitleSearchChoice.search ? 'stremio' : null,
        );
        expect(screen.forceSources, choice == TitleSearchChoice.searchAll);
      }
    },
  );

  test('other title searches retain normal and all-sources behavior', () {
    for (final sourceId in [
      'zm',
      'cs:source',
      'ani:1',
      'mihon:1',
      'lnr:1',
      'mangayomi:1',
    ]) {
      for (final choice in TitleSearchChoice.values) {
        final screen = detailTitleSearchScreen(
          title: 'Title',
          sourceId: sourceId,
          choice: choice,
        );
        expect(screen.initialQuery, 'Title');
        expect(screen.fixedSourceId, isNull, reason: sourceId);
        expect(screen.forceSources, choice == TitleSearchChoice.searchAll);
      }
    }
  });
}
