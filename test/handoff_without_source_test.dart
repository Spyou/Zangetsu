// "Continue on phone" plays links the TV resolved, on a phone that may not
// have the TV's source installed. These pin the phone-side contract: every
// resolve goes through resolveSources (the TV), nothing reaches the Z-Mode
// resolver, and the TV proxy keeps each link's own headers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:watch_app/core/cast/cast_proxy.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/features/player/mpv_player_pool.dart';
import 'package:watch_app/features/player/player_controller.dart';

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

/// Records every use; a handoff must never touch the Z-Mode resolver.
class _Resolver extends Fake implements PlaybackResolver {
  final calls = <Symbol>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('phone player in remote-resolve mode', () {
    late Directory dir;
    late _Player player;
    late _Resolver resolver;
    PlayerCubit? cubit;
    const live = VideoSource(url: 'http://192.168.1.5:4000/p/t/live/seg');
    const mirror = VideoSource(url: 'http://192.168.1.5:4000/p/t/mirror/seg');
    const zShow = 'zm://anime/42';
    const zEpisode = 'zm://anime/42/ep/1';

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('handoff_without_source');
      Hive.init(dir.path);
      await PlaybackPrefs.init();
      await ResumeStore.init();
      await TitlePrefsStore.init();
      await sl.reset();
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
      resolver = _Resolver();
      sl.registerSingleton<PlaybackResolver>(resolver);
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

    Future<List<String>> start({required bool remote}) async {
      final asked = <String>[];
      final opened = player.opens.stream.first;
      cubit = PlayerCubit(
        // A Z-Mode title: without remote-resolve this would sweep through the
        // phone's own PlaybackResolver instead of asking the TV.
        sourceId: 'zm',
        showUrl: zShow,
        episodes: const [Episode(id: '1', title: 'One', url: zEpisode)],
        resume: ResumeStore(),
        resolveSources: (url) async {
          asked.add(url);
          return [live, mirror];
        },
        dio: Dio(),
        initialSource: live,
        remoteResolve: remote,
      )..init(0);
      await opened;
      await Future<void>.delayed(Duration.zero);
      return asked;
    }

    test('links come from the TV, never the Z-Mode resolver', () async {
      final asked = await start(remote: true);
      expect(asked, [zEpisode]);
      expect(player.opened, [live.url]);
      expect(cubit!.playingSourceId, 'zm');
      expect(resolver.calls, isEmpty);
    });

    test('a dead live link fails over to the TV mirror', () async {
      await start(remote: true);
      final next = player.opens.stream.first;
      player.errors.add('Failed to open http://192.168.1.5:4000/p/t/live/seg');
      expect(await next, mirror.url);
      expect(resolver.calls, isEmpty);
    });

    test('every TV link dead ends with a message, not a throw', () async {
      await start(remote: true);
      final next = player.opens.stream.first;
      player.errors.add('Failed to open live');
      await next;
      await Future<void>.delayed(Duration.zero);
      player.errors.add('Failed to open mirror');
      for (var i = 0; i < 20 && cubit!.state.error == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cubit!.state.error, isNotNull);
      expect(resolver.calls, isEmpty);
    });
  });

  group('TV proxy for the phone', () {
    // The test binding answers every HttpClient with 400; these need real
    // loopback sockets.
    HttpOverrides? saved;
    setUp(() {
      saved = HttpOverrides.current;
      HttpOverrides.global = null;
    });
    tearDown(() => HttpOverrides.global = saved);

    test('each proxied link keeps its own headers', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = CastProxyServer(restrictTargets: true);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.stop();
        await upstream.close(force: true);
      });
      upstream.listen((req) async {
        final res = req.response;
        res.write('${req.uri.path}:${req.headers.value('Referer')}');
        await res.close();
      });
      final base = 'http://127.0.0.1:${upstream.port}';
      final a = await proxy.serve('$base/a.mp4', {'Referer': 'https://a.test'});
      final b = proxy.proxify(
        '$base/b.mp4',
        headers: {'Referer': 'https://b.test'},
      );
      expect(a, isNotNull);
      expect(b, isNotNull);
      Future<String> get(String url) async {
        final res = await (await client.getUrl(
          Uri.parse(url).replace(host: '127.0.0.1'),
        )).close();
        return res.transform(utf8.decoder).join();
      }

      expect(await get(b!), '/b.mp4:https://b.test');
      expect(await get(a!), '/a.mp4:https://a.test');
    });

    test('a registered local file is served with ranges', () async {
      final dir = await Directory.systemTemp.createTemp('handoff_local');
      final file = File('${dir.path}${Platform.pathSeparator}ep.mp4');
      await file.writeAsString('abcdef');
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = CastProxyServer(restrictTargets: true);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.stop();
        await upstream.close(force: true);
        await dir.delete(recursive: true);
      });
      upstream.listen((req) => req.response.close());
      // serve() starts the proxy; the local file is then proxied like a mirror.
      await proxy.serve('http://127.0.0.1:${upstream.port}/x.mp4', const {});
      final local = proxy.proxify(file.uri.toString(), headers: const {});
      expect(local, isNotNull);
      final uri = Uri.parse(local!).replace(host: '127.0.0.1');
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=2-4');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.partialContent);
      expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2-4/6');
      expect(await res.transform(utf8.decoder).join(), 'cde');
    });
  });
}
