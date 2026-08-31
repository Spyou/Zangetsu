// Task 21: CloudStream sources go through native OkHttp (PluginHost.kt),
// invisible to the JS-provider `_looksLikeCfChallenge` check — a CF-gated CS
// source used to just vanish from matching with no icon and no way to solve.
// PluginHost's shared-client interceptor now pushes a challenge hit to Dart
// over the existing `zangetsu/cloudstream` channel as `onCfChallenge`;
// [CloudStreamManager.handleCfChallenge] is the Dart-side handler for that
// push, pulled out so a test can call it directly instead of simulating a
// full platform-channel round trip (native isn't reachable from here at all).
//
// It feeds the SAME `CfSolveNeeded` latch the JS path uses (cf_solve_needed_
// test.dart), so solving is exercised the same way that suite does: via
// ProviderManager.solveCloudflareForHost, which is channel-agnostic — it
// only cares that the host is flagged, not which path flagged it.

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    CfSolveNeeded.clear('cf-cs.test');
  });

  test('the native onCfChallenge push flags the host', () {
    final manager = CloudStreamManager();
    manager.handleCfChallenge({
      'host': 'cf-cs.test',
      'url': 'https://cf-cs.test/search?q=foo',
      // No source with this native resolution key is installed here, so the
      // sourceId resolution (CloudStreamManager._sourceIdForHostKey) misses
      // and the flag lands host-only — exactly what a plain (non-Z-Mode)
      // detail block screen reads via CfSolveNeeded.hostFlagged.
      'sourceId': 'SomeSource',
    });

    expect(CfSolveNeeded.hostFlagged('cf-cs.test'), isTrue);
    expect(CfSolveNeeded.sourceFlagged('cs:SomeSource'), isFalse);
  });

  test('a malformed push (missing host/url) is ignored', () {
    final manager = CloudStreamManager();
    manager.handleCfChallenge({'sourceId': 'SomeSource'});
    manager.handleCfChallenge({'host': '', 'url': 'https://x.test/'});

    expect(CfSolveNeeded.hostFlagged('cf-cs.test'), isFalse);
  });

  test('a successful solve clears a CS-flagged host', () async {
    final manager = CloudStreamManager();
    manager.handleCfChallenge({
      'host': 'cf-cs.test',
      'url': 'https://cf-cs.test/search?q=foo',
    });
    expect(CfSolveNeeded.hostFlagged('cf-cs.test'), isTrue);

    const channel = MethodChannel('zangetsu/cloudstream');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'solveCloudflare') {
        return {'cookie': 'cf_clearance=abc123', 'userAgent': 'TestUA/1.0'};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    // Same solver the JS path uses (see cf_solve_needed_test.dart) — proves
    // the shared latch + solve plumbing clears a CS-originated flag too.
    final solved = await ProviderManager(
      dio: Dio(),
    ).solveCloudflareForHost('cf-cs.test', 'https://cf-cs.test/search?q=foo');

    expect(solved, isTrue);
    expect(CfSolveNeeded.hostFlagged('cf-cs.test'), isFalse);
  });
}
