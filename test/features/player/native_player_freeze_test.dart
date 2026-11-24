import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/native_player_freeze.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';

void main() {
  testWidgets('freezes only while the player is in front and the app is idle', (
    tester,
  ) async {
    bool? animating;
    await tester.pumpWidget(
      MaterialApp(
        home: NativePlayerFreeze(
          child: Builder(
            builder: (context) {
              animating = TickerMode.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    addTearDown(() => phoneNativeInFront.value = false);
    expect(animating, isTrue); // nothing in front

    phoneNativeInFront.value = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(animating, isFalse); // player in front, app paused behind it

    // Picture-in-Picture: the app is visible and resumed again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(animating, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(animating, isFalse);
    phoneNativeInFront.value = false; // docked or closed
    await tester.pump();
    expect(animating, isTrue);
  });
}
