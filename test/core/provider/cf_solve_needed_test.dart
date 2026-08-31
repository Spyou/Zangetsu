// Task 20: Z Mode matches a title to a source BY searching it, and
// `_suppressCfSolve` deliberately skips the Cloudflare solve during a
// `search` call (a passive multi-source sweep must never pop the blocking
// WebView). That made a CF-gated source silently drop out of matching —
// nothing recorded that it would have worked after a solve. These tests
// spin up a REAL QuickJS provider (the same ProviderManager/JsProvider path
// every installed source uses, per js_reading_provider_names_test.dart) with
// a fake Dio adapter standing in for the network, so they exercise the
// actual _JsHost fetch path, not a re-implementation of it.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

const String _cfBlockedJs = r'''
async function search(query, page, opts) {
  await fetch('https://cf-blocked.test/s?q=' + query);
  return [];
}
''';

const String _healthyJs = r'''
async function search(query, page, opts) {
  var res = await fetch('https://healthy.test/s?q=' + query);
  var data = JSON.parse(await res.text());
  return data.items || [];
}
''';

/// Fake Dio adapter, no real network: 'cf-blocked.test' always answers with
/// a Cloudflare interstitial (403 + the markers `_looksLikeCfChallenge`
/// checks for); everything else answers a normal 200.
class _FakeAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.host == 'cf-blocked.test') {
      return ResponseBody.fromString(
        '<html>Just a moment...</html>',
        403,
        headers: {
          'server': ['cloudflare'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'items': <dynamic>[]}),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderManager manager;

  setUp(() {
    manager = ProviderManager(dio: Dio()..httpClientAdapter = _FakeAdapter());
  });

  tearDown(() {
    CfSolveNeeded.clear('cf-blocked.test');
    CfSolveNeeded.clear('healthy.test');
  });

  test(
    'a search that hits a Cloudflare challenge while solving is suppressed '
    'records the host as needing a solve',
    () async {
      final provider = manager.load(sourceId: 'cf-src', jsSource: _cfBlockedJs);
      await provider.search('foo', 1);

      expect(CfSolveNeeded.hostFlagged('cf-blocked.test'), isTrue);
      expect(CfSolveNeeded.sourceFlagged('cf-src'), isTrue);
      expect(CfSolveNeeded.urlFor('cf-src'), 'https://cf-blocked.test/s?q=foo');
    },
  );

  test('a search that succeeds records nothing', () async {
    final provider = manager.load(sourceId: 'ok-src', jsSource: _healthyJs);
    final results = await provider.search('foo', 1);

    expect(results, isEmpty); // the fake's own answer, just proving it ran
    expect(CfSolveNeeded.hostFlagged('healthy.test'), isFalse);
    expect(CfSolveNeeded.sourceFlagged('ok-src'), isFalse);
  });

  test('a successful solve clears the flag', () async {
    final provider = manager.load(sourceId: 'cf-src', jsSource: _cfBlockedJs);
    await provider.search('foo', 1);
    expect(CfSolveNeeded.hostFlagged('cf-blocked.test'), isTrue);

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

    final solved = await manager.solveCloudflareForHost(
      'cf-blocked.test',
      'https://cf-blocked.test/s?q=foo',
    );

    expect(solved, isTrue);
    expect(CfSolveNeeded.hostFlagged('cf-blocked.test'), isFalse);
  });
}
