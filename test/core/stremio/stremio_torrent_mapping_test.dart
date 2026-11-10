import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/stremio/stremio_link_session.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:watch_app/core/stremio/stremio_stream_mapping.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _hash = '0123456789abcdef0123456789abcdef01234567';
const _ref = StremioRef(
  installationId: 'addon-a',
  type: 'series',
  itemId: 'tt1',
  videoId: 'tt1:1:1',
);

StremioLinkChoice _choice(StremioStream stream) => StremioLinkChoice(
  installationId: 'addon-a',
  ref: _ref,
  stream: stream,
  label: 'Torrent',
);

void main() {
  test('torrent choice becomes a magnet with the exact file index', () {
    final source = stremioVideoSource(
      _choice(
        const StremioStream(
          kind: StremioStreamKind.torrent,
          infoHash: _hash,
          fileIndex: 0,
          name: '1080p',
          description: '42 seeders',
          trackers: ['udp://tracker.example:1337/announce'],
        ),
      ),
    )!;
    expect(source.url, contains('xt=urn:btih:$_hash'));
    expect(source.url, contains('so=0'));
    expect(source.url, contains('tr='));
    expect(source.container, SourceContainer.torrent);
    expect(source.torrentFileIndex, 0);
    expect(source.quality, '1080p');
    expect(source.label, 'Torrent');
  });

  test('TV preserves the choice but hides torrents from selection', () {
    final choice = _choice(
      const StremioStream(
        kind: StremioStreamKind.torrent,
        infoHash: _hash,
        fileIndex: 3,
      ),
    );
    expect(stremioVideoSource(choice, allowTorrent: false), isNull);
    expect(stremioVideoSource(choice)!.torrentFileIndex, 3);
  });

  test('invalid hashes never become playable sources', () {
    expect(
      stremioVideoSource(
        _choice(
          const StremioStream(
            kind: StremioStreamKind.torrent,
            infoHash: 'bad',
            fileIndex: 1,
          ),
        ),
      ),
      isNull,
    );
  });
}
