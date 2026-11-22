import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mangayomi/mangayomi_source_id.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

void main() {
  test(
    'reads the declared Mangayomi content type from a stable source key',
    () {
      expect(
        mangayomiContentTypeOf('mg:repo:0:0:17'),
        MangayomiContentType.manga,
      );
      expect(
        mangayomiContentTypeOf('mg:repo:1:1:23'),
        MangayomiContentType.video,
      );
      expect(
        mangayomiContentTypeOf('mg:repo:1:1:-228451656'),
        MangayomiContentType.video,
      );
      expect(
        mangayomiContentTypeOf('mg:repo:2:0:31'),
        MangayomiContentType.novel,
      );
    },
  );

  test('does not classify unrelated or malformed source ids', () {
    expect(mangayomiContentTypeOf('mihon:17'), isNull);
    expect(mangayomiContentTypeOf('mg:repo:9:0:17'), isNull);
    expect(mangayomiContentTypeOf('mg:repo:0'), isNull);
  });

  test('matches each source only to its declared content mode', () {
    expect(
      sourceIdMatchesContentMode('mg:repo:0:0:17', ContentMode.manga),
      isTrue,
    );
    expect(
      sourceIdMatchesContentMode('mg:repo:0:0:17', ContentMode.anime),
      isFalse,
    );
    expect(
      sourceIdMatchesContentMode('mg:repo:1:1:23', ContentMode.anime),
      isTrue,
    );
    expect(
      sourceIdMatchesContentMode('mg:repo:2:0:31', ContentMode.novel),
      isTrue,
    );
    expect(sourceIdMatchesContentMode('mihon:17', ContentMode.manga), isTrue);
    expect(sourceIdMatchesContentMode('lnr:17', ContentMode.novel), isTrue);
    expect(sourceIdMatchesContentMode('legacy-js', ContentMode.anime), isTrue);
  });
}
