import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/companion/apple_companion.dart';
import 'package:watch_app/features/companion/companion_wire.dart';

/// A version-2 hello from a raw test client, proving [secret] over the
/// transcript the TV's [challenge] and the client's [key] make.
Map<String, dynamic> rawHello(
  Map<String, dynamic> challenge, {
  required String secret,
  required String mode,
  required String clientId,
  CompanionKey? key,
  String? provedTvKey,
}) => {
  'version': companionPairingVersion,
  'clientId': clientId,
  'mode': mode,
  'proof': companionPairingProof(
    secret,
    label: 'phone',
    mode: mode,
    nonce: challenge['nonce'] as String,
    tvKey: provedTvKey ?? challenge['key'] as String,
    clientKey: key?.publicHex ?? '',
    clientId: clientId,
  ),
  if (key != null) 'key': key.publicHex,
};

/// Starts an Apple receiver and returns it with its pairing details and port.
Future<(AppleCompanion, Map, int)> startReceiver() async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
    if (call.method == 'player')
      return {'active': false, 'appForeground': true};
    return null;
  });
  final tv = AppleCompanion(receiverDevice: () => true);
  addTearDown(() async {
    await tv.invoke('receiverStop', null);
    messenger.setMockMethodCallHandler(AppleCompanion.native, null);
  });
  final receiver = await tv.invoke('receiverStart', null) as Map;
  final port = int.parse(
    (receiver['address'] as String).split('\n').first.split(':').last,
  );
  return (tv, receiver, port);
}

