import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/ui/episode_player_sheet.dart';

void main() {
  testWidgets('mirror long press copies the exact URL and tap still selects', (
    tester,
  ) async {
    const url = 'https://cdn.example/video.mp4?token=test';
    final source = VideoSource(url: url, label: 'Test server');
    String? copied;
    VideoSource? picked;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await showMirrorSheet(
                  context,
                  episodeLabel: 'Episode 1',
                  sources: [source],
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Test server'));
    await tester.pumpAndSettle();
    expect(copied, url);
    expect(picked, isNull);
    expect(find.text('Test server'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('Test server'));
    await tester.pumpAndSettle();
    expect(picked, same(source));
  });
}
