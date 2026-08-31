// Task 23: the "Solve Cloudflare" action on a CloudStream source opened the
// WRONG domain — the value of `MainAPI.mainUrl` captured when the plugin was
// LISTED (installedApis(), Task 22), not the domain the plugin has since
// rewritten `mainUrl` to after resolving it at runtime (e.g. NetMirror-style
// sources that fetch a redirect list). [SourceRepository.cfSolveTargetFor] is
// the fix: it prefers a host [CfSolveNeeded] actually saw challenged, then
// the plugin's CURRENT mainUrl (native round trip via `liveMainUrl`), then
// the cached listing value, and returns null (hide the action) only when
// none of those is usable.

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';

const _channel = MethodChannel('zangetsu/cloudstream');

/// Installs one CS source ("cs:Test") with [cachedMainUrl] as the value
/// captured at listing time — the same shape `installedApis()` sends and
/// [CloudStreamManager.rebuildFromForTest] already exists to accept without a
/// platform-channel round trip.
CloudStreamManager _csWith(String cachedMainUrl) {
  final cs = CloudStreamManager();
  cs.rebuildFromForTest([
    {
      'name': 'Test',
      'lang': 'en',
      'hasMainPage': true,
      'types': ['Movie'],
      'sourcePlugin': 'TestPlugin@1',
      'mainUrl': cachedMainUrl,
    },
  ]);
  return cs;
}

SourceRepository _repoWith(CloudStreamManager cs) => SourceRepository(
  manager: ProviderManager(dio: Dio()),
  csManager: cs,
  aniManager: AniyomiManager(),
  activeSource: ActiveSourceCubit(),
  prefs: PlaybackPrefs(),
);

void main() {
  // ProviderManager eagerly spins up the QuickJS runtime in its constructor.
  TestWidgetsFlutterBinding.ensureInitialized();

  const sourceId = 'cs:Test';

  tearDown(() {
    CfSolveNeeded.clear('challenged.test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('prefers a recorded challenge url over mainUrl entirely', () async {
    CfSolveNeeded.needsSolve(
      'challenged.test',
      'https://challenged.test/path',
      sourceId: sourceId,
    );
    // No handler installed for 'liveMainUrl' — if the resolver reached for it
    // first this would throw past the recorded-url short-circuit.
    final repo = _repoWith(_csWith('https://stale-listing.test'));

    expect(
      await repo.cfSolveTargetFor(sourceId),
      'https://challenged.test/path',
    );
  });

  test('falls back to the live mainUrl when no challenge is recorded', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'liveMainUrl') return 'https://live-domain.test';
      return null;
    });
    final repo = _repoWith(_csWith('https://stale-listing.test'));

    // The plugin has since rewritten its own mainUrl at runtime — the live
    // lookup must win over the value captured when the source was listed.
    expect(
      await repo.cfSolveTargetFor(sourceId),
      'https://live-domain.test',
    );
  });

  test(
    'falls back to the cached listing value when the live lookup returns '
    'nothing',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'liveMainUrl') return null; // not loaded natively
        return null;
      });
      final repo = _repoWith(_csWith('https://stale-listing.test'));

      expect(
        await repo.cfSolveTargetFor(sourceId),
        'https://stale-listing.test',
      );
    },
  );

  test('resolves to null when no url can be determined at all — the action '
      'must stay hidden', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'liveMainUrl') return null;
      return null;
    });
    final repo = _repoWith(_csWith('')); // plugin declares no url at all

    expect(await repo.cfSolveTargetFor(sourceId), isNull);
  });
}
