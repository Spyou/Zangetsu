import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/discord/discord_config.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';

class _DiscordAdapter implements HttpClientAdapter {
  int exchanges = 0;
  final accountFetched = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final token = options.path.endsWith('/token');
    if (token) {
      exchanges++;
    } else if (!accountFetched.isCompleted) {
      accountFetched.complete();
    }
    return ResponseBody.fromString(
      jsonEncode(
        token
            ? {
                'access_token': 'test-access',
                'refresh_token': 'test-refresh',
                'expires_in': 3600,
              }
            : {'id': '123', 'username': 'tester'},
      ),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'fast native callbacks complete once; browser fallback and denial finish',
    () async {
      final dir = await Directory.systemTemp.createTemp('discord_login');
      Hive.init(dir.path);
      await Hive.openBox(DiscordRpc.boxName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      const links = MethodChannel('com.llfbandit.app_links/messages');
      const events = MethodChannel('com.llfbandit.app_links/events');
      messenger.setMockMethodCallHandler(links, (_) async => null);
      messenger.setMockMethodCallHandler(events, (_) async => null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final adapter = _DiscordAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final rpc = DiscordRpc(dio);
      final launched = <Uri>[];

      Future<void> emit(Uri uri) async {
        final delivered = Completer<void>();
        messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope(uri.toString()),
          (_) => delivered.complete(),
        );
        await delivered.future;
      }

      try {
        messenger.setMockMethodCallHandler(launcher, (call) async {
          final uri = Uri.parse((call.arguments as Map)['url'] as String);
          launched.add(uri);
          final callback =
              Uri.parse(
                'discord-${DiscordConfig.applicationId}:/authorize/callback',
              ).replace(
                queryParameters: {
                  'state': uri.queryParameters['state']!,
                  'code': 'test-code',
                },
              );
          await emit(
            callback.replace(
              queryParameters: {'state': 'stale', 'code': 'wrong'},
            ),
          );
          await emit(callback);
          await emit(callback);
          await adapter.accountFetched.future;
          // The OS launch result may arrive after the whole redirect exchange.
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return true;
        });
        expect(await rpc.connect().timeout(const Duration(seconds: 5)), isTrue);
        expect(launched.single.scheme, 'discord');
        expect(adapter.exchanges, 1);
        expect(rpc.loggedIn, isTrue);
        expect(Hive.box(DiscordRpc.boxName).get('oauthState'), isNull);

        launched.clear();
        messenger.setMockMethodCallHandler(launcher, (call) async {
          final uri = Uri.parse((call.arguments as Map)['url'] as String);
          launched.add(uri);
          if (uri.scheme == 'discord') throw PlatformException(code: 'NO_APP');
          await emit(
            Uri.parse(
              'discord-${DiscordConfig.applicationId}:/authorize/callback',
            ).replace(
              queryParameters: {
                'state': uri.queryParameters['state']!,
                'error': 'access_denied',
              },
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return true;
        });
        expect(
          await rpc.connect().timeout(const Duration(seconds: 5)),
          isFalse,
        );
        expect(launched.map((u) => u.scheme), ['discord', 'https']);
        expect(rpc.lastAuthError, 'access_denied');
        expect(Hive.box(DiscordRpc.boxName).get('codeVerifier'), isNull);

        messenger.setMockMethodCallHandler(launcher, (_) async => false);
        expect(await rpc.connect(), isFalse);
        expect(rpc.lastAuthError, contains('Could not open'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(launcher, null);
        messenger.setMockMethodCallHandler(links, null);
        messenger.setMockMethodCallHandler(events, null);
        dio.close();
        await Hive.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
