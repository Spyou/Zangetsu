import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/environment.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/mangabaka_service.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/cubit/tracker_home_rows.dart';

/// MangaBaka is the only PUBLIC OAuth client of the four trackers — PKCE, no
/// secret — so the verifier/challenge maths is ours to get right, not a
/// library's. The rest covers the tolerance the interface demands: reads are
/// best-effort and must never throw.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late MangaBakaService svc;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mangabaka_test');
    Hive.init(dir.path);
    await MangaBakaService.init();
    svc = MangaBakaService(Dio());
  });

  tearDown(() async {
    svc.dispose();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('PKCE', () {
    test('the verifier is RFC 7636 legal and different every time', () {
      final a = MangaBakaService.newVerifier();
      final b = MangaBakaService.newVerifier();
      expect(a, isNot(b), reason: 'reusing one would defeat PKCE entirely');
      for (final v in [a, b]) {
        expect(v.length, greaterThanOrEqualTo(43));
        expect(v.length, lessThanOrEqualTo(128));
        expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(v), isTrue,
            reason: 'unreserved characters only: $v');
      }
    });

    test('the challenge is unpadded base64url of SHA-256, as S256 requires',
        () {
      const v = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final expected =
          base64Url.encode(sha256.convert(ascii.encode(v)).bytes)
              .replaceAll('=', '');
      final got = MangaBakaService.challengeFor(v);
      expect(got, expected);
      expect(got.contains('='), isFalse, reason: 'padding breaks S256');
      expect(got, isNot(v), reason: 'sending the verifier itself is the bug');
    });
  });

  group('status mapping', () {
    test('reading maps to watching — the wording differs, the meaning does not',
        () {
      expect(MangaBakaService.statusFrom('reading'), WatchStatus.watching);
      expect(MangaBakaService.statusFrom('completed'), WatchStatus.completed);
      expect(MangaBakaService.statusFrom('on_hold'), WatchStatus.paused);
      expect(MangaBakaService.statusFrom('dropped'), WatchStatus.dropped);
    });

    test('case and whitespace do not decide it', () {
      expect(MangaBakaService.statusFrom('  READING '), WatchStatus.watching);
    });

    test('an unknown status falls back instead of throwing', () {
      // The real spellings are unverified; one odd value must not take down a
      // whole library fetch.
      expect(MangaBakaService.statusFrom('something_new'), WatchStatus.planning);
      expect(MangaBakaService.statusFrom(null), WatchStatus.planning);
      expect(MangaBakaService.statusFrom(42), WatchStatus.planning);
    });

    test('the spellings are the API\'s own, not conventional guesses', () {
      // Both confirmed live: a row's `state` came back as `reading`, and the
      // profile's `library_default_state` as `plan_to_read`. The conventional
      // guesses ("planning", "watching") are wrong here.
      expect(MangaBakaService.statusOut[WatchStatus.planning], 'plan_to_read');
      expect(MangaBakaService.statusOut[WatchStatus.watching], 'reading');
    });

    test('a status round-trips out and back', () {
      for (final s in WatchStatus.values) {
        expect(MangaBakaService.statusFrom(MangaBakaService.statusOut[s]), s,
            reason: '$s must survive a write followed by a read');
      }
    });

    test('every WatchStatus has an outgoing spelling', () {
      for (final s in WatchStatus.values) {
        expect(MangaBakaService.statusOut[s], isNotNull, reason: '$s');
      }
    });
  });

  group('disconnected behaviour', () {
    test('starts disconnected with no viewer', () {
      expect(svc.isConnected, isFalse);
      expect(svc.viewerName, isNull);
      expect(svc.exportSession(), isNull, reason: 'nothing to relay');
    });

    test('fetchList returns empty rather than throwing', () async {
      expect(await svc.fetchList(), isEmpty);
    });

    test('every write is a silent no-op', () async {
      // Deliberately unimplemented until the real payloads are captured — a
      // GUESSED write corrupts a real library, which is worse than no write.
      await svc.scrobble(title: 'X', episode: 3, kind: MediaKind.manga);
      await svc.setStatus(title: 'X', status: WatchStatus.completed);
      await svc.updateEntry(title: 'X', progress: 5);
      await svc.removeFromList(title: 'X');
      expect(svc.isConnected, isFalse);
    });

    test('an empty search query never hits the network', () async {
      expect(await svc.searchEntries('   '), isEmpty);
    });
  });

  group('session relay', () {
    test('a session round-trips for the TV relay', () async {
      await svc.importSession({
        'accessToken': 'tok',
        'refreshToken': 'ref',
        'viewerName': 'krishna',
      });
      expect(svc.isConnected, isTrue);
      expect(svc.viewerName, 'krishna');
      final out = svc.exportSession();
      expect(out?['accessToken'], 'tok');
      expect(out?['refreshToken'], 'ref');
    });

    test('disconnect clears the token and the viewer', () async {
      await svc.importSession({'accessToken': 'tok', 'viewerName': 'k'});
      await svc.disconnect();
      expect(svc.isConnected, isFalse);
      expect(svc.viewerName, isNull);
    });
  });

  group('it is reading-only — it has no anime library', () {
    test('it claims a reading library and no video one', () {
      expect(svc.supportsReading, isTrue);
      expect(trackerSupportsVideo(svc), isFalse);
      expect(svc.displayName, 'MangaBaka');
    });

    test('a watching mode does not offer it; a reading mode does', () {
      final hub = TrackerHub([svc]);
      expect(hub.forMode(ContentMode.anime), isEmpty);
      expect(hub.forMode(ContentMode.manga), [svc]);
      expect(hub.forMode(ContentMode.novel), [svc]);
    });

    test('it answers no home row for anime, film or series', () {
      expect(trackerServesKind(svc, ZKind.anime), isFalse);
      expect(trackerServesKind(svc, ZKind.movie), isFalse);
      expect(trackerServesKind(svc, ZKind.tv), isFalse);
      expect(trackerServesKind(svc, ZKind.manga), isTrue);
      expect(trackerServesKind(svc, ZKind.novel), isTrue);
    });
  });

  // MangaBaka rates 0-100, the sheet is 0-10. The two halves have to agree or
  // the bug gets worse, not better: write-only shows 86/10, read-only stores
  // every score at 0.8/10.
  group('rating scale', () {
    test('the app score is scaled up on the way out', () {
      expect(MangaBakaService.ratingOut(8), 80);
      expect(MangaBakaService.ratingOut(10), 100);
      expect(MangaBakaService.ratingOut(0), 0);
      expect(MangaBakaService.ratingOut(7.5), 75);
    });

    test("MangaBaka's rating is scaled down on the way in", () {
      // The real value the live API returns for ONE-PUNCH MAN.
      expect(MangaBakaService.ratingIn(86.6237142857143), closeTo(8.66, 0.01));
      expect(MangaBakaService.ratingIn(100), 10);
      expect(MangaBakaService.ratingIn(0), 0);
    });

    test('a round trip returns the score it started with', () {
      for (var i = 0; i <= 10; i++) {
        expect(MangaBakaService.ratingIn(MangaBakaService.ratingOut(i.toDouble())),
            i.toDouble());
      }
    });

    test('a value outside the scale is clamped, never sent wild', () {
      expect(MangaBakaService.ratingOut(99), 100);
      expect(MangaBakaService.ratingOut(-3), 0);
      expect(MangaBakaService.ratingIn(9999), 10);
    });
  });

  test('the registered client is public: the id ships, no secret exists', () {
    expect(Environment.mangabakaClientId, isNotEmpty);
    expect(Environment.mangabakaRedirectUri, 'zangetsu://mangabaka-auth');
    expect(Environment.mangabakaScopes, contains('library.write'));
    expect(Environment.mangabakaScopes, contains('offline_access'));
  });
}
