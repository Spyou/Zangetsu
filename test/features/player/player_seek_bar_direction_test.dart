import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media;
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/features/player/player_controller.dart';
import 'package:watch_app/features/player/player_screen.dart';

class _Prefs extends PlaybackPrefs {
  @override
  bool get skipIntro => false;
}

class _Streams implements media.PlayerStream {
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<Duration> get buffer => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements media.Player {
  @override
  final stream = _Streams();
  @override
  final state = const media.PlayerState(position: Duration(seconds: 20));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller implements PlayerCubit {
  @override
  final player = _Player();
  @override
  String? get previewUri => null;
  Duration? sought;
  @override
  void seekTo(Duration value) => sought = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => sl.registerSingleton<PlaybackPrefs>(_Prefs()));
  tearDown(() => sl.reset());

  for (final direction in TextDirection.values) {
    testWidgets('timeline stays left to right in $direction', (tester) async {
      final controller = _Controller();
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: Column(
                children: [
                  const Text('العربية', key: ValueKey('arabic')),
                  PlayerSeekBar(
                    controller: controller,
                    duration: const Duration(seconds: 100),
                    onInteract: () {},
                    trailing: const Text('+85s'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final slider = find.byType(Slider);
      expect(Directionality.of(tester.element(slider)), TextDirection.ltr);
      expect(
        Directionality.of(tester.element(find.byKey(const ValueKey('arabic')))),
        direction,
      );
      expect(
        tester.getCenter(find.text('00:20 / 01:40')).dx,
        lessThan(tester.getCenter(find.text('+85s')).dx),
      );
      final rect = tester.getRect(slider);
      await tester.tapAt(Offset(rect.left + rect.width * .75, rect.center.dy));
      await tester.pump();
      expect(controller.sought!.inSeconds, greaterThan(60));
      await tester.tap(find.text('00:20 / 01:40'));
      await tester.pump();
      expect(find.text('00:20 / -01:20'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
