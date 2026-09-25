import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';

class _RecordingTrackerHub extends TrackerHub {
  _RecordingTrackerHub() : super(const []);

  int calls = 0;
  int? malId;
  String? title;
  int? tmdbId;
  bool? tmdbIsTv;
  String? imdbId;
  int? episode;
  int? season;
  int? seasonEpisode;

  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    int? season,
    int? seasonEpisode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
    bool auto = true,
  }) async {
    calls++;
    this.malId = malId;
    this.title = title;
    this.tmdbId = tmdbId;
    this.tmdbIsTv = tmdbIsTv;
    this.imdbId = imdbId;
    this.episode = episode;
    this.season = season;
    this.seasonEpisode = seasonEpisode;
  }
}

VideoSource _src({
  String url = 'https://cdn.test/ep1.mp4',
  SourceContainer container = SourceContainer.mp4,
  Map<String, String>? headers,
  List<Subtitle> subtitles = const [],
}) => VideoSource(
  url: url,
  container: container,
  headers: headers,
  subtitles: subtitles,
);

void main() {
  group('phoneMimeFor', () {
    test('an HLS container is hinted even when the url has no extension', () {
      // Tokenised urls carry no .m3u8, so without the hint ExoPlayer builds a
      // progressive MediaSource and the stream never starts.
      expect(
        phoneMimeFor(
          _src(url: 'https://cdn.test/s?t=abc', container: SourceContainer.hls),
        ),
        'application/x-mpegURL',
      );
    });

    test('extensions are recognised on their own', () {
      expect(
        phoneMimeFor(_src(url: 'https://a/b.m3u8')),
        'application/x-mpegURL',
      );
      expect(
        phoneMimeFor(_src(url: 'https://a/b.mpd')),
        'application/dash+xml',
      );
      expect(phoneMimeFor(_src(url: 'https://a/b.mp4')), 'video/mp4');
    });

    test('an unknown url gets no hint, so ExoPlayer sniffs it', () {
      expect(phoneMimeFor(_src(url: 'https://a/stream')), isNull);
    });
  });

  group('phonePlayerArgs', () {
    Map<String, dynamic> args({VideoSource? source, int positionMs = 0}) =>
        phonePlayerArgs(
          source: source ?? _src(),
          positionMs: positionMs,
          title: 'A Show',
          episodeLabel: 'Episode 1',
          episodeLabels: const ['Episode 1', 'Episode 2'],
          startIndex: 0,
          accentColor: 0xFFFF4D5E,
          softwareDecoding: false,
          defaultSpeed: 1.0,
          bufferParams: const {
            'minBufferMs': 15000,
            'maxBufferMs': 50000,
            'targetBufferBytes': 0,
            'backBufferMs': 30000,
          },
          subtitleScale: 1.0,
          subtitleFgColor: 0xFFFFFFFF,
          subtitleBgColor: 0x00000000,
          subtitleEdgeType: 1,
          subtitleEdgeColor: 0xFF000000,
          subtitlePreference: '',
          autoResume: true,
          keepScreenOn: false,
          autoplayNext: true,
          seekSeconds: 15,
        );

    test('carries the stream, the resume position and the episode list', () {
      final a = args(positionMs: 90000);
      expect(a['url'], 'https://cdn.test/ep1.mp4');
      expect(a['positionMs'], 90000);
      expect(a['episodeCount'], 2);
      expect(a['startIndex'], 0);
      expect(a['episodeLabels'], ['Episode 1', 'Episode 2']);
    });

    test('headers survive as a map and default to empty, never null', () {
      expect(args()['headers'], <String, String>{});
      final withHeaders = args(
        source: _src(headers: {'Referer': 'https://host/'}),
      );
      expect(withHeaders['headers'], {'Referer': 'https://host/'});
    });

    test('subtitles are flattened into three parallel lists', () {
      final a = args(
        source: _src(
          subtitles: const [
            Subtitle(url: 'https://a/en.vtt', lang: 'en', label: 'English'),
            Subtitle(url: 'https://a/es.vtt', lang: 'es'),
          ],
        ),
      );
      expect(a['subUrls'], ['https://a/en.vtt', 'https://a/es.vtt']);
      expect(a['subLangs'], ['en', 'es']);
      // A subtitle with no label falls back to its language, so the picker
      // never shows a blank row.
      expect(a['subLabels'], ['English', 'es']);
    });

    test('buffer params are spread in, not nested', () {
      final a = args();
      expect(a['minBufferMs'], 15000);
      expect(a['maxBufferMs'], 50000);
      expect(a['backBufferMs'], 30000);
    });

    test('carries phone playback settings and subtitle metadata', () {
      final a = args(
        source: _src(
          subtitles: const [
            Subtitle(
              url: 'https://a/en',
              lang: 'en',
              format: 'srt',
              isDefault: true,
            ),
            Subtitle(url: 'https://a/es', lang: 'es'),
          ],
        ),
      );

      expect(a['autoResume'], isTrue);
      expect(a['keepScreenOn'], isFalse);
      expect(a['autoplayNext'], isTrue);
      expect(a['seekSeconds'], 15);
      expect(a['subtitleEdgeColor'], 0xFF000000);
      expect(a['subtitlePreference'], '');
      expect(a['subFormats'], ['srt', '']);
      expect(a['subDefaults'], [true, false]);
    });
  });

  group('phoneSourceMap', () {
    test('carries source and subtitle metadata for the native picker', () {
      final map = phoneSourceMap(
        _src(
          subtitles: const [
            Subtitle(
              url: 'https://a/en',
              lang: 'en',
              format: 'srt',
              isDefault: true,
            ),
          ],
        ),
        3,
      );

      expect(map['label'], 'Server 4');
      expect(map['subFormats'], ['srt']);
      expect(map['subDefaults'], [true]);
    });
  });

  group('phoneSubtitleMime', () {
    test('prefers provider format over the URL', () {
      expect(
        phoneSubtitleMime('srt', 'https://a/subtitle.vtt'),
        'application/x-subrip',
      );
      expect(phoneSubtitleMime('ass', 'https://a/subtitle.vtt'), 'text/x-ssa');
      expect(
        phoneSubtitleMime('dfxp', 'https://a/subtitle.vtt'),
        'application/ttml+xml',
      );
    });

    test('falls back to the URL extension', () {
      expect(phoneSubtitleMime(null, 'https://a/subtitle.vtt'), 'text/vtt');
      expect(phoneSubtitleMime(null, 'https://a/subtitle.ssa'), 'text/x-ssa');
      expect(
        phoneSubtitleMime(null, 'https://a/subtitle.dfxp'),
        'application/ttml+xml',
      );
      expect(phoneSubtitleMime(null, 'https://a/subtitle'), 'text/vtt');
    });
  });

  group('phoneScrobbleOnLaunch', () {
    late _RecordingTrackerHub hub;

    setUp(() {
      hub = _RecordingTrackerHub();
      sl.registerSingleton<TrackerHub>(hub);
      addTearDown(() async {
        if (sl.isRegistered<TrackerHub>()) {
          await sl.unregister<TrackerHub>();
        }
      });
    });

    test(
      'forwards tracker metadata for a positive whole episode number',
      () async {
        const episode = Episode(
          id: 'e1',
          title: 'Episode 1',
          number: 1,
          url: '/e1',
          season: 2,
        );

        await phoneScrobbleOnLaunch(
          episode: episode,
          episodes: const [episode],
          malId: 123,
          scrobbleTitle: 'Tracked Show',
          tmdbId: 456,
          tmdbIsTv: true,
          imdbId: 'tt1234567',
        );

        expect(hub.calls, 1);
        expect(hub.malId, 123);
        expect(hub.title, 'Tracked Show');
        expect(hub.tmdbId, 456);
        expect(hub.tmdbIsTv, isTrue);
        expect(hub.imdbId, 'tt1234567');
        expect(hub.episode, 1);
        expect(hub.season, 2);
        expect(hub.seasonEpisode, 1);
      },
    );

    test(
      'does not scrobble non-positive or non-whole episode numbers',
      () async {
        for (final number in <double>[0, 1.5]) {
          final episode = Episode(
            id: 'e$number',
            title: 'Episode $number',
            number: number,
            url: '/e$number',
            season: 2,
          );
          await phoneScrobbleOnLaunch(
            episode: episode,
            episodes: [episode],
            malId: 123,
            scrobbleTitle: 'Tracked Show',
            tmdbId: 456,
            tmdbIsTv: true,
            imdbId: 'tt1234567',
          );
        }

        expect(hub.calls, 0);
      },
    );

    test('does not scrobble an infinite episode number', () async {
      const episode = Episode(
        id: 'e∞',
        title: 'Episode infinity',
        number: double.infinity,
        url: '/e∞',
      );

      await phoneScrobbleOnLaunch(episode: episode, episodes: const [episode]);

      expect(hub.calls, 0);
    });

    test('does not scrobble a peek episode', () async {
      const episode = Episode(
        id: 'e1',
        title: 'Episode 1',
        number: 1,
        url: '/e1',
      );

      await phoneScrobbleOnLaunch(
        episode: episode,
        episodes: const [episode],
        peek: true,
      );

      expect(hub.calls, 0);
    });
  });

  test('returns normally without a registered TrackerHub', () async {
    const episode = Episode(
      id: 'e1',
      title: 'Episode 1',
      number: 1,
      url: '/e1',
    );

    expect(sl.isRegistered<TrackerHub>(), isFalse);
    await expectLater(
      phoneScrobbleOnLaunch(episode: episode, episodes: const [episode]),
      completes,
    );
  });

  group('phoneMirrorLabel', () {
    test('prefers the provider name', () {
      final s = VideoSource(
        url: 'https://a/1',
        container: SourceContainer.mp4,
        label: 'Vidhide',
        quality: '1080p',
      );
      expect(phoneMirrorLabel(s, 0), 'Vidhide');
    });

    test('falls back to the quality when there is no name', () {
      final s = VideoSource(
        url: 'https://a/2',
        container: SourceContainer.mp4,
        quality: '720p',
      );
      expect(phoneMirrorLabel(s, 1), '720p');
    });

    test('never returns blank — an unnamed mirror gets its number', () {
      // A blank row in the picker is unpickable; the index is 0-based and the
      // label is 1-based, so index 2 reads "Server 3".
      final s = VideoSource(url: 'https://a/3', container: SourceContainer.mp4);
      expect(phoneMirrorLabel(s, 2), 'Server 3');
    });
  });
}
