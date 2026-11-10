import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
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

class _Player extends Fake implements mk.Player {
  final subtitles = <mk.SubtitleTrack>[];
  String? audioPreferenceAtSelection;
  String? subtitlePreferenceAtSelection;
  VoidCallback? onSubtitle;

  @override
  mk.PlatformPlayer? get platform => null;
  @override
  Future<void> setAudioTrack(mk.AudioTrack track) async {
    audioPreferenceAtSelection = sl<TitlePrefsStore>().audioTrack(
      'stremio',
      'show',
    );
  }

  @override
  Future<void> setSubtitleTrack(mk.SubtitleTrack track) async {
    subtitles.add(track);
    subtitlePreferenceAtSelection = sl<TitlePrefsStore>().subtitleChoice(
      'stremio',
      'show',
    );
    onSubtitle?.call();
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _Cubit extends PlayerCubit {
  _Cubit(Dio dio)
    : super(
        sourceId: 'stremio',
        showUrl: 'show',
        episodes: const [
          Episode(id: '1', title: 'Episode 1', url: 'episode-one'),
        ],
        resume: ResumeStore(),
        resolveSources: (_) async => [],
        dio: dio,
      );
  void source(VideoSource value) => emit(state.copyWith(active: () => value));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Player player;
  late _Cubit cubit;
  late Dio dio;
  const english = Subtitle(url: 'https://sub.test/en.srt', lang: 'en');
  const arabic = Subtitle(url: 'https://sub.test/ar.srt', lang: 'ar');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    await sl.reset();
    dir = await Directory.systemTemp.createTemp('manual_tracks');
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    await TitlePrefsStore.init();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
    player = _Player();
    sl.registerSingleton<MpvPlayerPool>(
      MpvPlayerPool(createPlayer: (_) => player),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHello\n'),
              ),
            );
          },
        ),
      );
    cubit = _Cubit(dio)
      ..source(
        const VideoSource(
          url: 'https://video.test',
          subtitles: [english, arabic],
        ),
      );
  });

  tearDown(() async {
    player.onSubtitle = null;
    await cubit.close();
    await cubit.nativeTeardown;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'one audio selection saves the new preference before native callbacks',
    () async {
      await sl<TitlePrefsStore>().setAudioTrack(
        'stremio',
        'show',
        'en|English',
      );
      await Future.sync(
        () => cubit.setAudioTrack(const mk.AudioTrack('2', 'Arabic', 'ar')),
      );
      expect(player.audioPreferenceAtSelection, 'ar|Arabic');
    },
  );

  test(
    'one soft-subtitle selection cannot be restored to the old language',
    () async {
      await sl<PlaybackPrefs>().setSubtitlePreference('en');
      await sl<TitlePrefsStore>().setSubtitleChoice('stremio', 'show', 'en');
      var first = true;
      player.onSubtitle = () {
        if (!first) return;
        first = false;
        cubit.reapplyPreferredSubtitle();
      };
      await cubit.setSoftSub(arabic);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.subtitlePreferenceAtSelection, 'ar');
      expect(player.subtitles, hasLength(1));
      expect(player.subtitles.single.language, 'ar');
    },
  );
  test('the selected mark follows the downloaded subtitle file', () async {
    await cubit.setSoftSub(arabic);
    final selected = player.subtitles.single.id;
    expect(selected, isNot(arabic.url));
    expect(File(selected).existsSync(), isTrue);
    expect(cubit.isSoftSubtitleSelected(arabic, selected), isTrue);
    expect(cubit.isSoftSubtitleSelected(english, selected), isFalse);
    await cubit.subtitlesOff();
    expect(
      cubit.isSoftSubtitleSelected(arabic, player.subtitles.last.id),
      isFalse,
    );
  });

  test(
    'a late automatic subtitle cannot overwrite a newer manual choice',
    () async {
      await sl<PlaybackPrefs>().setSubtitlePreference('en');
      await sl<TitlePrefsStore>().setSubtitleChoice('stremio', 'show', 'en');
      final started = Completer<void>();
      final release = Completer<void>();
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.uri.path == '/en.srt') {
              started.complete();
              await release.future;
            }
            handler.next(options);
          },
        ),
      );
      cubit.reapplyPreferredSubtitle();
      await started.future;
      await cubit.setSoftSub(arabic);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.subtitles, hasLength(1));
      expect(player.subtitles.single.language, 'ar');
    },
  );

  test(
    'embedded tracks with an unknown language use their readable title',
    () async {
      await cubit.setSubtitle(const mk.SubtitleTrack('3', 'Arabic', 'und'));
      expect(sl<TitlePrefsStore>().subtitleChoice('stremio', 'show'), 'ar');
      expect(player.subtitles.single.id, '3');
    },
  );
}
