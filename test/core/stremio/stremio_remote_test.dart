import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/stremio/stremio_remote.dart';
import 'package:watch_app/core/stremio/stremio_backup_cipher.dart';

class Adapter implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  Completer<void>? hold;
  int status = 200;
  String body = '{"version":0,"accepted":true,"configuration":null}';
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    calls.add(options);
    await hold?.future;
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Adapter adapter;
  late StremioRemote remote;
  late String? owner;
  setUp(() {
    owner = 'account-a';
    adapter = Adapter();
    remote = StremioRemote(
      endpoint: Uri.parse('https://sync.test'),
      accessToken: () => 'test-only-token',
      currentUserId: () => owner,
      client: Dio()..httpClientAdapter = adapter,
    );
  });
  tearDown(() => remote.dispose());
  test(
    'uses the authenticated fixed route and preserves the response',
    () async {
      final result = await remote.request('account-a', 'configuration', {});
      expect(result['version'], 0);
      expect(
        adapter.calls.single.uri.toString(),
        'https://sync.test/stremio/v1/configuration',
      );
      expect(
        adapter.calls.single.headers['Authorization'],
        'Bearer test-only-token',
      );
      expect(jsonDecode(adapter.calls.single.data as String), {});
      await expectLater(
        remote.request('account-b', 'configuration', {}),
        throwsA(isA<StremioBackupException>()),
      );
      expect(adapter.calls, hasLength(1));
    },
  );
  test('a late response after account switching is rejected', () async {
    adapter.hold = Completer<void>();
    final pending = remote.request('account-a', 'configuration', {});
    final expectation = expectLater(
      pending,
      throwsA(isA<StremioBackupException>()),
    );
    await Future<void>.delayed(Duration.zero);
    owner = 'account-b';
    adapter.hold!.complete();
    await expectation;
  });
  test(
    'server failures never expose request tokens or response secrets',
    () async {
      adapter.status = 500;
      adapter.body = 'private-token';
      await expectLater(
        remote.request('account-a', 'seal', {'url': 'private-url'}),
        throwsA(
          isA<StremioBackupException>().having(
            (error) => error.toString(),
            'message',
            isNot(anyOf(contains('private-token'), contains('private-url'))),
          ),
        ),
      );
    },
  );
}
