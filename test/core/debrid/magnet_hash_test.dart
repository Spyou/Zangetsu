import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/debrid/debrid_provider.dart';
import 'package:watch_app/core/debrid/magnet_hash.dart';

void main() {
  group('parseMagnetHash', () {
    test('reads 40-char hex btih, case-insensitive', () {
      expect(
        parseMagnetHash(
          'magnet:?xt=urn:btih:0123456789ABCDEFFEDCBA9876543210ABCDEF01&dn=x',
        ),
        '0123456789abcdeffedcba9876543210abcdef01',
      );
    });

    test('decodes 32-char base32 btih to hex', () {
      // 32 'A's = 20 zero bytes.
      expect(
        parseMagnetHash('magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'),
        '00' * 20,
      );
    });

    test('returns null for non-magnet and v2-only', () {
      expect(parseMagnetHash('https://x.com/file.mp4'), isNull);
      expect(
        parseMagnetHash(
          'magnet:?xt=urn:btmh:1220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        isNull,
      );
    });
  });

  test('looksLikeTorrentFileUrl', () {
    expect(looksLikeTorrentFileUrl('https://x.com/a.torrent'), isTrue);
    expect(looksLikeTorrentFileUrl('https://x.com/a.torrent?dl=1'), isTrue);
    expect(looksLikeTorrentFileUrl('magnet:?xt=urn:btih:abc'), isFalse);
    expect(looksLikeTorrentFileUrl('https://x.com/a.mp4'), isFalse);
  });

  test('infoHashFromTorrentBytes hashes the bencoded info dict', () {
    // Minimal single-file torrent. `pieces` is 20 bytes of 0x00.
    final pieces = Uint8List(20);
    final info = <int>[
      ...utf8.encode(
        'd6:lengthi1e4:name1:a12:piece lengthi16384e6:pieces20:',
      ),
      ...pieces,
      0x65, // end info dict
    ];
    final torrent = <int>[
      ...utf8.encode('d8:announce9:http://x/4:info'),
      ...info,
      0x65, // end torrent dict
    ];
    expect(infoHashFromTorrentBytes(torrent), sha1.convert(info).toString());
  });

  group('pickLargestVideo', () {
    test('picks the largest video extension, ignoring samples', () {
      final pick = pickLargestVideo([
        const DebridFile(id: '1', path: '/Sample/sample.mkv', bytes: 50),
        const DebridFile(id: '2', path: '/Show.mkv', bytes: 2000),
        const DebridFile(id: '3', path: '/Show.nfo', bytes: 12),
      ]);
      expect(pick?.id, '2');
    });

    test('falls back to largest file when nothing looks like video', () {
      final pick = pickLargestVideo([
        const DebridFile(id: '1', path: 'a.rar', bytes: 10),
        const DebridFile(id: '2', path: 'b.bin', bytes: 99),
      ]);
      expect(pick?.id, '2');
    });
  });
}
