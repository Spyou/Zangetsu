import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/debrid/debrid_prefs.dart';
import 'package:watch_app/core/debrid/debrid_provider.dart';
import 'package:watch_app/core/debrid/debrid_resolver.dart';
import 'package:watch_app/core/debrid/debrid_result.dart';
import 'package:watch_app/core/debrid/playable_torrent.dart';

class _FakeClient implements DebridClient {
  _FakeClient(
    this.service, {
    this.result,
    this.error,
  });

  @override
  final DebridService service;
  final DebridResolved? result;
  final DebridException? error;
  int resolveCalls = 0;
  bool? lastRequireCached;

  @override
  Future<bool> validateToken(String token) async => token.isNotEmpty;

  @override
  Future<DebridResolved> resolve(
    String uri, {
    required String token,
    required Duration timeout,
    bool requireCached = false,
    void Function(String phase)? onPhase,
  }) async {
    resolveCalls++;
    lastRequireCached = requireCached;
    onPhase?.call(service.phaseLabel);
    if (error != null) throw error!;
    return result!;
  }
}

void main() {
  late Directory dir;
  late DebridPrefs prefs;
  late Map<DebridService, String?> tokens;
  late _FakeClient rd;
  late _FakeClient tb;
  late DebridResolver resolver;

  DebridResolver build() => DebridResolver(
        prefs: prefs,
        readToken: (s) async => tokens[s],
        realDebrid: rd,
        torbox: tb,
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    await Hive.openBox(DebridPrefs.boxName);
    prefs = DebridPrefs();
    tokens = {};
    rd = _FakeClient(
      DebridService.realDebrid,
      result: const DebridResolved(url: 'https://rd.example/v.mp4'),
    );
    tb = _FakeClient(
      DebridService.torbox,
      result: const DebridResolved(url: 'https://tb.example/v.mkv'),
    );
    resolver = build();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  const magnet =
      'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';

  test('Off skips debrid even with a token', () async {
    await prefs.setMode(DebridMode.off);
    tokens[DebridService.realDebrid] = 'rd-token';
    expect(await resolver.resolve(magnet), isA<DebridSkipped>());
    expect(rd.resolveCalls, 0);
  });

  test('Prefer with no token skips', () async {
    await prefs.setMode(DebridMode.prefer);
    expect(await resolver.resolve(magnet), isA<DebridSkipped>());
    expect(rd.resolveCalls, 0);
  });

  test('Prefer fail (not cached) returns Failed; fallback is allowed',
      () async {
    await prefs.setMode(DebridMode.prefer);
    tokens[DebridService.realDebrid] = 'rd-token';
    rd = _FakeClient(
      DebridService.realDebrid,
      error: const DebridException(DebridFailure.notCached, 'not cached'),
    );
    resolver = build();
    final attempt = await resolver.resolve(magnet);
    expect(attempt, isA<DebridFailed>());
    expect((attempt as DebridFailed).error.kind, DebridFailure.notCached);
    expect(rd.lastRequireCached, isTrue);
    expect(shouldFallbackToLocal(attempt, DebridMode.prefer), isTrue);
  });

  test('Prefer success returns HTTP url and requireCached', () async {
    await prefs.setMode(DebridMode.prefer);
    tokens[DebridService.realDebrid] = 'rd-token';
    final attempt = await resolver.resolve(magnet);
    expect(attempt, isA<DebridOk>());
    expect((attempt as DebridOk).resolved.url, 'https://rd.example/v.mp4');
    expect(rd.lastRequireCached, isTrue);
    expect(tb.resolveCalls, 0);
  });

  test('Always with no token is an auth error; no local fallback', () async {
    await prefs.setMode(DebridMode.always);
    final attempt = await resolver.resolve(magnet);
    expect(attempt, isA<DebridFailed>());
    expect((attempt as DebridFailed).error.kind, DebridFailure.auth);
    expect(shouldFallbackToLocal(attempt, DebridMode.always), isFalse);
    expect(rd.resolveCalls, 0);
  });

  test('Always fail does not fall back to local', () async {
    await prefs.setMode(DebridMode.always);
    tokens[DebridService.realDebrid] = 'rd-token';
    rd = _FakeClient(
      DebridService.realDebrid,
      error: const DebridException(DebridFailure.auth, 'bad token'),
    );
    resolver = build();
    final attempt = await resolver.resolve(magnet);
    expect(shouldFallbackToLocal(attempt, DebridMode.always), isFalse);
    expect(rd.lastRequireCached, isFalse);
  });

  test('uses TorBox when it is the active connected service', () async {
    await prefs.setMode(DebridMode.prefer);
    tokens[DebridService.realDebrid] = 'rd-token';
    tokens[DebridService.torbox] = 'tb-token';
    await prefs.setActiveService(DebridService.torbox);
    resolver = build();
    final attempt = await resolver.resolve(magnet);
    expect(attempt, isA<DebridOk>());
    expect((attempt as DebridOk).resolved.url, 'https://tb.example/v.mkv');
    expect(rd.resolveCalls, 0);
    expect(tb.resolveCalls, 1);
  });

  test('falls back to first connected when active has no token', () async {
    await prefs.setMode(DebridMode.always);
    tokens[DebridService.torbox] = 'tb-token';
    await prefs.setActiveService(DebridService.realDebrid);
    resolver = build();
    final attempt = await resolver.resolve(magnet);
    expect((attempt as DebridOk).resolved.url, 'https://tb.example/v.mkv');
  });
}
