import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/seek_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('nearby warmed thumbnails are displayed without another decode', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('zangetsu/keyframe_thumbs');
    final requests = <int>[];
    var releases = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'release') {
        releases++;
        return null;
      }
      final position = call.arguments['positionMs'] as int;
      requests.add(position);
      return Uint8List.fromList([position ~/ 1000]);
    });

    final preview = SeekPreview(uri: 'https://example.com/video', local: false);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    preview.warm(
      const Duration(seconds: 10),
      duration: const Duration(minutes: 1),
    );
    await tester.pumpAndSettle();
    expect(requests, contains(12000));
    expect(preview.frame.value, isNull);

    final count = requests.length;
    preview.request(const Duration(milliseconds: 12500));
    expect(preview.frame.value, orderedEquals([12]));
    expect(requests.length, count);

    preview.request(const Duration(seconds: 18));
    expect(preview.frame.value, orderedEquals([12]));
    await tester.pumpAndSettle();
    expect(preview.frame.value, orderedEquals([18]));

    preview.request(const Duration(seconds: 14));
    expect(preview.frame.value, orderedEquals([12]));
    await tester.pumpAndSettle();

    var buffering = true;
    preview.warm(
      const Duration(seconds: 10),
      duration: const Duration(minutes: 1),
      isBuffering: () => buffering,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(requests, isNot(contains(44000)));

    buffering = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(requests, contains(44000));
    preview.request(const Duration(seconds: 100));
    expect(preview.frame.value, orderedEquals([44]));
    await tester.pumpAndSettle();
    expect(preview.frame.value, orderedEquals([100]));
    await preview.dispose();
    expect(releases, 1);
  });
}
