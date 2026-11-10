import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';

void main() {
  group('StremioRef', () {
    test('round-trips custom item and video ids', () {
      const ref = StremioRef(
        installationId: 'stremio_1',
        type: 'series',
        itemId: 'custom:season/one?part=2',
        videoId: 'custom:season/one?part=2:1:1',
      );
      final decoded = StremioRef.parse(ref.encode());
      expect(decoded, ref);
    });

    test('request id prefers the selected video', () {
      const ref = StremioRef(
        installationId: 'i',
        type: 'series',
        itemId: 'tt1',
        videoId: 'tt1:1:2',
      );
      expect(ref.requestId, 'tt1:1:2');
      expect(ref.withVideo(null).requestId, 'tt1');
    });

    test('encoded ref carries no addon URL or token', () {
      const ref = StremioRef(installationId: 'i', type: 'movie', itemId: 'tt1');
      final encoded = ref.encode();
      expect(encoded, isNot(contains('https')));
      expect(encoded, isNot(contains('token')));
      expect(StremioRef.isRef(encoded), isTrue);
    });

    test('rejects foreign and incomplete refs', () {
      expect(() => StremioRef.parse('https://x'), throwsFormatException);
      expect(
        () => StremioRef.parse('stremio://ref?v=1&i=x&t=movie'),
        throwsFormatException,
      );
      expect(
        () => StremioRef.parse('stremio://ref?v=9&i=x&t=movie&m=1'),
        throwsFormatException,
      );
    });
  });

  group('saved identity', () {
    test('one external title from two addons shares a saved id', () {
      final a = stremioMediaId(
        type: 'series',
        itemId: 'tt0944947',
        installationId: 'a',
      );
      final b = stremioMediaId(
        type: 'series',
        itemId: 'tt0944947',
        installationId: 'b',
      );
      expect(a, b);
      expect(a, 'series:tt0944947');
    });

    test('type and namespace keep collisions apart', () {
      expect(
        stremioMediaId(type: 'movie', itemId: 'tmdb:1', installationId: 'a'),
        isNot(
          stremioMediaId(type: 'series', itemId: 'tmdb:1', installationId: 'a'),
        ),
      );
      expect(isVerifiedStremioId('tmdb:1'), isTrue);
      expect(isVerifiedStremioId('kitsu:1'), isTrue);
      expect(isVerifiedStremioId('mal:1'), isTrue);
      expect(isVerifiedStremioId('title-1'), isFalse);
    });

    test('custom ids stay scoped to their installation', () {
      final a = stremioMediaId(
        type: 'movie',
        itemId: 'local:7',
        installationId: 'a',
      );
      final b = stremioMediaId(
        type: 'movie',
        itemId: 'local:7',
        installationId: 'b',
      );
      expect(a, isNot(b));
      expect(a, 'movie:a:local:7');
    });

    test('episode ids merge only for verified titles', () {
      expect(
        stremioEpisodeId(
          itemId: 'tt0944947',
          videoId: 'tt0944947:1:1',
          installationId: 'a',
        ),
        stremioEpisodeId(
          itemId: 'tt0944947',
          videoId: 'tt0944947:1:1',
          installationId: 'b',
        ),
      );
      expect(
        stremioEpisodeId(
          itemId: 'local:7',
          videoId: 'local:7:1:1',
          installationId: 'a',
        ),
        isNot(
          stremioEpisodeId(
            itemId: 'local:7',
            videoId: 'local:7:1:1',
            installationId: 'b',
          ),
        ),
      );
    });

    test('movie type detection accepts film spellings', () {
      expect(isStremioMovieType('movie'), isTrue);
      expect(isStremioMovieType('Movies'), isTrue);
      expect(isStremioMovieType('film'), isTrue);
      expect(isStremioMovieType('series'), isFalse);
      expect(isStremioMovieType('anime'), isFalse);
    });
  });
}
