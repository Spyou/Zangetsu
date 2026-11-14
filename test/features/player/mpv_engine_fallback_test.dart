import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/features/player/mpv_player_pool.dart';
import 'package:watch_app/features/player/player_controller.dart';
import 'package:watch_app/features/player/player_engine_fallback.dart';

class _Player extends Fake implements mk.Player {
  final errors = StreamController<String>.broadcast();
  final opened = <String>[];
  final opens = StreamController<String>.broadcast();
  @override
  mk.PlatformPlayer? get platform => null;
  @override
  mk.PlayerState get state => const mk.PlayerState();
  @override
  late final stream = mk.PlayerStream(
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    errors.stream,
  );
  @override
  Future<void> open(mk.Playable playable, {bool play = true}) async {
    final url = (playable as mk.Media).uri;
    opened.add(url);
    opens.add(url);
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> setRate(double value) async {}
  @override
  Future<void> setSubtitleTrack(mk.SubtitleTrack track) async {}
  @override
  Future<void> setAudioTrack(mk.AudioTrack track) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Player player;
  PlayerCubit? cubit;
  const first = VideoSource(url: 'https://cdn.test/first.mp4');
  const second = VideoSource(url: 'https://cdn.test/second.mp4');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mpv_engine_fallback');
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    await ResumeStore.init();
    await TitlePrefsStore.init();
    await sl.reset();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
    player = _Player();
    sl.registerSingleton<MpvPlayerPool>(
      MpvPlayerPool(createPlayer: (_) => player),
    );
  });
  tearDown(() async {
    if (cubit != null) {
      await cubit!.close();
      await cubit!.nativeTeardown;
    }
    cubit = null;
    await player.errors.close();
    await player.opens.close();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<void> start({
    Future<bool> Function(VideoSource, Duration)? failure,
    Duration resume = Duration.zero,
    bool forceResume = false,
    PlayerEngineFallback? fallback,
  }) async {
    final opened = player.opens.stream.first;
    cubit = PlayerCubit(
      sourceId: 'source',
      episodes: const [Episode(id: '1', title: 'First', url: 'episode-1')],
      resume: ResumeStore(),
      resolveSources: (_) async => [first, second],
      dio: Dio(),
      onSourceFailure: failure,
      engineFallback: fallback,
      initialResume: resume,
      forceInitialResume: forceResume,
    )..init(0);
    await opened;
    // Let open() finish before sending a decoder error.
    await Future<void>.delayed(Duration.zero);
  }

  test('MPV asks the alternate engine before opening another mirror', () async {
    final requested = Completer<VideoSource>();
    await start(
      failure: (source, position) async {
        requested.complete(source);
        return true;
      },
    );
    player.errors.add('unsupported codec');
    expect(await requested.future, first);
    await Future<void>.delayed(Duration.zero);
    player.errors.add('unsupported codec again');
    await Future<void>.delayed(Duration.zero);
    expect(player.opened, [first.url]);
    expect(cubit!.state.error, isNull);
  });

  test('a declined handoff continues the existing next-mirror flow', () async {
    await start(failure: (_, _) async => false);
    final next = player.opens.stream.first;
    player.errors.add('unsupported codec');
    expect(await next, second.url);
    expect(player.opened, [first.url, second.url]);
  });

  test('off keeps the existing next-mirror flow', () async {
    await start();
    final next = player.opens.stream.first;
    player.errors.add('unsupported codec');
    expect(await next, second.url);
  });

  test('a broken engine handoff still tries the next mirror', () async {
    await start(failure: (_, _) async => throw StateError('unavailable'));
    final next = player.opens.stream.first;
    player.errors.add('unsupported codec');
    expect(await next, second.url);
  });

  test(
    'links that failed in both engines are excluded from a new session',
    () async {
      final fallback = PlayerEngineFallback();
      for (final engine in PlaybackEngine.values) {
        fallback.next(
          enabled: true,
          failedEngine: engine,
          episodeUrl: 'episode-1',
          category: 'sub',
          source: first,
        );
      }
      await start(fallback: fallback);
      expect(player.opened, [second.url]);
    },
  );

  test('subtitle-only errors do not switch player or mirror', () async {
    var requests = 0;
    await start(
      failure: (_, _) async {
        requests++;
        return true;
      },
    );
    player.errors.add('subtitle failed to download');
    await Future<void>.delayed(Duration.zero);
    expect(requests, 0);
    expect(player.opened, [first.url]);
  });

  test('recovery retains position even when auto-resume is off', () async {
    await sl<PlaybackPrefs>().setAutoResume(false);
    final requested = Completer<Duration>();
    await start(
      resume: const Duration(seconds: 42),
      forceResume: true,
      failure: (_, position) async {
        requested.complete(position);
        return true;
      },
    );
    player.errors.add('unsupported codec');
    expect(await requested.future, const Duration(seconds: 42));
    expect(sl<PlaybackPrefs>().autoResume, isFalse);
  });
}
