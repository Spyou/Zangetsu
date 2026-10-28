import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestClient;
import 'package:watch_app/core/profiles/profile_lock_remote.dart';

void main() {
  late HttpServer server;
  late PostgrestClient client;
  late PostgrestProfileLockRemote remote;
  final tokens = <String?>[];
  final bodies = <Map<String, dynamic>>[];
  String? token;
  var status = 200;
  var response = <String, dynamic>{};
  setUp(() async {
    tokens.clear();
    bodies.clear();
    token = 'first';
    status = 200;
    response = {'ok': true};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/rpc/profile_lock');
      expect(request.uri.query, isEmpty);
      tokens.add(request.headers.value('authorization'));
      bodies.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    client = PostgrestClient('http://127.0.0.1:${server.port}');
    remote = PostgrestProfileLockRemote(client, () => token);
  });
  tearDown(() async {
    await client.dispose();
    await server.close(force: true);
  });

  test(
    'PIN stays in the POST body and each request uses the current JWT',
    () async {
      await remote.request('unlock', profileId: 'private', pin: '1234');
      token = 'refreshed';
      await remote.request('status', profileId: 'private');
      expect(tokens, ['Bearer first', 'Bearer refreshed']);
      expect(bodies.first['p_pin'], '1234');
      expect(bodies.first.containsKey('user_key'), isFalse);
    },
  );
  test('missing login never contacts the server', () async {
    token = null;
    await expectLater(
      remote.request('status'),
      throwsA(isA<ProfileLockException>()),
    );
    expect(tokens, isEmpty);
  });
  test('HTTP failures do not leak server details or credentials', () async {
    status = 403;
    response = {'code': 'PT403', 'message': 'private secret 1234'};
    try {
      await remote.request('unlock', pin: '1234');
      fail('expected failure');
    } on ProfileLockException catch (error) {
      expect(error.code, 'profile_locked');
      expect(error.toString(), isNot(contains('1234')));
    }
  });
  test('structured cooldown is preserved', () async {
    response = {'ok': false, 'error': 'rate_limited', 'retry_after': 30};
    await expectLater(
      remote.request('unlock', pin: '1234'),
      throwsA(
        isA<ProfileLockException>().having((e) => e.retryAfter, 'retry', 30),
      ),
    );
  });
}
