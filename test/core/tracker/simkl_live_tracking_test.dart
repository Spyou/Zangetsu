import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late SimklService simkl;
  late Dio dio;
  late TrackerHub hub;
  late Box box;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('simkl-live-');
    Hive.init(dir.path);
    box = await Hive.openBox(SimklService.boxName);
    await box.putAll({'accessToken': 'test-token', 'viewerName': 'test'});
    dio = Dio();
    simkl = SimklService(dio);
    hub = TrackerHub([simkl]);
  });
  tearDown(() async {
    simkl.dispose();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'real service queues live events and reports only the selected episode',
    () async {
      final requests = <RequestOptions>[];
      final releaseStart = Completer<void>();
      final firstStarted = Completer<void>();
      final stopped = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requests.add(options);
            if (requests.length == 1) {
              firstStarted.complete();
              await releaseStart.future;
            }
            handler.resolve(Response(requestOptions: options, statusCode: 201));
            if (options.path.endsWith('/stop')) stopped.complete();
          },
        ),
      );
      final session = hub.simklPlayback(malId: 21, episode: 8)!;
      session.update(positionMs: 1000, durationMs: 100000, playing: true);
      session.update(positionMs: 2000, durationMs: 100000, playing: false);
      session.update(positionMs: 2000, durationMs: 100000, playing: true);
      session.stop();
      await firstStarted.future;
      expect(requests, hasLength(1));
      releaseStart.complete();
      await stopped.future.timeout(const Duration(seconds: 3));
      expect(requests.map((r) => r.uri.path), [
        '/scrobble/start',
        '/scrobble/pause',
        '/scrobble/start',
        '/scrobble/stop',
      ]);
      for (final request in requests) {
        expect(request.data['episode'], {'number': 8});
        expect(request.data.containsKey('shows'), isFalse);
        expect(request.headers['Authorization'], 'Bearer test-token');
      }
      expect(requests.last.data['progress'], 2);
    },
  );

  test(
    'incognito, auto-track off, and disconnected accounts do not track',
    () async {
      await IncognitoMode.init();
      await PlaybackPrefs.init();
      final prefs = PlaybackPrefs();
      sl.registerSingleton<PlaybackPrefs>(prefs);
      await prefs.setAutoTrack(false);
      expect(hub.simklPlayback(malId: 21, episode: 1), isNull);
      await prefs.setAutoTrack(true);
      await IncognitoMode.set(true);
      expect(hub.simklPlayback(malId: 21, episode: 1), isNull);
      await IncognitoMode.set(false);
      await box.delete('accessToken');
      expect(hub.simklPlayback(malId: 21, episode: 1), isNull);
    },
  );

  test('queued updates cannot follow an account change', () async {
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(Response(requestOptions: options, statusCode: 201));
        },
      ),
    );
    final session = hub.simklPlayback(malId: 21, episode: 1)!;
    await box.put('accessToken', 'different-account');
    session.update(positionMs: 1000, durationMs: 100000, playing: true);
    session.stop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, isEmpty);
  });

  test('a failed start cannot block later pause and stop updates', () async {
    final paths = <String>[];
    final stopped = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          paths.add(options.uri.path);
          if (paths.length == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            );
          } else {
            handler.resolve(Response(requestOptions: options, statusCode: 201));
          }
          if (options.path.endsWith('/stop')) stopped.complete();
        },
      ),
    );
    final session = hub.simklPlayback(malId: 21, episode: 8)!;
    session.update(positionMs: 1000, durationMs: 100000, playing: true);
    session.update(positionMs: 2000, durationMs: 100000, playing: false);
    session.stop();
    await stopped.future.timeout(const Duration(seconds: 3));
    expect(paths, ['/scrobble/start', '/scrobble/pause', '/scrobble/stop']);
  });
}
