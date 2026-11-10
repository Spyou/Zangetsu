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
    expect(calls.single.arguments, {'uri': 'magnet:x', 'allowMobileData': false});
  });

  test('stop invokes stopStream with the id', () async {
    await TorrentService().stop('abc');
    expect(calls.single.method, 'stopStream');
    expect(calls.single.arguments, {'id': 'abc'});
  });

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
