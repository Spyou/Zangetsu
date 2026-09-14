import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mihon/mihon_extension_service.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';

/// The native ecosystems (CloudStream, Aniyomi, Mihon) all solve Cloudflare
/// through [MihonExtensionService.solveCloudflare]. It used to leave the
/// `CfSolveNeeded` latch set, so the resolver and matcher went on skipping a
/// source the user had just solved — for the rest of the app's life, since the
/// latch is in-memory and nothing else clears it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zangetsu/mihon');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => CfSolveNeeded.clear('animepahe.pw'));
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    CfSolveNeeded.clear('animepahe.pw');
  });

  test('a completed solve lifts the latch for that host', () async {
    CfSolveNeeded.needsSolve(
      'animepahe.pw',
      'https://animepahe.pw/api?m=search&q=x',
      sourceId: 'cs:AnimePahe',
    );
    expect(CfSolveNeeded.sourceFlagged('cs:AnimePahe'), isTrue);

    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'solveCloudflare');
      return null; // native resolves when the solve screen closes
    });

    await MihonExtensionService.solveCloudflare(
      'https://animepahe.pw/api?m=search&q=x',
    );

    expect(CfSolveNeeded.hostFlagged('animepahe.pw'), isFalse);
    // The real point: the resolver stops skipping the source.
    expect(CfSolveNeeded.sourceFlagged('cs:AnimePahe'), isFalse);
  });

  test('no native solver (non-Android) leaves the latch alone', () async {
    CfSolveNeeded.needsSolve(
      'animepahe.pw',
      'https://animepahe.pw/',
      sourceId: 'cs:AnimePahe',
    );

    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no native solver');
    });

    await MihonExtensionService.solveCloudflare('https://animepahe.pw/');

    // Nothing solved anything, so the flag has to stand.
    expect(CfSolveNeeded.hostFlagged('animepahe.pw'), isTrue);
  });

  test('a malformed url cannot throw out of the solve', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    await expectLater(
      MihonExtensionService.solveCloudflare('::::not a url::::'),
      completes,
    );
  });
}
