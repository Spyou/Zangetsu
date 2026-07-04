import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_mapping.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/video_source.dart';

void main() {
  // ── videoSourceFromVideo ────────────────────────────────────────────────────
  group('videoSourceFromVideo', () {
    test('maps HLS container when url ends with .m3u8', () {
      final src = videoSourceFromVideo({
        'videoUrl': 'https://cdn.test/master.m3u8',
        'videoTitle': '1080p',
        'headers': {'Referer': 'https://embed.test/'},
        'subtitleTracks': [
          {'url': 'https://cdn.test/en.vtt', 'lang': 'en'},
        ],
        'audioTracks': [],
      });

      expect(src.url, 'https://cdn.test/master.m3u8');
      expect(src.container, SourceContainer.hls);
      expect(src.quality, '1080p');
      expect(src.headers, {'Referer': 'https://embed.test/'});
      expect(src.subtitles, hasLength(1));
      expect(src.subtitles.first.url, 'https://cdn.test/en.vtt');
      expect(src.subtitles.first.lang, 'en');
    });

    test('maps MP4 container for non-m3u8 url', () {
      final src = videoSourceFromVideo({
        'videoUrl': 'https://cdn.test/video.mp4',
        'videoTitle': '720p',
        'headers': null,
        'subtitleTracks': [],
      });

      expect(src.container, SourceContainer.mp4);
      expect(src.headers, isNull);
      expect(src.subtitles, isEmpty);
    });

    test('null headers produce null on VideoSource', () {
      final src = videoSourceFromVideo({
        'videoUrl': 'https://cdn.test/video.mp4',
      });
      expect(src.headers, isNull);
    });

    test('multiple subtitle tracks are all mapped', () {
      final src = videoSourceFromVideo({
        'videoUrl': 'https://cdn.test/master.m3u8',
        'subtitleTracks': [
          {'url': 'https://cdn.test/en.vtt', 'lang': 'en'},
          {'url': 'https://cdn.test/ja.vtt', 'lang': 'ja'},
        ],
      });
      expect(src.subtitles, hasLength(2));
      expect(src.subtitles[1].lang, 'ja');
    });

    test('empty videoTitle produces null quality', () {
      final src = videoSourceFromVideo({
        'videoUrl': 'https://cdn.test/v.mp4',
        'videoTitle': '',
      });
      expect(src.quality, isNull);
    });
  });

  // ── episodeFromSEpisode ─────────────────────────────────────────────────────
  group('episodeFromSEpisode', () {
    test('keeps url in Episode.url and derives number', () {
      final ep = episodeFromSEpisode({
        'url': 'https://source.test/ep/1',
        'name': 'Episode 1',
        'episode_number': 1.0,
        'date_upload': 0,
        'fillermark': false,
      });

      expect(ep.url, 'https://source.test/ep/1');
      expect(ep.number, 1.0);
      expect(ep.title, 'Episode 1');
      expect(ep.filler, false);
    });

    test('negative episode_number treated as null number', () {
      final ep = episodeFromSEpisode({
        'url': 'https://source.test/ep/special',
        'name': 'Special',
        'episode_number': -1.0,
        'date_upload': 0,
        'fillermark': false,
      });

      expect(ep.number, isNull);
      // id falls back to the url when episode_number is unset
      expect(ep.id, 'https://source.test/ep/special');
    });

    test('date_upload millis are converted to ISO string', () {
      final ep = episodeFromSEpisode({
        'url': 'https://source.test/ep/2',
        'name': 'Episode 2',
        'episode_number': 2.0,
        'date_upload': 1700000000000,
        'fillermark': false,
      });

      expect(ep.date, isNotNull);
      expect(ep.date, contains('2023')); // 1700000000000 ms ≈ Nov 2023
    });

    test('zero date_upload produces null date', () {
      final ep = episodeFromSEpisode({
        'url': 'u',
        'name': 'E',
        'episode_number': 3.0,
        'date_upload': 0,
        'fillermark': false,
      });
      expect(ep.date, isNull);
    });

    test('preview_url is mapped to thumbnail', () {
      final ep = episodeFromSEpisode({
        'url': 'u',
        'name': 'E',
        'episode_number': 4.0,
        'date_upload': 0,
        'fillermark': false,
        'preview_url': 'https://img.test/thumb.jpg',
      });
      expect(ep.thumbnail, 'https://img.test/thumb.jpg');
    });

    test('fillermark true maps to filler = true', () {
      final ep = episodeFromSEpisode({
        'url': 'u',
        'name': 'Filler',
        'episode_number': 5.0,
        'date_upload': 0,
        'fillermark': true,
      });
      expect(ep.filler, true);
    });
  });

  // ── mediaItemFromSAnime ─────────────────────────────────────────────────────
  group('mediaItemFromSAnime', () {
    test('basic mapping', () {
      final item = mediaItemFromSAnime(
        {
          'url': 'https://source.test/anime/1',
          'title': 'My Hero Academia',
          'thumbnail_url': 'https://img.test/mha.jpg',
        },
        sourceId: 'ani:123456',
      );

      expect(item.id, 'https://source.test/anime/1');
      expect(item.url, 'https://source.test/anime/1');
      expect(item.title, 'My Hero Academia');
      expect(item.cover, 'https://img.test/mha.jpg');
      expect(item.sourceId, 'ani:123456');
    });

    test('null thumbnail_url produces null cover', () {
      final item = mediaItemFromSAnime(
        {'url': 'https://source.test/anime/2', 'title': 'Title'},
        sourceId: 'ani:789',
      );
      expect(item.cover, isNull);
    });

    test('non-empty headers are set as coverHeaders', () {
      final item = mediaItemFromSAnime(
        {
          'url': 'https://source.test/anime/3',
          'title': 'Cover Headers Test',
          'thumbnail_url': 'https://img.test/cover.jpg',
        },
        sourceId: 'ani:111',
        headers: {'Referer': 'https://source.test/', 'User-Agent': 'Mozilla/5.0'},
      );
      expect(item.coverHeaders, isNotNull);
      expect(item.coverHeaders!['Referer'], 'https://source.test/');
      expect(item.coverHeaders!['User-Agent'], 'Mozilla/5.0');
    });

    test('empty headers produce null coverHeaders', () {
      final item = mediaItemFromSAnime(
        {'url': 'u', 'title': 'T'},
        sourceId: 'ani:222',
        headers: {},
      );
      expect(item.coverHeaders, isNull);
    });

    test('null headers produce null coverHeaders', () {
      final item = mediaItemFromSAnime(
        {'url': 'u', 'title': 'T'},
        sourceId: 'ani:333',
      );
      expect(item.coverHeaders, isNull);
    });

    test('x-ani-src marker is injected when headers are non-empty', () {
      final item = mediaItemFromSAnime(
        {
          'url': 'https://source.test/anime/4',
          'title': 'Marker Test',
          'thumbnail_url': 'https://i.animepahe.pw/cover.jpg',
        },
        sourceId: 'ani:8272',
        headers: {'Referer': 'https://animepahe.ru/'},
      );
      expect(item.coverHeaders, isNotNull);
      expect(item.coverHeaders!['x-ani-src'], '8272');
      // Original headers are still present
      expect(item.coverHeaders!['Referer'], 'https://animepahe.ru/');
    });

    test('x-ani-src is absent when no headers are passed', () {
      final item = mediaItemFromSAnime(
        {'url': 'u', 'title': 'T'},
        sourceId: 'ani:1234',
      );
      expect(item.coverHeaders, isNull);
    });
  });

  // ── mediaDetailFromSAnime ───────────────────────────────────────────────────
  group('mediaDetailFromSAnime', () {
    test('maps status int to MediaStatus', () {
      final detail = mediaDetailFromSAnime(
        {
          'url': 'https://source.test/anime/3',
          'title': 'Ongoing Show',
          'thumbnail_url': null,
          'description': 'A show that is ongoing.',
          'genre': 'Action, Fantasy',
          'status': 1,
        },
        const [],
        sourceId: 'ani:1',
      );

      expect(detail.status, MediaStatus.ongoing);
      expect(detail.genres, containsAll(['Action', 'Fantasy']));
      expect(detail.description, 'A show that is ongoing.');
    });

    test('non-empty headers are set as coverHeaders', () {
      final detail = mediaDetailFromSAnime(
        {'url': 'u', 'title': 'T', 'status': 1},
        const [],
        sourceId: 'ani:10',
        headers: {'Referer': 'https://source.test/'},
      );
      expect(detail.coverHeaders, isNotNull);
      expect(detail.coverHeaders!['Referer'], 'https://source.test/');
    });

    test('empty headers produce null coverHeaders on detail', () {
      final detail = mediaDetailFromSAnime(
        {'url': 'u', 'title': 'T'},
        const [],
        sourceId: 'ani:11',
        headers: {},
      );
      expect(detail.coverHeaders, isNull);
    });

    test('x-ani-src marker is injected in detail when headers are non-empty', () {
      final detail = mediaDetailFromSAnime(
        {'url': 'u', 'title': 'T', 'status': 1},
        const [],
        sourceId: 'ani:8272',
        headers: {'Referer': 'https://animepahe.ru/'},
      );
      expect(detail.coverHeaders, isNotNull);
      expect(detail.coverHeaders!['x-ani-src'], '8272');
      expect(detail.coverHeaders!['Referer'], 'https://animepahe.ru/');
    });

    test('status 2 → completed', () {
      final detail = mediaDetailFromSAnime(
        {'url': 'u', 'title': 'T', 'status': 2},
        const [],
        sourceId: 'ani:2',
      );
      expect(detail.status, MediaStatus.completed);
    });

    test('unknown status int → unknown', () {
      final detail = mediaDetailFromSAnime(
        {'url': 'u', 'title': 'T', 'status': 99},
        const [],
        sourceId: 'ani:3',
      );
      expect(detail.status, MediaStatus.unknown);
    });

    test('null genre → empty genres list', () {
      final detail = mediaDetailFromSAnime(
        {'url': 'u', 'title': 'T'},
        const [],
        sourceId: 'ani:4',
      );
      expect(detail.genres, isEmpty);
    });

    test('episodes list is embedded unchanged', () {
      final ep = episodeFromSEpisode({
        'url': 'https://source.test/ep/1',
        'name': 'Ep 1',
        'episode_number': 1.0,
        'date_upload': 0,
        'fillermark': false,
      });
      final detail = mediaDetailFromSAnime(
        {'url': 'u', 'title': 'T'},
        [ep],
        sourceId: 'ani:5',
      );
      expect(detail.episodes, hasLength(1));
      expect(detail.episodes.first.url, 'https://source.test/ep/1');
    });
  });
}
