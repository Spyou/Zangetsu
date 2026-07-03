import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/torrent/torrent_download_service.dart';

void main() {
  test('TorrentDownloadProgress.fromMap maps fields', () {
    final p = TorrentDownloadProgress.fromMap({
      'id': 'x',
      'status': 'downloading',
      'progress': 0.5,
      'peers': 12,
      'downSpeedBps': 999,
      'filePath': 'content://x',
      'error': null,
    });
    expect(p.id, 'x');
    expect(p.status, 'downloading');
    expect(p.progress, 0.5);
    expect(p.peers, 12);
    expect(p.downSpeedBps, 999);
    expect(p.filePath, 'content://x');
  });

  test('TorrentDownloadProgress.fromMap uses safe defaults for missing fields', () {
    final p = TorrentDownloadProgress.fromMap({'id': 'y', 'status': 'queued'});
    expect(p.progress, 0.0);
    expect(p.peers, 0);
    expect(p.downSpeedBps, 0);
    expect(p.filePath, isNull);
  });
}
