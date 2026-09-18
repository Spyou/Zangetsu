import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/companion/apple_companion.dart';
import 'package:watch_app/features/companion/companion_wire.dart';

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
      const clientId = 'android-compatible-client-123';
      raw.send({
        'clientId': clientId,
        'mode': 'qr',
        'proof': companionProof(
          receiver['qr'] as String,
          challenge['nonce'] as String,
        ),
      });
      final paired = await raw.read();
      expect(paired['type'], 'paired');
      expect(paired['token'], hasLength(64));
      final state = await raw.exchange({'action': 'state'});
      expect(state['appForeground'], isTrue);
      raw.close();
      final remembered = CompanionWire(
        await Socket.connect('127.0.0.1', int.parse(port)),
      );
      final nextChallenge = await remembered.read();
      remembered.send({
        'clientId': clientId,
        'mode': 'remembered',
        'proof': companionProof(
          paired['token'] as String,
          nextChallenge['nonce'] as String,
        ),
      });
      expect((await remembered.read())['type'], 'paired');
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
}
