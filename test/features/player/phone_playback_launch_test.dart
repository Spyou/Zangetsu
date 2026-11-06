import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';
import 'package:watch_app/features/player/player_controller.dart'
    show mergeArrivedSourceLists;

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
    Map<String, dynamic> args({
      VideoSource? source,
      int positionMs = 0,
      bool megaSkip = true,
      int megaSkipSeconds = 85,
    }) => phonePlayerArgs(
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
      megaSkip: megaSkip,
      megaSkipSeconds: megaSkipSeconds,
    );

    test(
      'MegaSkip preserves its toggle and amount separately from double-tap seeking',
      () {
        expect(args()['megaSkip'], isTrue);
        expect(args()['megaSkipSeconds'], 85);
        final custom = args(megaSkip: false, megaSkipSeconds: 30);
        expect(custom['megaSkip'], isFalse);
        expect(custom['megaSkipSeconds'], 30);
        expect(custom['seekSeconds'], 15);
        expect(args(megaSkipSeconds: 1)['megaSkipSeconds'], 5);
        expect(args(megaSkipSeconds: 999)['megaSkipSeconds'], 180);
      },
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

    test('carries the orientation and watch-page metadata', () {
      final a = phonePlayerArgs(
        title: 'A Show',
        episodeLabel: 'Episode 1',
        episodeLabels: const ['Episode 1', 'Episode 2'],
        startIndex: 0,
        accentColor: 0xFFFF4D5E,
        softwareDecoding: false,
        defaultSpeed: 1.0,
        bufferParams: const {},
        subtitleScale: 1.0,
        subtitleFgColor: 0xFFFFFFFF,
        subtitleBgColor: 0x00000000,
        subtitleEdgeType: 1,
        subtitleEdgeColor: 0xFF000000,
        subtitlePreference: '',
        autoResume: true,
        keepScreenOn: true,
        autoplayNext: true,
        seekSeconds: 10,
        playerOrientation: 'system',
        showDescription: 'The show saga.',
        availableCategories: const ['sub', 'dub'],
        source: _src(),
      );
      expect(a['playerOrientation'], 'system');
      expect(a['showDescription'], 'The show saga.');
      expect(a['availableCategories'], ['sub', 'dub']);
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

  group('phoneShouldScrobbleOnFirstFrame', () {
    test('only scrobbles the active non-peek start episode once', () {
      expect(
        phoneShouldScrobbleOnFirstFrame(
          playerOpen: true,
          alreadyScrobbled: false,
          peek: false,
          episodeIndex: 2,
          startIndex: 2,
        ),
        isTrue,
      );
      for (final values in <({bool open, bool done, bool peek, int index})>[
        (open: false, done: false, peek: false, index: 2),
        (open: true, done: true, peek: false, index: 2),
        (open: true, done: false, peek: true, index: 2),
        (open: true, done: false, peek: false, index: 3),
      ]) {
        expect(
          phoneShouldScrobbleOnFirstFrame(
            playerOpen: values.open,
            alreadyScrobbled: values.done,
            peek: values.peek,
            episodeIndex: values.index,
            startIndex: 2,
          ),
          isFalse,
        );
      }
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

  // Covers `PlayerCubit.mergeArrivedStreams(episodeUrl, streams)` via its pure
  // core `mergeArrivedSourceLists`: the cubit itself cannot be constructed
  // under `flutter test` (`Player()` needs media_kit native init — verified by
  // probe), so the episode guard + emit live on the method while every
  // ordering/dedupe assertion lands here. The method delegates with no extra
  // logic besides the guard and a no-change emit skip.
  group('mergeArrivedStreams', () {
    test(
      'late stream arrivals merge by position without interrupting playback',
      () {
        // Open on streams [A]; deliver cumulative arrival [B, A, C] for the same
        // episode; expect quality list [B, A, C] and playing stream still A.
        final a = VideoSource(
          url: 'https://cdn.test/a.mp4',
          container: SourceContainer.mp4,
          quality: '720p',
        );
        final b = VideoSource(
          url: 'https://cdn.test/b.mp4',
          container: SourceContainer.mp4,
          quality: '1080p',
        );
        final c = VideoSource(
          url: 'https://cdn.test/c.mp4',
          container: SourceContainer.mp4,
          quality: '480p',
        );
        final merged = mergeArrivedSourceLists([a], [b, a, c]);
        expect(merged.map((s) => s.url), [b.url, a.url, c.url]);
        // The open entry keeps its identity, so the Sources sheet's playing tick
        // (value equality against `state.active`, which the method never touches)
        // survives the merge.
        expect(identical(merged[1], a), isTrue);
      },
    );

    test('duplicate arrival URLs collapse to their first occurrence', () {
      final a = VideoSource(
        url: 'https://cdn.test/a.mp4',
        container: SourceContainer.mp4,
        quality: '720p',
      );
      final b = VideoSource(
        url: 'https://cdn.test/b.mp4',
        container: SourceContainer.mp4,
        quality: '1080p',
      );
      final merged = mergeArrivedSourceLists([a], [b, a, b]);
      expect(merged.map((s) => s.url), [b.url, a.url]);
    });

    test('open entries the arrivals omit are kept, arrival order first', () {
      final a = VideoSource(
        url: 'https://cdn.test/a.mp4',
        container: SourceContainer.mp4,
        quality: '720p',
      );
      final b = VideoSource(
        url: 'https://cdn.test/b.mp4',
        container: SourceContainer.mp4,
        quality: '1080p',
      );
      final merged = mergeArrivedSourceLists([a], [b]);
      expect(merged.map((s) => s.url), [b.url, a.url]);
    });

    test(
      'nothing new arrives yields the same URL order (method skips emit)',
      () {
        final a = VideoSource(
          url: 'https://cdn.test/a.mp4',
          container: SourceContainer.mp4,
          quality: '720p',
        );
        final merged = mergeArrivedSourceLists([a], [a]);
        expect(merged.map((s) => s.url), [a.url]);
        expect(identical(merged[0], a), isTrue);
      },
    );
  });

  group(
    'mergeArrivedSourceLists keeps every option the full resolve showed',
    () {
      VideoSource mk(
        String url, {
        String? quality,
        List<Subtitle> subs = const [],
      }) => VideoSource(
        url: url,
        quality: quality,
        container: SourceContainer.mp4,
        headers: null,
        kind: AudioKind.sub,
        audioLang: 'sub',
        subtitles: subs,
      );

      test('same URL, DIFFERENT quality - both survive', () {
        // The gap: url-keyed dedup dropped the 720p entry, so a quality the full
        // resolve would have shown simply disappeared.
        final out = mergeArrivedSourceLists(const [], [
          mk('https://x/a', quality: '1080p'),
          mk('https://x/a', quality: '720p'),
        ]);
        expect(out.map((e) => e.quality).toList(), ['1080p', '720p']);
      });

      test('same URL, different subtitles - both survive', () {
        final out = mergeArrivedSourceLists(const [], [
          mk(
            'https://x/a',
            subs: [const Subtitle(lang: 'en', label: '', url: 'u1')],
          ),
          mk(
            'https://x/a',
            subs: [const Subtitle(lang: 'hi', label: '', url: 'u2')],
          ),
        ]);
        expect(
          out.length,
          2,
          reason: 'a different subtitle track is a different option',
        );
      });

      test('a TRUE duplicate still collapses', () {
        final out = mergeArrivedSourceLists(const [], [
          mk('https://x/a', quality: '1080p'),
          mk('https://x/a', quality: '1080p'),
        ]);
        expect(out.length, 1, reason: 'the same option twice is one option');
      });

      test(
        'the already-playing entry is the SAME object, so the tick survives',
        () {
          final open = mk('https://x/a', quality: '1080p');
          final out = mergeArrivedSourceLists(
            [open],
            [mk('https://x/a', quality: '1080p')],
          );
          expect(identical(out.first, open), isTrue);
        },
      );
    },
  );
}
