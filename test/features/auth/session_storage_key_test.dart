import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:watch_app/core/environment.dart';

// supabase_flutter derives the default persisted-session key from the FIRST
// hostname segment of the API URL (see its initialize()); changing the URL
// would therefore abandon every installed user's saved login. These tests pin
// the contract that keeps the Cloud-era storage key across the URL switch.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pinned session storage key', () {
    test('matches the SDK derivation for the current Cloud URL', () {
      final derived =
          'sb-${Uri.parse('https://eogwzrlfoercfwcfwlmv.supabase.co').host.split('.').first}-auth-token';
      expect(Environment.supabaseSessionStorageKey, derived);
    });

    test('differs from what a destination URL would derive', () {
      // Documents the hazard the pin prevents: without the explicit
      // localStorage override, sb.zangetsu.online derives a different key
      // and the saved session would be invisible to the app.
      const destinationUrl = 'https://sb.zangetsu.online';
      final destinationDerived =
          'sb-${Uri.parse(destinationUrl).host.split('.').first}-auth-token';
      expect(destinationDerived, isNot(Environment.supabaseSessionStorageKey));
    });
  });

  group('SharedPreferencesLocalStorage round-trip', () {
    test('persists and restores a session under the pinned key', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = SharedPreferencesLocalStorage(
        persistSessionKey: Environment.supabaseSessionStorageKey,
      );
      await storage.initialize();

      expect(await storage.hasAccessToken(), isFalse);
      const sessionJson = '{"access_token":"a.b.c","user":{"id":"u1"}}';
      await storage.persistSession(sessionJson);

      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), sessionJson);

      // A second storage instance (simulating the retry-init path / next
      // launch) must read the same persisted session from the same key.
      final second = SharedPreferencesLocalStorage(
        persistSessionKey: Environment.supabaseSessionStorageKey,
      );
      await second.initialize();
      expect(await second.accessToken(), sessionJson);
    });

    test('removePersistedSession clears the pinned key', () async {
      SharedPreferences.setMockInitialValues({
        Environment.supabaseSessionStorageKey: '{"access_token":"x"}',
      });
      final storage = SharedPreferencesLocalStorage(
        persistSessionKey: Environment.supabaseSessionStorageKey,
      );
      await storage.initialize();
      expect(await storage.hasAccessToken(), isTrue);
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), isFalse);
    });
  });

  group('both Supabase.initialize paths pin the key', () {
    test('boot and retry initializers both pass the pinned localStorage', () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final occurrences =
          'persistSessionKey: Environment.supabaseSessionStorageKey'
              .allMatches(mainSource)
              .length;
      expect(
        occurrences,
        2,
        reason:
            'Both Supabase.initialize calls (boot + _retrySupabaseInit) '
            'must override the session storage key; if an initializer '
            'loses the override, a URL switch would silently strand the '
            'installed session.',
      );
    });
  });
}
