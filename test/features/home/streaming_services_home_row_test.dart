import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_row.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/cubit/home_rows_composer.dart';

void main() {
  // TMDB and Simkl share ZKind.movie, so the kind alone cannot tell them
  // apart — only the layout key can. Gating on the kind put the rail on the
  // Simkl home, where every logo opened an empty grid because Simkl's
  // catalogue cannot answer a `wp:` row.
  group('which layouts get the rail', () {
    test('TMDB yes, Simkl no', () {
      expect(streamingRailForLayout('tmdb::movie'), isTrue);
      expect(streamingRailForLayout('tmdb::tv'), isTrue);
      expect(streamingRailForLayout('simkl::movie'), isFalse);
      expect(streamingRailForLayout('simkl::tv'), isFalse);
    });

    test('reading layouts and source-backed homes never get it', () {
      expect(streamingRailForLayout('anilist::anime'), isFalse);
      expect(streamingRailForLayout('mal::manga'), isFalse);
      expect(streamingRailForLayout('source:ani:12'), isFalse);
    });

    test('the key the app actually builds for TMDB is the one that matches',
        () {
      final key = layoutKeyFor(
        sourceId: '',
        zModeOn: true,
        browseKind: ZKind.movie,
      );
      expect(streamingRailForLayout(key), isTrue);

      final simkl = layoutKeyFor(
        sourceId: '',
        zModeOn: true,
        browseKind: ZKind.movie,
        simklPreferred: true,
      );
      expect(streamingRailForLayout(simkl), isFalse);
    });
  });

  test('offered and shipped ON when the layout takes it', () {
    final ids = availableRowIds(
      const [],
      withTrackerRows: false,
      kind: ZKind.movie,
      withStreamingRail: true,
    );
    expect(ids, contains(streamingServicesRowId));

    final def = defaultLayout(
      const [],
      withTrackerRows: false,
      kind: ZKind.movie,
      withStreamingRail: true,
    );
    expect(def, contains(streamingServicesRowId),
        reason: 'visible: a hidden id would carry a ! prefix');
  });

  test('absent when the layout does not take it', () {
    expect(
      availableRowIds(const [], withTrackerRows: true, kind: ZKind.movie),
      isNot(contains(streamingServicesRowId)),
      reason: 'defaults to off, so a new caller cannot leak it onto Simkl',
    );
  });

  test('a visible entry merges into a StreamingServicesHomeRow', () {
    final rows = mergeHomeRows(
      layout: const [HomeRowEntry(streamingServicesRowId, false)],
      rowSections: const [],
      trackerRows: const [],
    );
    expect(rows.single, isA<StreamingServicesHomeRow>());
    expect(rows.single.id, streamingServicesRowId);
  });

  test('hiding it in the editor removes it from Home', () {
    final rows = mergeHomeRows(
      layout: const [HomeRowEntry(streamingServicesRowId, true)],
      rowSections: const [],
      trackerRows: const [],
    );
    expect(rows, isEmpty);
  });

  test('a saved Simkl layout that names it drops the id', () {
    final layout = sanitizeLayout(
      [streamingServicesRowId, localContinueRowId],
      availableRowIds(const [], withTrackerRows: false, kind: ZKind.movie),
    );
    expect(layout.map((e) => e.id), isNot(contains(streamingServicesRowId)));
  });
}
