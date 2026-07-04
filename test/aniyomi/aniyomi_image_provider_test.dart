import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_image_provider.dart';

void main() {
  group('AniyomiImage equality and keying', () {
    const url = 'https://i.animepahe.pw/covers/example.jpg';
    const id = 8272;

    test('two instances with same sourceId+url are equal', () {
      const a = AniyomiImage(id, url);
      const b = AniyomiImage(id, url);
      expect(a, equals(b));
    });

    test('different sourceId → not equal', () {
      const a = AniyomiImage(id, url);
      const b = AniyomiImage(9999, url);
      expect(a, isNot(equals(b)));
    });

    test('different url → not equal', () {
      const a = AniyomiImage(id, url);
      const b = AniyomiImage(id, 'https://i.animepahe.pw/other.jpg');
      expect(a, isNot(equals(b)));
    });

    test('hashCode is equal for equal instances', () {
      const a = AniyomiImage(id, url);
      const b = AniyomiImage(id, url);
      expect(a.hashCode, equals(b.hashCode));
    });

    test('hashCode differs for different instances (most cases)', () {
      const a = AniyomiImage(id, url);
      const b = AniyomiImage(9999, url);
      // Not a guarantee but almost certain for these inputs
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });

    test('can be used as a Map key (deduplication)', () {
      final seen = <AniyomiImage, int>{};
      seen[const AniyomiImage(id, url)] = 1;
      seen[const AniyomiImage(id, url)] = 2; // should overwrite
      expect(seen.length, 1);
      expect(seen[const AniyomiImage(id, url)], 2);
    });

    test('toString contains sourceId and url', () {
      const a = AniyomiImage(id, url);
      final s = a.toString();
      expect(s, contains('$id'));
      expect(s, contains(url));
    });
  });
}
