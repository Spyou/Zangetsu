import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/torrent/torrent_util.dart';

const _hash = '0123456789abcdef0123456789abcdef01234567';

void main() {
  test('valid info hash becomes an xt magnet', () {
    expect(buildTorrentMagnet(infoHash: _hash), 'magnet:?xt=urn:btih:$_hash');
    expect(
      buildTorrentMagnet(infoHash: _hash.toUpperCase()),
      'magnet:?xt=urn:btih:$_hash',
    );
  });

  test('file index is preserved, including zero', () {
    expect(buildTorrentMagnet(infoHash: _hash, fileIndex: 0), contains('so=0'));
    expect(buildTorrentMagnet(infoHash: _hash, fileIndex: 3), contains('so=3'));
    expect(buildTorrentMagnet(infoHash: _hash), isNot(contains('so=')));
  });

  test('only valid trackers are forwarded', () {
    final magnet = buildTorrentMagnet(
      infoHash: _hash,
      trackers: [
        'udp://tracker.example:1337/announce',
        'https://tracker.example/a',
        'ftp://bad.example/x',
        'not a url',
      ],
    )!;
    expect(
      magnet,
      contains(
        'tr=${Uri.encodeQueryComponent('udp://tracker.example:1337/announce')}',
      ),
    );
    expect(
      magnet,
      contains('tr=${Uri.encodeQueryComponent('https://tracker.example/a')}'),
    );
    expect(magnet, isNot(contains('ftp')));
  });

  test('malformed hashes and negative indexes are rejected', () {
    expect(buildTorrentMagnet(infoHash: 'nope'), isNull);
    expect(buildTorrentMagnet(infoHash: _hash, fileIndex: -1), isNull);
  });

  test('existing torrent detection is unchanged', () {
    expect(isTorrentUrl(buildTorrentMagnet(infoHash: _hash)!), isTrue);
    expect(isTorrentUrl('https://x/a.torrent'), isTrue);
    expect(isTorrentUrl('https://x/a.m3u8'), isFalse);
  });
}
