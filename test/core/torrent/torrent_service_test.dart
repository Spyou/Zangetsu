import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/torrent/torrent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.spyou.watch_app/torrent');
  final calls = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'startStream') {
            return {'id': 'abc', 'localUrl': 'http://127.0.0.1:9/stream'};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('startStream returns id + localUrl', () async {
    final r = await TorrentService().startStream('magnet:x');
    expect(r.id, 'abc');
    expect(r.localUrl, 'http://127.0.0.1:9/stream');
    expect(calls.single.method, 'startStream');
    expect(calls.single.arguments, {
      'uri': 'magnet:x',
      'allowMobileData': false,
    });
  });

  test('stop invokes stopStream with the id', () async {
    await TorrentService().stop('abc');
    expect(calls.single.method, 'stopStream');
    expect(calls.single.arguments, {'id': 'abc'});
  });

  test(
    'switching away cancels peer search before its stream id is known',
    () async {
      final first = Completer<Map<String, dynamic>>();
      final events = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            events.add(call.method);
            if (call.method == 'startStream') {
              if (events.where((e) => e == 'startStream').length == 1) {
                return first.future;
              }
              return {'id': 'new', 'localUrl': 'http://127.0.0.1:2/stream'};
            }
            return null;
          });
      final service = TorrentService();
      final old = service.startStream('magnet:old');
      final cancelled = expectLater(old, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      var stopped = false;
      final stopping = service.stop('').then((_) => stopped = true);
      final next = service.startStream('magnet:new');
      await Future<void>.delayed(Duration.zero);
      expect(events, ['startStream', 'stopStream']);
      expect(stopped, isFalse);
      first.complete({'id': 'old', 'localUrl': 'http://127.0.0.1:1/stream'});
      await cancelled;
      await stopping;
      expect((await next).id, 'new');
      expect(events, ['startStream', 'stopStream', 'startStream']);
    },
  );

  test('a replacement torrent waits for active-stream cleanup', () async {
    final stopDone = Completer<void>();
    final events = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          events.add(call.method);
          if (call.method == 'stopStream') {
            await stopDone.future;
            return null;
          }
          return {'id': 'ready', 'localUrl': 'http://127.0.0.1:9/stream'};
        });
    final service = TorrentService();
    await service.startStream('magnet:first');
    final replacement = service.startStream('magnet:second');
    await Future<void>.delayed(Duration.zero);
    expect(events, ['startStream', 'stopStream']);
    stopDone.complete();
    await replacement;
    expect(events, ['startStream', 'stopStream', 'startStream']);
  });

  test('a queued replacement superseded during cleanup never starts', () async {
    final stopDone = Completer<void>();
    final started = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'stopStream') {
            await stopDone.future;
            return null;
          }
          started.add((call.arguments as Map)['uri'] as String);
          return {'id': 'ready', 'localUrl': 'http://127.0.0.1:9/stream'};
        });
    final service = TorrentService();
    await service.startStream('magnet:first');
    final replaced = service.startStream('magnet:obsolete');
    final cancelled = expectLater(replaced, throwsA(isA<StateError>()));
    final latest = service.startStream('magnet:latest');
    stopDone.complete();
    await cancelled;
    await latest;
    expect(started, ['magnet:first', 'magnet:latest']);
  });

  test(
    'replacing an event listener cannot disconnect the new listener',
    () async {
      const eventChannel = MethodChannel('com.spyou.watch_app/torrent/events');
      final eventCalls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(eventChannel, (call) async {
        eventCalls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(eventChannel, null));
      final service = TorrentService();
      final first = service.events().listen((_) {});
      final received = <TorrentProgress>[];
      final second = service.events().listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(eventCalls, ['listen']);
      await first.cancel();
      expect(eventCalls, ['listen']);
      await messenger.handlePlatformMessage(
        eventChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'id': 'new',
          'state': 'finding',
        }),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(received.single.id, 'new');
      await second.cancel();
      expect(eventCalls, ['listen', 'cancel']);
    },
  );

  test('TorrentProgress.fromMap parses fields + state', () {
    final p = TorrentProgress.fromMap({
      'id': 'x',
      'state': 'ready',
      'bufferPct': 0.5,
      'peers': 3,
      'downSpeedBps': 1000,
    });
    expect(p.state, TorrentState.ready);
    expect(p.bufferPct, 0.5);
    expect(p.peers, 3);
    expect(p.downSpeedBps, 1000);
  });
}
