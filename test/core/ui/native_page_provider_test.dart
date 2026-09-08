// Some extensions serve their chapter pages deliberately scrambled and put the
// descrambler on their own OkHttp client. Fetching the url from Dart never runs
// that interceptor, so the reader drew the raw scrambled bytes and the page came
// out looking torn into squares.
//
// The bridge marks exactly those pages with the same internal header covers
// already use. This pins WHICH pages get diverted — the cost of getting it wrong
// in either direction is real: divert nothing and scrambled sources stay broken,
// divert everything and every chapter loses Flutter's image cache.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_image_provider.dart';
import 'package:watch_app/core/mihon/mihon_image_provider.dart';
import 'package:watch_app/core/ui/native_page_provider.dart';

void main() {
  const url = 'https://example.test/chapter/1.jpg';

  group('nativePageProvider', () {
    test('an ordinary page is not diverted', () {
      // The common case by far. Returning null is what keeps every working
      // source on the cached path.
      expect(nativePageProvider(url, null), isNull);
      expect(nativePageProvider(url, const {}), isNull);
      expect(
        nativePageProvider(url, const {'Referer': 'https://example.test/'}),
        isNull,
      );
    });

    test('a marked Mihon page goes to that source native fetch', () {
      final p = nativePageProvider(url, const {'x-mihon-src': '42'});
      expect(p, isA<MihonImage>());
    });

    test('a marked Aniyomi page does too', () {
      final p = nativePageProvider(url, const {'x-ani-src': '7'});
      expect(p, isA<AniyomiImage>());
    });

    test('the marker carries the source id through, not just a flag', () {
      // The native side needs the id to pick the right source's client; a
      // truthy-but-wrong id would fetch through someone else's interceptors.
      final p = nativePageProvider(url, const {'x-mihon-src': '42'});
      expect((p! as MihonImage).sourceId, 42);
    });

    test('a marker that is not a number is ignored rather than crashing', () {
      // Headers arrive over a platform channel; a malformed one must degrade to
      // the normal path, not take the reader down mid-chapter.
      expect(nativePageProvider(url, const {'x-mihon-src': 'abc'}), isNull);
      expect(nativePageProvider(url, const {'x-ani-src': ''}), isNull);
    });
  });
}
