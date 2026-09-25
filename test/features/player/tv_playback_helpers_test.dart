import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/skip_service.dart';
import 'package:watch_app/core/playback/tv_playback_helpers.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  group('kTvSpeeds', () {
    test('is the expected ordered set', () {
      expect(kTvSpeeds, [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]);
    });
  });

  group('volumeBoostToMillibels', () {
    test('100% -> 0, 200% -> 600, 150% -> 300', () {
      expect(volumeBoostToMillibels(100), 0);
      expect(volumeBoostToMillibels(200), 600);
      expect(volumeBoostToMillibels(150), 300);
    });
    test('clamps out-of-range', () {
      expect(volumeBoostToMillibels(50), 0);
      expect(volumeBoostToMillibels(300), 600);
    });
  });

  group('shouldScrobble', () {
    test('fires at/after 92% when not already scrobbled', () {
      expect(
        shouldScrobble(
          positionMs: 9200,
          durationMs: 10000,
          alreadyScrobbled: false,
        ),
        isTrue,
      );
      expect(
        shouldScrobble(
          positionMs: 9500,
          durationMs: 10000,
          alreadyScrobbled: false,
        ),
        isTrue,
      );
    });
    test('does not fire below 92%', () {
      expect(
        shouldScrobble(
          positionMs: 9100,
          durationMs: 10000,
          alreadyScrobbled: false,
        ),
        isFalse,
      );
    });
    test('does not fire when already scrobbled or duration unknown', () {
      expect(
        shouldScrobble(
          positionMs: 9900,
          durationMs: 10000,
          alreadyScrobbled: true,
        ),
        isFalse,
      );
      expect(
        shouldScrobble(positionMs: 100, durationMs: 0, alreadyScrobbled: false),
        isFalse,
      );
    });
  });

  group('activeSkipInterval', () {
    final skips = [
      SkipInterval(
        start: const Duration(seconds: 10),
        end: const Duration(seconds: 30),
        type: 'op',
      ),
      SkipInterval(
        start: const Duration(minutes: 22),
        end: const Duration(minutes: 23),
        type: 'ed',
      ),
    ];
    test('returns the interval containing the position', () {
      expect(activeSkipInterval(skips, 15000)?.type, 'op');
      expect(
        activeSkipInterval(
          skips,
          const Duration(minutes: 22, seconds: 30).inMilliseconds,
        )?.type,
        'ed',
      );
    });
    test('end is exclusive', () {
      expect(activeSkipInterval(skips, 30000), isNull); // exactly at end of op
    });
    test('returns null outside any interval and for empty', () {
      expect(activeSkipInterval(skips, 5000), isNull);
      expect(activeSkipInterval(const [], 15000), isNull);
    });
  });

  group('shouldAutoAddToMyList', () {
    test('adds when opted in, not incognito, and not already listed', () {
      expect(
        shouldAutoAddToMyList(
          autoAddEnabled: true,
          incognito: false,
          alreadyListed: false,
        ),
        isTrue,
      );
    });

    test('skips when the user turned the setting off', () {
      expect(
        shouldAutoAddToMyList(
          autoAddEnabled: false,
          incognito: false,
          alreadyListed: false,
        ),
        isFalse,
      );
    });

    test('skips in incognito', () {
      expect(
        shouldAutoAddToMyList(
          autoAddEnabled: true,
          incognito: true,
          alreadyListed: false,
        ),
        isFalse,
      );
    });

    test('skips when already listed', () {
      expect(
        shouldAutoAddToMyList(
          autoAddEnabled: true,
          incognito: false,
          alreadyListed: true,
        ),
        isFalse,
      );
    });
  });

  group('mediaItemForPlayback', () {
    test(
      'uses the Z-mode catalogue id so Detail and play share a My List key',
      () {
        final item = mediaItemForPlayback(
          sourceId: ZmodeIds.sourceId,
          showUrl: 'zm://anime/mal:123',
          showTitle: 'Show',
          malId: 123,
        );
        expect(item, isNotNull);
        expect(item!.id, 'mal:123');
        expect(item.url, 'zm://anime/mal:123');
        expect(item.sourceId, ZmodeIds.sourceId);
        expect(item.type, ProviderType.anime);
        expect(item.malId, 123);
      },
    );

    test('maps Z-mode kinds to provider types', () {
      expect(
        mediaItemForPlayback(
          sourceId: ZmodeIds.sourceId,
          showUrl: 'zm://movie/tmdb:9',
          showTitle: 'Film',
        )!.type,
        ProviderType.movie,
      );
      expect(
        mediaItemForPlayback(
          sourceId: ZmodeIds.sourceId,
          showUrl: 'zm://manga/mal:1',
          showTitle: 'Book',
        )!.type,
        ProviderType.manga,
      );
    });

    test('falls back to the show url as id for a source title', () {
      final item = mediaItemForPlayback(
        sourceId: 'hianime',
        showUrl: '/watch/foo',
        showTitle: 'Foo',
      );
      expect(item!.id, '/watch/foo');
      expect(item.sourceId, 'hianime');
    });

    test('returns null without a title or url', () {
      expect(mediaItemForPlayback(sourceId: 'x'), isNull);
    });
  });
}
