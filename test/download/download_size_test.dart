import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_size');
  });

  tearDown(() async => dir.delete(recursive: true));

  group('sizeOf', () {
    test('reports the real length of a finished file', () async {
      // The bug: bytesTotal was only ever set from background_downloader's
      // expectedFileSize, and HLS never goes through it — so every HLS download
      // finished at 0 B and the storage total under-counted every anime source.
      final f = File('${dir.path}/ep.mp4');
      await f.writeAsBytes(List.filled(4096, 0));
      expect(await DownloadManager.sizeOf(f.path), 4096);
    });

    test('returns null rather than 0 for anything it cannot measure', () async {
      // null means "keep what's recorded" — returning 0 would clobber a size
      // the download path already knew.
      expect(await DownloadManager.sizeOf(null), isNull);
      expect(await DownloadManager.sizeOf(''), isNull);
      expect(await DownloadManager.sizeOf('${dir.path}/missing.mp4'), isNull);

      final empty = File('${dir.path}/empty.mp4');
      await empty.create();
      expect(await DownloadManager.sizeOf(empty.path), isNull);
    });

    test('a SAF content:// path is left alone, not stat-ed', () async {
      // File() can't open one, and guessing 0 would wipe a real size.
      expect(
        await DownloadManager.sizeOf('content://com.android.x/tree/1'),
        isNull,
      );
    });
  });

  group('supersededPath survives a restart', () {
    const base = DownloadRecord(
      id: 'a',
      sourceId: 's',
      showId: 'sh',
      showTitle: 'Show',
      showUrl: 'https://x/show',
      episodeId: 'e1',
      episodeUrl: 'https://x/e1',
      episodeTitle: 'Episode 1',
      category: 'sub',
      quality: '1080p',
      createdAt: 0,
    );

    test('round-trips through the box', () {
      // The whole point: held in memory it was lost when the app died mid
      // re-download, and the replaced file was stranded for good.
      final rec = base.copyWith(supersededPath: () => '/old/ep.mp4');
      final back = DownloadRecord.fromMap(rec.toMap());
      expect(back.supersededPath, '/old/ep.mp4');
    });

    test('a record written before this field existed still loads', () {
      final old = base.toMap()..remove('supersededPath');
      expect(DownloadRecord.fromMap(old).supersededPath, isNull);
    });

    test('copyWith can clear it, and leaves it alone when not asked', () {
      final rec = base.copyWith(supersededPath: () => '/old/ep.mp4');
      expect(rec.copyWith(progress: 1).supersededPath, '/old/ep.mp4');
      expect(rec.copyWith(supersededPath: () => null).supersededPath, isNull);
    });
  });

  group('record size bookkeeping', () {
    test('a null bytesTotal keeps whatever was already known', () {
      // _markDone passes null when the size is already set, so this is the
      // guarantee that a known size is never overwritten.
      const rec = DownloadRecord(
        id: 'a',
        sourceId: 's',
        showId: 'sh',
        showTitle: 'Show',
        showUrl: 'https://x/show',
        episodeId: 'e1',
        episodeUrl: 'https://x/e1',
        episodeTitle: 'Episode 1',
        category: 'sub',
        quality: '1080p',
        createdAt: 0,
        bytesTotal: 1234,
      );
      expect(rec.copyWith(bytesTotal: null).bytesTotal, 1234);
      expect(rec.copyWith(bytesTotal: 99).bytesTotal, 99);
    });
  });
}
