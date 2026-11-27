import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_keyboard_bridge.dart';
import 'package:watch_app/features/companion/apple_companion.dart';
import 'package:watch_app/features/companion/companion_wire.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(AppleCompanion.native, null),
  );

  /// Starts an Apple receiver and returns a QR-paired raw client.
  Future<CompanionWire> pairedClient(AppleCompanion tv) async {
    final receiver = await tv.invoke('receiverStart', null) as Map;
    final port = (receiver['address'] as String)
        .split('\n')
        .first
        .split(':')
        .last;
    final raw = CompanionWire(
      await Socket.connect('127.0.0.1', int.parse(port)),
    );
    final challenge = await raw.read();
    const clientId = 'apple-companion-test-client';
    final key = CompanionKey.generate();
    raw.send({
      'version': companionPairingVersion,
      'clientId': clientId,
      'mode': 'qr',
      'proof': companionPairingProof(
        receiver['qr'] as String,
        label: 'phone',
        mode: 'qr',
        nonce: challenge['nonce'] as String,
        tvKey: challenge['key'] as String,
        clientKey: key.publicHex,
        clientId: clientId,
      ),
      'key': key.publicHex,
    });
    expect((await raw.read())['type'], 'paired');
    addTearDown(() async {
      raw.close();
      await tv.invoke('receiverStop', null);
    });
    return raw;
  }

  test('a new play clears the previous receiver playback error', () async {
    messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
      if (call.method == 'player') return {'active': false};
      return null;
    });
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    final tv = AppleCompanion(receiverDevice: () => true)
      ..catalogue = (c) async => {'ok': true};
    final raw = await pairedClient(tv);
    await tv.invoke('playbackError', 'Source failed');
    expect(
      (await raw.exchange({'action': 'state'}))['playbackError'],
      'Source failed',
    );
    await raw.exchange({'action': 'play'});
    expect((await raw.exchange({'action': 'state'}))['playbackError'], isNull);
  });

  test(
    'player commands bypass the Flutter lifecycle guard while AVKit plays',
    () async {
      final calls = <Map>[];
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method != 'player') return null;
        final args = call.arguments as Map;
        calls.add(args);
        return args['action'] == 'state' ? {'active': true} : {'ok': true};
      });
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final tv = AppleCompanion(receiverDevice: () => true);
      final raw = await pairedClient(tv);
      expect((await raw.exchange({'action': 'toggle'}))['ok'], isTrue);
      expect(calls.last['action'], 'toggle');
    },
  );

  group('phone keyboard v1', () {
    setUp(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    /// A receiver whose native player is [active] and catalogue records [seen].
    AppleCompanion receiver(bool active, List<Map<String, dynamic>> seen) {
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'player') return {'active': active};
        return null;
      });
      return AppleCompanion(receiverDevice: () => true)
        ..catalogue = (c) async {
          seen.add(c);
          return {'ok': true, 'keyboard': null};
        };
    }

    test('state advertises the keyboard capability and snapshot', () async {
      final raw = await pairedClient(receiver(false, []));
      final state = await raw.exchange({'action': 'state'});
      expect(state['keyboardVersion'], 1);
      expect(state.containsKey('keyboard'), isTrue);
      expect(state['keyboard'], TvKeyboardBridge.instance.snapshot());
    });

    test('keyboard actions route to the catalogue callback', () async {
      final seen = <Map<String, dynamic>>[];
      final raw = await pairedClient(receiver(false, seen));
      final reply = await raw.exchange({
        'action': 'keyboardInput',
        'field': 1,
        'text': 'x',
      });
      expect(reply['ok'], isTrue);
      expect(reply.containsKey('error'), isFalse);
      expect(seen, hasLength(1));
      expect(seen.single['action'], 'keyboardInput');
      expect(seen.single['field'], 1);
      expect(seen.single['text'], 'x');
    });

    test('an active native player hides the keyboard quietly', () async {
      final seen = <Map<String, dynamic>>[];
      final raw = await pairedClient(receiver(true, seen));
      final state = await raw.exchange({'action': 'state'});
      expect(state['keyboardVersion'], 1);
      expect(state['keyboard'], isNull);
      final reply = await raw.exchange({
        'action': 'keyboardSubmit',
        'field': 1,
        'text': 'x',
      });
      expect(reply['ok'], isFalse);
      expect(reply['keyboard'], isNull);
      expect(reply.containsKey('error'), isFalse);
      expect(seen, isEmpty);
    });

    test(
      'the tvOS system keyboard (inactive) still accepts typing, background does not',
      () async {
        final seen = <Map<String, dynamic>>[];
        final raw = await pairedClient(receiver(false, seen));
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        final typing = await raw.exchange({
          'action': 'keyboardInput',
          'field': 1,
          'text': 'x',
        });
        expect(typing['ok'], isTrue);
        expect(seen, hasLength(1));
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.hidden,
        );
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.paused,
        );
        final state = await raw.exchange({'action': 'state'});
        expect(state['keyboard'], isNull);
        final refused = await raw.exchange({
          'action': 'keyboardInput',
          'field': 1,
          'text': 'y',
        });
        expect(refused['ok'], isFalse);
        expect(refused.containsKey('error'), isFalse);
        expect(seen, hasLength(1));
      },
    );
  });

  test(
    'receiverClosePlayer closes the native player and ignores no-player errors',
    () async {
      final actions = <String>[];
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method != 'player') return null;
        actions.add((call.arguments as Map)['action'] as String);
        throw PlatformException(code: 'player', message: 'No player');
      });
      final tv = AppleCompanion(receiverDevice: () => true);
      await tv.invoke('receiverClosePlayer', null);
      expect(actions, ['closePlayer']);
    },
  );

  test('discover moves a saved TV to its new Bonjour address', () async {
    String? stored;
    messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
      switch (call.method) {
        case 'readStore':
          return jsonEncode({'deviceId': 'tv-1', 'address': '10.0.0.2:4000'});
        case 'writeStore':
          stored = call.arguments as String;
          return null;
        case 'discover':
          return [
            {'name': 'Other', 'address': '10.0.0.9:4000', 'deviceId': 'tv-2'},
            {
              'name': 'Living room',
              'address': '10.0.0.7:4000',
              'deviceId': 'tv-1',
            },
          ];
      }
      return null;
    });
    final phone = AppleCompanion()..udpDiscover = () async => const [];
    expect(await phone.invoke('discover', null), hasLength(2));
    expect(await phone.invoke('lastAddress', null), '10.0.0.7:4000');
    expect(jsonDecode(stored!)['address'], '10.0.0.7:4000');
  });

  test(
    'explicit connect replaces an in-flight reconnect; plain connect reports busy',
    () async {
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'readStore')
          return jsonEncode({
            'autoConnect': true,
            'deviceId': 'old',
            'token': 't',
          });
        if (call.method == 'player') return {'active': false};
        return null;
      });
      // A dead TV that accepts but never answers keeps the reconnect pending.
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      dead.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await dead.close();
      });
      final phone = AppleCompanion();
      await phone.invoke('remoteMode', false);
      final first = phone.invoke('connect', {
        'address': '127.0.0.1:${dead.port}',
        'pin': '123456',
      });
      final failed = expectLater(first, throwsA(isA<PlatformException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await expectLater(
        phone.invoke('connect', <String, dynamic>{}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'busy')),
      );
      await phone.invoke('reconnect', null);
      final tv = AppleCompanion(receiverDevice: () => true);
      final receiver = await tv.invoke('receiverStart', null) as Map;
      addTearDown(() async {
        await phone.invoke('disconnect', null);
        await tv.invoke('receiverStop', null);
      });
      final port = (receiver['address'] as String)
          .split('\n')
          .first
          .split(':')
          .last;
      await phone.invoke('connect', {
        'address': '127.0.0.1:$port',
        'qr': receiver['qr'],
      });
      for (final s in held) {
        s.destroy();
      }
      await failed;
      expect(
        (await phone.invoke('connectionState', null) as Map)['connected'],
        isTrue,
      );
    },
  );

  group('iPhone phone remote', () {
    test('a failed Keychain read is retried on the next call', () async {
      var reads = 0;
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'readStore') {
          if (++reads == 1)
            throw PlatformException(code: 'keychain', message: 'locked');
          return jsonEncode({'address': '10.0.0.2:4000'});
        }
        return null;
      });
      final phone = AppleCompanion(receiverDevice: () => false);
      await expectLater(
        phone.invoke('lastAddress', null),
        throwsA(isA<PlatformException>()),
      );
      expect(await phone.invoke('lastAddress', null), '10.0.0.2:4000');
      expect(reads, 2);
    });

    test('a corrupt Keychain entry starts empty instead of failing', () async {
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'readStore') return '{not json';
        return null;
      });
      final phone = AppleCompanion(receiverDevice: () => false);
      expect(await phone.invoke('lastAddress', null), isNull);
    });

    test('a bad TV code or QR is refused before any socket opens', () async {
      messenger.setMockMethodCallHandler(AppleCompanion.native, (_) async {
        return null;
      });
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var accepted = 0;
      server.listen((s) {
        accepted++;
        s.destroy();
      });
      addTearDown(server.close);
      final phone = AppleCompanion(receiverDevice: () => false);
      await expectLater(
        phone.invoke('connect', {
          'address': '127.0.0.1:${server.port}',
          'pin': '12345',
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.message,
            'message',
            'Enter the TV code or scan its QR.',
          ),
        ),
      );
      await expectLater(
        phone.invoke('connect', {
          'address': '127.0.0.1:${server.port}',
          'qr': 'NOT-A-QR',
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.message,
            'message',
            'Invalid QR code.',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(accepted, 0);
    });

    test('a failed Keychain write after pairing keeps the link', () async {
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'player') return {'active': false};
        if (call.method == 'writeStore' &&
            (jsonDecode(call.arguments as String) as Map)['autoConnect'] ==
                true)
          throw PlatformException(code: 'keychain', message: 'locked');
        return null;
      });
      final tv = AppleCompanion(receiverDevice: () => true);
      final receiver = await tv.invoke('receiverStart', null) as Map;
      final phone = AppleCompanion(receiverDevice: () => false);
      addTearDown(() async {
        await phone.invoke('disconnect', null).catchError((_) {});
        await tv.invoke('receiverStop', null);
      });
      final port = (receiver['address'] as String)
          .split('\n')
          .first
          .split(':')
          .last;
      await phone.invoke('connect', {
        'address': '127.0.0.1:$port',
        'qr': receiver['qr'],
      });
      expect(
        (await phone.invoke('connectionState', null) as Map)['connected'],
        isTrue,
      );
    });

    test('Find TVs and the reconnect scan share one discovery', () async {
      var scans = 0;
      final release = Completer<void>();
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'discover') {
          scans++;
          await release.future;
          return [
            {'name': 'Bonjour', 'address': '10.0.0.7:4000', 'deviceId': 'a'},
          ];
        }
        return null;
      });
      final phone = AppleCompanion(receiverDevice: () => false)
        ..udpDiscover = () async => [
          {'name': 'Dup', 'address': '10.0.0.7:4000', 'deviceId': 'a'},
          {'name': 'Udp', 'address': '10.0.0.8:4000', 'deviceId': 'b'},
        ];
      final first = phone.invoke('discover', null);
      final second = phone.invoke('discover', null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      release.complete();
      final a = await first as List;
      final b = await second as List;
      expect(scans, 1);
      expect(a.map((e) => (e as Map)['name']), ['Bonjour', 'Udp']);
      expect(b, same(a));
      // A later scan is a fresh one.
      await phone.invoke('discover', null);
      expect(scans, 2);
    });

    test('UDP finds a TV even when Bonjour fails', () async {
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'discover')
          throw PlatformException(code: 'localNetwork', message: 'denied');
        return null;
      });
      final phone = AppleCompanion(receiverDevice: () => false)
        ..udpDiscover = () async => [
          {'name': 'Udp', 'address': '10.0.0.8:4000', 'deviceId': 'b'},
        ];
      expect(await phone.invoke('discover', null), hasLength(1));
    });

    test('a Local Network denial surfaces when nothing is found', () async {
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'discover')
          throw PlatformException(code: 'localNetwork', message: 'denied');
        return null;
      });
      final phone = AppleCompanion(receiverDevice: () => false)
        ..udpDiscover = () async => throw const SocketException('denied');
      await expectLater(
        phone.invoke('discover', null),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'localNetwork',
          ),
        ),
      );
    });
  });
}
