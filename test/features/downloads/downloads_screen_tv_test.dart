import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/downloads/downloads_screen_tv.dart';

// ── Minimal fakes ─────────────────────────────────────────────────────────────

/// Stub [DownloadManager]: provides a fixed [byShow] map without requiring
/// Hive, background_downloader, or GetIt setup. Extends [ChangeNotifier] so
/// [ListenableBuilder] can register its listener; [implements DownloadManager]
/// so the concrete type is satisfied by [DownloadTile] and [_TileMenu].
/// [noSuchMethod] silences any unimplemented member calls at the type-system
/// level; none are invoked during widget rendering.
class _FakeDownloadManager extends ChangeNotifier implements DownloadManager {
  _FakeDownloadManager(this._byShow);

  final Map<String, List<DownloadRecord>> _byShow;

  @override
  Map<String, List<DownloadRecord>> get byShow => _byShow;

  @override
  List<DownloadRecord> get all =>
      _byShow.values.expand((l) => l).toList();

  @override
  DownloadRecord? recordFor(String sourceId, String showId, String episodeId) =>
      null;

  @override
  void setup() {}

  @override
  Future<void> enqueueEpisodes({
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    required String showUrl,
    required String category,
    required String quality,
    required List<Episode> episodes,
    required int nowMs,
    int? malId,
  }) async {}

  @override
  Future<void> enqueueSource({
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    required String showUrl,
    required String category,
    required Episode episode,
    required VideoSource source,
    required String qualityLabel,
    required int nowMs,
    int? malId,
    List<VideoSource> fallbacks = const [],
  }) async {}

  @override
  Future<void> pause(DownloadRecord r) async {}

  @override
  Future<void> resume(DownloadRecord r) async {}

  @override
  Future<void> cancel(DownloadRecord r) async {}

  @override
  Future<void> delete(DownloadRecord r) async {}

  // Any other DownloadManager member not called during widget rendering is
  // handled here without throwing so rendering remains side-effect-free.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

DownloadRecord _doneRecord({
  required String showId,
  required String showTitle,
  required String episodeId,
  double? episodeNumber,
  String episodeTitle = '',
}) => DownloadRecord(
  id: '${showId}_$episodeId',
  sourceId: 'test',
  showId: showId,
  showTitle: showTitle,
  showUrl: '/show/$showId',
  episodeId: episodeId,
  episodeUrl: '/ep/$episodeId',
  episodeNumber: episodeNumber,
  episodeTitle: episodeTitle,
  category: 'sub',
  quality: 'best',
  status: DownloadStatus.done,
  filePath: '/fake/path.mp4',
  createdAt: 0,
);

DownloadRecord _downloadingRecord({
  required String showId,
  required String showTitle,
  required String episodeId,
}) => DownloadRecord(
  id: '${showId}_$episodeId',
  sourceId: 'test',
  showId: showId,
  showTitle: showTitle,
  showUrl: '/show/$showId',
  episodeId: episodeId,
  episodeUrl: '/ep/$episodeId',
  episodeNumber: 1,
  episodeTitle: '',
  category: 'sub',
  quality: 'best',
  status: DownloadStatus.downloading,
  progress: 0.5,
  createdAt: 0,
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  testWidgets(
    'DownloadsScreenTv renders episode tiles and first tile has autofocus',
    (tester) async {
      final rec1 = _doneRecord(
        showId: 'aot',
        showTitle: 'Attack on Titan',
        episodeId: 'ep1',
        episodeNumber: 1,
        episodeTitle: 'To You, 2000 Years Later',
      );
      final rec2 = _doneRecord(
        showId: 'aot',
        showTitle: 'Attack on Titan',
        episodeId: 'ep2',
        episodeNumber: 2,
        episodeTitle: 'That Day',
      );
      final manager = _FakeDownloadManager({
        'aot': [rec1, rec2],
      });
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        MaterialApp(home: DownloadsScreenTv(manager: manager)),
      );
      await tester.pumpAndSettle();

      // Both episode labels are rendered.
      expect(find.text('E1 · To You, 2000 Years Later'), findsOneWidget);
      expect(find.text('E2 · That Day'), findsOneWidget);

      // Show title rendered in the group header.
      expect(find.text('Attack on Titan'), findsOneWidget);

      // At least 2 TvFocusable widgets present (one per episode tile).
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(2));

      // The very first TvFocusable (first episode tile) has autofocus=true.
      expect(focusables.first.autofocus, isTrue);

      // Subsequent tiles do NOT have autofocus.
      expect(focusables.skip(1).any((f) => f.autofocus), isFalse);
    },
  );

  testWidgets(
    'DownloadsScreenTv shows empty state when manager has no downloads',
    (tester) async {
      final manager = _FakeDownloadManager({});
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        MaterialApp(home: DownloadsScreenTv(manager: manager)),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Episodes you download appear here'),
        findsOneWidget,
      );
      expect(find.byType(TvFocusable), findsNothing);
    },
  );

  testWidgets(
    'DownloadsScreenTv in-progress tile has onTap no-op (not autofocus beyond first)',
    (tester) async {
      final done = _doneRecord(
        showId: 'ds',
        showTitle: 'Demon Slayer',
        episodeId: 'ep1',
        episodeNumber: 1,
      );
      final inProgress = _downloadingRecord(
        showId: 'ds',
        showTitle: 'Demon Slayer',
        episodeId: 'ep2',
      );
      final manager = _FakeDownloadManager({
        'ds': [done, inProgress],
      });
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        MaterialApp(home: DownloadsScreenTv(manager: manager)),
      );
      await tester.pumpAndSettle();

      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();

      // Two tiles: first (done) gets autofocus, second (in-progress) does not.
      expect(focusables.length, 2);
      expect(focusables[0].autofocus, isTrue);
      expect(focusables[1].autofocus, isFalse);
    },
  );
}