/// A one-connection fake TV: sends [challenge], hands the hello to [answer]
/// and sends back what it returns.
Future<int> fakeTv(
  Map<String, dynamic> challenge,
  Map<String, dynamic> Function(Map<String, dynamic> hello) answer,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  server.listen((socket) async {
    final wire = CompanionWire(socket);
    try {
      wire.send(challenge);
      wire.send(answer(await wire.read()));
      await wire.read(timeout: const Duration(seconds: 5));
    } catch (_) {
    } finally {
      wire.close();
    }
  });
  return server.port;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('HMAC wire proof matches published SHA256 vector', () {
    expect(
      companionProof('key', 'The quick brown fox jumps over the lazy dog'),
      'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
    );
    expect(companionProofMatches('abc', 'abc'), isTrue);
    expect(companionProofMatches('abc', 'ab'), isFalse);
  });

  group('pairing proof v2', () {
    // Shared cross-check vector: CompanionProtocolTest.kt pins the same
    // inputs and outputs, so Kotlin and Dart compute byte-identical proofs.
    final nonce = '0123456789abcdef' * 4;
    final tvKey = '04${'11' * 64}';
    final phoneKey = '04${'22' * 64}';
    const clientId = 'pairing-vector-client-01';
    String proof({
      String secret = '123456',
      String label = 'phone',
      String mode = 'pin',
      String? n,
      String? tv,
      String? phone,
    }) => companionPairingProof(
      secret,
      label: label,
      mode: mode,
      nonce: n ?? nonce,
      tvKey: tv ?? tvKey,
      clientKey: phone ?? phoneKey,
      clientId: clientId,
    );

    test('matches the vector shared with the Kotlin receiver', () {
      expect(
        companionTranscript(
          label: 'phone',
          mode: 'pin',
          nonce: nonce,
          tvKey: tvKey,
          clientKey: phoneKey,
          clientId: clientId,
        ),
        'zangetsu-pair-v2|phone|pin|$nonce|$tvKey|$phoneKey|$clientId',
      );
      expect(
        proof(),
        '628d73ebfb5474bcd555fd5af1286b05f59642ce69bda36677a9a4d120a9c5ff',
      );
      expect(
        proof(label: 'tv'),
        '155534e70efa0388888ddd71d2eb3eb77515676b322035abcf52348fdc043317',
      );
      expect(
        proof(secret: 'tok', mode: 'remembered', phone: ''),
        '0d876c464033436d89b41ff45db5254cdef445f66f483baebc34e7f0b9873661',
      );
      expect(
        proof(phone: '04${'33' * 64}'),
        'db4a0a70dcb4805f078cd13fef5e7819ea066706e008dcf181c84646d98c116d',
      );
    });

    test('binds both keys, the nonce, the code and the role', () {
      final good = proof();
      final swapped = '04${'33' * 64}';
      for (final other in [
        proof(phone: swapped),
        proof(tv: swapped),
        proof(n: 'f' * 64),
        proof(secret: '654321'),
        proof(label: 'tv'),
        // The old nonce-only proof no longer counts.
        companionProof('123456', nonce),
      ]) {
        expect(companionProofMatches(good, other), isFalse);
      }
    });

    test('the TV refuses a swapped key or a version-1 hello', () async {
      final (_, receiver, port) = await startReceiver();
      final qr = receiver['qr'] as String;
      const clientId = 'swapped-key-client-0123';
      Future<Map<String, dynamic>> attempt(
        Map<String, dynamic> Function(Map<String, dynamic> challenge) hello,
      ) async {
        final raw = CompanionWire(await Socket.connect('127.0.0.1', port));
        addTearDown(raw.close);
        raw.send(hello(await raw.read()));
        return raw.read(timeout: const Duration(seconds: 5));
      }

      final phone = CompanionKey.generate();
      final attacker = CompanionKey.generate();
      // Someone on the Wi-Fi gave the phone their key instead of the TV's.
      final tvSwapped = await attempt(
        (c) => rawHello(
          c,
          secret: qr,
          mode: 'qr',
          clientId: clientId,
          key: phone,
          provedTvKey: attacker.publicHex,
        ),
      );
      expect(tvSwapped['type'], isNot('paired'));
      // ...or replaced the phone's key on its way to the TV.
      final phoneSwapped = await attempt(
        (c) => {
          ...rawHello(
            c,
            secret: qr,
            mode: 'qr',
            clientId: clientId,
            key: phone,
          ),
          'key': attacker.publicHex,
        },
      );
      expect(phoneSwapped['type'], isNot('paired'));
      // QR pairing without a phone key is refused.
      final keyless = await attempt(
        (c) => rawHello(c, secret: qr, mode: 'qr', clientId: clientId),
      );
      expect(keyless['type'], isNot('paired'));
      // A version-1 phone proving only the nonce gets a clear error.
      final old = await attempt(
        (c) => {
          'clientId': clientId,
          'mode': 'qr',
          'proof': companionProof(qr, c['nonce'] as String),
        },
      );
      expect(old['error'], companionOldPhoneError);
      // The honest hello still pairs, and the TV proves itself back.
      late Map<String, dynamic> challenge;
      final ok = await attempt(
        (c) => rawHello(
          challenge = c,
          secret: qr,
          mode: 'qr',
          clientId: clientId,
          key: phone,
        ),
      );
      expect(ok['type'], 'paired');
      expect(ok.containsKey('token'), isFalse);
      expect(
        ok['proof'],
        companionPairingProof(
          qr,
          label: 'tv',
          mode: 'qr',
          nonce: challenge['nonce'] as String,
          tvKey: challenge['key'] as String,
          clientKey: phone.publicHex,
          clientId: clientId,
        ),
      );
    });

    test('the phone refuses a TV whose proof covers other keys', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppleCompanion.native, (_) async {
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppleCompanion.native, null),
      );
      final qr = companionSecret();
      final seen = CompanionKey.generate();
      final real = CompanionKey.generate();
      Map<String, dynamic> challenge({int version = companionPairingVersion}) =>
          {
            'type': 'challenge',
            'version': version,
            'deviceId': 'fake-tv',
            'nonce': companionSecret(),
            'name': 'TV',
            'key': seen.publicHex,
          };
      Map<String, dynamic> tvProof(
        Map<String, dynamic> c,
        Map<String, dynamic> hello,
        String tvKey,
      ) => {
        'type': 'paired',
        'deviceId': 'fake-tv',
        'name': 'TV',
        'proof': companionPairingProof(
          qr,
          label: 'tv',
          mode: 'qr',
          nonce: c['nonce'] as String,
          tvKey: tvKey,
          clientKey: hello['key'] as String,
          clientId: hello['clientId'] as String,
        ),
      };
      Future<Object?> connect(int port) async {
        final phone = AppleCompanion(receiverDevice: () => false);
        addTearDown(() => phone.invoke('disconnect', null).catchError((_) {}));
        try {
          await phone.invoke('connect', {
            'address': '127.0.0.1:$port',
            'qr': qr,
          });
          return null;
        } on PlatformException catch (e) {
          return e.message;
        }
      }

      // The TV signs a different key than the one the phone was shown.
      final swappedChallenge = challenge();
      expect(
        await connect(
          await fakeTv(
            swappedChallenge,
            (h) => tvProof(swappedChallenge, h, real.publicHex),
          ),
        ),
        'The TV could not prove its identity. Scan it again.',
      );
      // A receiver that skips the proof and sends a token is refused too.
      expect(
        await connect(
          await fakeTv(
            challenge(),
            (_) => {'type': 'paired', 'deviceId': 'fake-tv', 'token': 'x'},
          ),
        ),
        'The TV could not prove its identity. Scan it again.',
      );
      // A version-1 TV gets a clear error.
      expect(
        await connect(
          await fakeTv(challenge(version: 1), (_) => {'type': 'paired'}),
        ),
        companionOldTvError,
      );
      // The matching proof is accepted.
      final honest = challenge();
      expect(
        await connect(
          await fakeTv(honest, (h) => tvProof(honest, h, seen.publicHex)),
        ),
        isNull,
      );
    });
  });
  test('fragmented frames and sequential commands preserve IDs', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final client = CompanionWire(
      await Socket.connect('127.0.0.1', server.port),
    );
    final socket = await accepted;
    final receiver = CompanionWire(socket);
    addTearDown(() async {
      client.close();
      receiver.close();
      await server.close();
    });
    socket.add(utf8.encode('{"hello":'));
    await socket.flush();
    socket.add(utf8.encode('true}\n'));
    expect(await client.read(), {'hello': true});
    final one = client.exchange({'action': 'next'});
    final two = client.exchange({'action': 'state'});
    final first = await receiver.read();
    expect(first, {'action': 'next', 'id': 1});
    receiver.send({'id': 1, 'ok': true});
    final second = await receiver.read();
    expect(second, {'action': 'state', 'id': 2});
    receiver.send({'id': 2, 'active': true});
    expect((await one)['ok'], isTrue);
    expect((await two)['active'], isTrue);
  });
  test(
    'wrong response ID closes transport without replaying the command',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final client = CompanionWire(
        await Socket.connect('127.0.0.1', server.port),
      );
      final receiver = CompanionWire(await accepted);
      addTearDown(() async {
        client.close();
        receiver.close();
        await server.close();
      });
      final result = client.exchange({'action': 'next'});
      final failure = expectLater(result, throwsStateError);
      await receiver.read();
      receiver.send({'id': 99});
      await failure;
      expect(client.alive, isFalse);
      await expectLater(client.exchange({'action': 'next'}), throwsStateError);
    },
  );
  test('oversized frame is rejected before JSON decoding', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final client = CompanionWire(
      await Socket.connect('127.0.0.1', server.port),
    );
    final socket = await accepted;
    addTearDown(() async {
      client.close();
      socket.destroy();
      await server.close();
    });
    final failure = expectLater(client.read(), throwsFormatException);
    socket.add(List.filled(262145, 65));
    await failure;
    expect(client.alive, isFalse);
  });
  test(
    'Apple receiver accepts Android-compatible QR and remembered handshakes',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'player')
          return {'active': false, 'appForeground': true};
        return null;
      });
      final tv = AppleCompanion(receiverDevice: () => true);
      final phone = AppleCompanion();
      addTearDown(() async {
        await phone.invoke('disconnect', null);
        await tv.invoke('receiverStop', null);
        messenger.setMockMethodCallHandler(AppleCompanion.native, null);
      });
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
      expect(challenge['version'], companionPairingVersion);
      const clientId = 'android-compatible-client-123';
      final key = CompanionKey.generate();
      raw.send(
        rawHello(
          challenge,
          secret: receiver['qr'] as String,
          mode: 'qr',
          clientId: clientId,
          key: key,
        ),
      );
      final paired = await raw.read();
      expect(paired['type'], 'paired');
      expect(paired.containsKey('token'), isFalse);
      final token = companionPairingToken(
        key.shared(challenge['key'] as String),
        challenge['nonce'] as String,
        clientId,
      );
      final state = await raw.exchange({'action': 'state'});
      expect(state['appForeground'], isTrue);
      raw.close();
      final remembered = CompanionWire(
        await Socket.connect('127.0.0.1', int.parse(port)),
      );
      final nextChallenge = await remembered.read();
      remembered.send(
        rawHello(
          nextChallenge,
          secret: token,
          mode: 'remembered',
          clientId: clientId,
        ),
      );
      final again = await remembered.read();
      expect(again['type'], 'paired');
      // The reconnect is mutual too: the TV proves the token back.
      expect(
        again['proof'],
        companionPairingProof(
          token,
          label: 'tv',
          mode: 'remembered',
          nonce: nextChallenge['nonce'] as String,
          tvKey: nextChallenge['key'] as String,
          clientKey: '',
          clientId: clientId,
        ),
      );
      remembered.close();
      await phone.invoke('connect', {
        'address': '127.0.0.1:$port',
        'qr': receiver['qr'],
      });
      final response =
          jsonDecode(
                await phone.invoke('command', '{"action":"state"}') as String,
              )
              as Map;
      expect(response['active'], isFalse);
      expect(
        (await phone.invoke('connectionState', null) as Map)['connected'],
        isTrue,
      );
    },
  );
  test('pairing key matches an OpenSSL P-256 ECDH vector', () {
    // Generated with Node's crypto.createECDH('prime256v1'), the same
    // uncompressed-point and X-coordinate format the Kotlin receiver uses.
    final a = CompanionKey.fromPrivateHex(
      '35543e7cc5811f3aa406d1456eeedb4832f33f348c9e3500d4cff8d12e4f8936',
    );
    expect(
      a.publicHex,
      '04230d2243c5cebb467adc5e652f909ef7099dc746d703424fcfca0e56e3b3c7d3'
      'b5291ae49c5a6f7928465493173f3b0d29619343e8759f029b469eb55a40faae',
    );
    final shared = a.shared(
      '0454afffe997b2725d1ec2410454eee6bfb4609876401fe44a2da5ff42bdc63d2f'
      '7d39204e8a750ee22507e9e270a691e1f212f658c4e8c4adab5be01bb55af35e',
    );
    expect(
      shared,
      '97924e3a767153b644bd1ded26dfe753fd131b024c1f197adedfb9e11625f2f3',
    );
    expect(
      companionPairingToken(shared, 'n0nce', 'client-0123456789abcdef'),
      '21e28a2bc0e00ae7af60a500c8be22a87201304b975343b566b1bd1da35cb2fd',
    );
    final b = CompanionKey.generate();
    expect(a.shared(b.publicHex), b.shared(a.publicHex));
    // A point off the curve is refused.
    expect(() => a.shared('04${'1' * 128}'), throwsA(isA<FormatException>()));
  });
  test(
    'PIN pairing derives the token without sending it and retires the PIN',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppleCompanion.native, (call) async {
        if (call.method == 'player')
          return {'active': false, 'appForeground': true};
        return null;
      });
      final tv = AppleCompanion(receiverDevice: () => true);
      addTearDown(() async {
        await tv.invoke('receiverStop', null);
        messenger.setMockMethodCallHandler(AppleCompanion.native, null);
      });
      final receiver = await tv.invoke('receiverStart', null) as Map;
      final port = int.parse(
        (receiver['address'] as String).split('\n').first.split(':').last,
      );
      const clientId = 'pin-client-0123456789';
      final pin = receiver['pin'] as String;
      final raw = CompanionWire(await Socket.connect('127.0.0.1', port));
      final challenge = await raw.read();
      final key = CompanionKey.generate();
      raw.send(
        rawHello(
          challenge,
          secret: pin,
          mode: 'pin',
          clientId: clientId,
          key: key,
        ),
      );
      final paired = await raw.read();
      expect(paired['type'], 'paired');
      expect(paired.containsKey('token'), isFalse);
      raw.close();
      final token = companionPairingToken(
        key.shared(challenge['key'] as String),
        challenge['nonce'] as String,
        clientId,
      );
      final again = CompanionWire(await Socket.connect('127.0.0.1', port));
      final next = await again.read();
      again.send(
        rawHello(next, secret: token, mode: 'remembered', clientId: clientId),
      );
      expect((await again.read())['type'], 'paired');
      again.close();
      final after = await tv.invoke('receiverState', null) as Map;
      expect(after['pin'], isNot(pin));
    },
  );
}
