import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';

void main() {
  DownloadRecord base() => const DownloadRecord(
    id: 'a',
    sourceId: 's',
    showId: 'sh',
    showTitle: 'T',
    showUrl: 'u',
    episodeId: 'e',
    episodeUrl: 'eu',
    episodeTitle: 'E1',
    category: 'sub',
    quality: '1080p',
    createdAt: 0,
  );

  test('isTorrent defaults to false and round-trips through the map', () {
    final rec = base();
    expect(rec.isTorrent, false);

    final t = rec.copyWith(isTorrent: true);
    expect(t.isTorrent, true);

    // Round-trips both ways.
    expect(DownloadRecord.fromMap(t.toMap()).isTorrent, true);
    expect(DownloadRecord.fromMap(rec.toMap()).isTorrent, false);
  });
}
