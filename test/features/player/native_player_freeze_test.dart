import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/in_app_mini_player.dart';
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

  testWidgets('a touch on the app wakes it even without a signal', (
    tester,
  ) async {
    bool? animating;
    await tester.pumpWidget(
      MaterialApp(
        home: NativePlayerFreeze(
          child: Builder(
            builder: (context) {
              animating = TickerMode.of(context);
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    addTearDown(() => phoneNativeInFront.value = false);
    phoneNativeInFront.value = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(animating, isFalse);

    // Picture-in-Picture: the app is on screen and gets touched.
    await tester.tap(find.byType(SizedBox));
    await tester.pump();
    expect(animating, isTrue);

    // The next time the player comes to the front it freezes again.
    phoneNativeInFront.value = false;
    await tester.pump();
    phoneNativeInFront.value = true;
    await tester.pump();
    expect(animating, isFalse);
  });

  testWidgets('a docked mini player never leaves the app frozen', (
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
    addTearDown(() {
      phoneNativeInFront.value = false;
      dockedPlayer.value = null;
    });
    // The player says it is in front (even late, after it docked)...
    phoneNativeInFront.value = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(animating, isFalse);

    // ...but once a mini player is docked the app is what is on screen.
    dockedPlayer.value = InAppMiniPlayer(
      video: const SizedBox(),
      playing: true,
      playPauseLabel: 'Pause',
      closeLabel: 'Close',
      restoreLabel: 'Restore',
      onTogglePlayback: () {},
      onClose: () {},
      onRestore: () {},
    );
    await tester.pump();
    expect(animating, isTrue);
  });
}
