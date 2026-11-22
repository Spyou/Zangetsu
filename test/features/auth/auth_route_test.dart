import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_app/core/environment.dart';
import 'package:watch_app/core/supabase/auth_route.dart';

String anonKey([String role = 'anon']) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode({'role': role})))}.signature';

Map<String, dynamic> manifest({
  int generation = 1,
  String authority = 'vps',
  String? key,
}) => {
  'schema': 1,
  'generation': generation,
  'authority': authority,
  'anonKey': key ?? anonKey(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  AuthRouteResolver resolver(Map<String, dynamic>? data) => AuthRouteResolver(
    preferences: prefs,
    client: MockClient((request) async {
      expect(request.followRedirects, isFalse);
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.url.host, 'sync.AniAura.online');
      return http.Response(
        data == null ? '' : jsonEncode(data),
        data == null ? 404 : 200,
      );
    }),
  );

  test('missing manifest preserves current Cloud configuration', () async {
    final decision = await resolver(null).resolve();
    expect(decision.route.url, Environment.supabaseUrl);
    expect(decision.route.anonKey, Environment.supabaseAnonKey);
    expect(decision.changed, isFalse);
  });

  test('selects and caches VPS endpoint and public key together', () async {
    final decision = await resolver(manifest()).resolve();
    expect(decision.route.url, 'https://sb.AniAura.online');
    expect(decision.route.anonKey, anonKey());
    expect(decision.changed, isTrue);
    expect(prefs.getString(AuthRouteResolver.cacheKey), isNotNull);
  });

  test(
    'cached VPS survives unavailable config without repeating transition',
    () async {
      await resolver(manifest()).resolve();
      final decision = await resolver(null).resolve();
      expect(decision.route.authority, 'vps');
      expect(decision.changed, isFalse);
    },
  );

  test('VPS never returns to Cloud even with a newer generation', () async {
    await resolver(manifest()).resolve();
    final decision = await resolver(
      manifest(generation: 2, authority: 'cloud'),
    ).resolve();
    expect(decision.route.authority, 'vps');
  });

  test(
    'stale or conflicting same-generation keys cannot replace cache',
    () async {
      await resolver(manifest(generation: 3)).resolve();
      for (final generation in [2, 3]) {
        final decision = await resolver(
          manifest(generation: generation, key: anonKey('other')),
        ).resolve();
        expect(decision.route.anonKey, anonKey());
        expect(decision.route.generation, 3);
      }
    },
  );

  test('only public anonymous keys are accepted', () async {
    for (final key in [
      anonKey('service_role'),
      'sb_secret_invalid',
      '',
      'invalid',
    ]) {
      final decision = await resolver(manifest(key: key)).resolve();
      expect(decision.route.authority, 'cloud');
      expect(prefs.getString(AuthRouteResolver.cacheKey), isNull);
    }
  });

  test('rejects unknown authority, schema and invalid generation', () async {
    for (final data in [
      {...manifest(), 'authority': 'https://invalid.example'},
      {...manifest(), 'schema': 2},
      {...manifest(), 'schema': 1.0},
      {...manifest(), 'generation': -1},
      {...manifest(), 'generation': 1.5},
      {...manifest(), 'url': 'https://invalid.example'},
    ]) {
      final decision = await resolver(data).resolve();
      expect(decision.route.authority, 'cloud');
    }
  });

  test('opaque publishable keys are accepted', () async {
    final decision = await resolver(
      manifest(key: 'sb_publishable_public-test-key'),
    ).resolve();
    expect(decision.route.authority, 'vps');
  });

  test('oversized cached settings fail closed', () async {
    await prefs.setString(AuthRouteResolver.cacheKey, 'x' * 17000);
    await expectLater(resolver(null).resolve(), throwsFormatException);
  });

  test('network exceptions preserve a migrated device', () async {
    await resolver(manifest()).resolve();
    final offline = AuthRouteResolver(
      preferences: prefs,
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    expect((await offline.resolve()).route.authority, 'vps');
  });

  test('timeout retains cache within the startup budget', () async {
    await resolver(manifest()).resolve();
    final slow = AuthRouteResolver(
      preferences: prefs,
      client: MockClient(
        (_) => Future<http.Response>.delayed(
          const Duration(milliseconds: 60),
          () => http.Response('', 500),
        ),
      ),
      timeout: const Duration(milliseconds: 1),
    );
    expect((await slow.resolve()).route.authority, 'vps');
  });

  test('corrupted cache fails closed rather than reverting to Cloud', () async {
    await prefs.setString(AuthRouteResolver.cacheKey, '{broken');
    await expectLater(resolver(null).resolve(), throwsFormatException);
  });

  test('corrupted cache never accepts a Cloud fallback', () async {
    await prefs.setString(AuthRouteResolver.cacheKey, '{broken');
    await expectLater(
      resolver(manifest(authority: 'cloud')).resolve(),
      throwsFormatException,
    );
  });

  test('valid network settings repair corrupted cached settings', () async {
    await prefs.setString(AuthRouteResolver.cacheKey, '{broken');
    final decision = await resolver(manifest()).resolve();
    expect(decision.route.authority, 'vps');
  });

  test('redirect and oversized body do not change authority', () async {
    for (final response in [
      http.Response('', 302),
      http.Response('x' * 17000, 200),
    ]) {
      final result = await AuthRouteResolver(
        preferences: prefs,
        client: MockClient((_) async => response),
      ).resolve();
      expect(result.route.authority, 'cloud');
    }
  });
}
