import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';

class _Repo implements CatalogueRepository {
  final urls = <String>[];
  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async => MediaDetail(
    id: 'canonical-title',
    title: 'Title',
    url: url,
    type: ProviderType.anime,
    sourceId: sourceId ?? 'source',
  );
  final source = VideoSource(
    url: 'https://cdn.test/dub.mp4',
    headers: {'Cookie': 'clearance=test'},
    subtitles: [Subtitle(url: 'https://cdn.test/sub.vtt', lang: 'en')],
  );
  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async => const [
    Episode(
      id: 'wrong-season',
      title: 'Other',
      url: 'other',
      number: 2,
      season: 2,
    ),
    Episode(
      id: 'dub-2',
      title: 'Episode 2 dub',
      url: 'dub-2',
      number: 2,
      season: 1,
    ),
  ];
  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    urls.add(episodeUrl);
    return [source];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads extends DownloadManager {
  _Downloads(super.repo);
  int calls = 0;
  DownloadRecord? record;
  final managed = <String>[];
  @override
  Future<void> pause(DownloadRecord rec) async {
    managed.add("pause");
  }

  @override
  Future<void> resume(DownloadRecord rec) async {
    managed.add("resume");
  }

  @override
  Future<void> cancel(DownloadRecord rec) async {
    managed.add("cancel");
  }

  String? savedShowId;
  String? savedCategory;
  Episode? savedEpisode;
  VideoSource? savedSource;
  List<VideoSource>? savedFallbacks;
  @override
  DownloadRecord? recordFor(String sourceId, String showId, String episodeId) =>
      record;
  @override
  Future<void> enqueueSource({
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    required String showUrl,
    required String category,
    required Episode episode,
    required VideoSource source,
    required String qualityLabel,
    required int nowMs,
    int? malId,
    List<VideoSource> fallbacks = const [],
  }) async {
    calls++;
    savedShowId = showId;
    savedCategory = category;
    savedEpisode = episode;
    savedSource = source;
    savedFallbacks = fallbacks;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('zangetsu/phone_player');
  late Directory dir;
  late _Repo repo;
  late _Downloads downloads;
  late Future<bool> playback;
  late int session;
  late List<String> nativeCalls;
  late Completer<void> launched;

  Future<dynamic> send(String method, Map<String, dynamic> args) async {
    final result = Completer<dynamic>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (data) {
        try {
          result.complete(
            data == null
                ? null
                : const StandardMethodCodec().decodeEnvelope(data),
          );
        } catch (e, st) {
          result.completeError(e, st);
        }
      },
    );
    return result.future;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('phone_watch_download');
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    await ResumeStore.init();
    await sl.reset();
    repo = _Repo();
    downloads = _Downloads(repo);
    sl.registerSingleton<CatalogueRepository>(repo);
    sl.registerSingleton<DownloadManager>(downloads);
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    nativeCalls = [];
    launched = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      if (call.method == 'launch') {
        session = (call.arguments as Map)['sessionId'] as int;
        launched.complete();
      }
      return true;
    });
    playback = PhoneNativePlayer.play(
      sourceId: 'source',
      episodes: const [
        Episode(
          id: 'sub-1',
          title: 'First',
          url: 'sub-1',
          number: 1,
          season: 1,
        ),
        Episode(
          id: 'sub-2',
          title: 'Second',
          url: 'sub-2',
          number: 2,
          season: 1,
        ),
      ],
      startIndex: 0,
      resume: ResumeStore(),
      resolveSources: (_) async => [],
      showUrl: 'https://show.test/title',
      downloadShowId: 'canonical-title',
      showTitle: 'Title',
      showDescription: 'Synopsis',
      availableCategories: ['sub', 'dub'],
    );
    await launched.future;
  });
  tearDown(() async {
    await send('playerClosed', {'index': 0, 'positionMs': 0, 'durationMs': 0});
    await playback;
    messenger.setMockMethodCallHandler(channel, null);
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'download chooses the exact cut and source without switching playback',
    () async {
      final args = {'sessionId': session, 'index': 1};
      final options =
          await send('watchDownloadOptions', {...args, 'category': 'dub'})
              as Map;
      expect(repo.urls, ['dub-2']);
      expect(downloads.calls, 0);
      expect(nativeCalls, ['launch']);
      expect(
        await send('watchDownloadChoose', {
          ...args,
          'token': options['token'],
          'source': 0,
        }),
        true,
      );
      expect(downloads.savedShowId, 'canonical-title');
      expect(downloads.savedCategory, 'dub');
      expect(downloads.savedEpisode?.id, 'dub-2');
      expect(downloads.savedSource, same(repo.source));
      expect(downloads.savedFallbacks, [repo.source]);
      expect(downloads.savedSource?.headers, {'Cookie': 'clearance=test'});
      expect(downloads.savedSource?.subtitles.single.lang, 'en');
      expect(nativeCalls, ['launch']);
      expect(
        await send('watchDownloadChoose', {
          ...args,
          'token': options['token'],
          'source': 0,
        }),
        false,
      );
      expect(downloads.calls, 1);
    },
  );

  test(
    'active downloads offer management without resolving or opening playback',
    () async {
      downloads.record = const DownloadRecord(
        id: 'download',
        sourceId: 'source',
        showId: 'canonical-title',
        showTitle: 'Title',
        showUrl: 'https://show.test/title',
        episodeId: 'sub-2',
        episodeUrl: 'sub-2',
        episodeTitle: 'Second',
        category: 'sub',
        quality: '1080p',
        status: DownloadStatus.paused,
        createdAt: 0,
      );
      final args = {'sessionId': session, 'index': 1};
      expect(await send('watchDownloadOptions', args), {'status': 'paused'});
      expect(
        await send('watchDownloadAction', {...args, 'action': 'resume'}),
        true,
      );
      expect(downloads.managed, ['resume']);
      expect(repo.urls, isEmpty);
      expect(downloads.calls, 0);
      expect(nativeCalls, ['launch']);
    },
  );

  test(
    'history entry without a download ID still uses the detail download group',
    () async {
      await send('playerClosed', {
        'index': 0,
        'positionMs': 0,
        'durationMs': 0,
      });
      await playback;
      launched = Completer<void>();
      playback = PhoneNativePlayer.play(
        sourceId: 'source',
        episodes: const [
          Episode(id: 'sub-2', title: 'Second', url: 'sub-2', number: 2),
        ],
        startIndex: 0,
        resume: ResumeStore(),
        resolveSources: (_) async => [],
        showUrl: 'https://show.test/title',
        showTitle: 'Title',
        showDescription: 'Synopsis',
      );
      await launched.future;
      final args = {'sessionId': session, 'index': 0};
      final options = await send('watchDownloadOptions', args) as Map;
      expect(
        await send('watchDownloadChoose', {
          ...args,
          'token': options['token'],
          'source': 0,
        }),
        true,
      );
      expect(downloads.savedShowId, 'canonical-title');
    },
  );

  test(
    'stale sessions, superseded choices and malformed indices cannot enqueue',
    () async {
      final args = {'sessionId': session, 'index': 1};
      expect(
        await send('watchDownloadOptions', {...args, 'sessionId': session - 1}),
        isNull,
      );
      expect(
        await send('watchDownloadOptions', {...args, 'category': 'invalid'}),
        isNull,
      );
      final old = await send('watchDownloadOptions', args) as Map;
      final current = await send('watchDownloadOptions', args) as Map;
      expect(
        await send('watchDownloadChoose', {
          ...args,
          'token': old['token'],
          'source': 0,
        }),
        false,
      );
      for (final source in [-1, 1, 0.5, '0']) {
        expect(
          await send('watchDownloadChoose', {
            ...args,
            'token': current['token'],
            'source': source,
          }),
          false,
        );
      }
      expect(downloads.calls, 0);
      expect(nativeCalls, ['launch']);
    },
  );
}
