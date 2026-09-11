import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/features/reader/reader_comfort.dart';

/// Nothing but the mixin — both readers get fullscreen from here, so testing
/// the mixin tests both.
class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with ReaderComfortMixin<_Host> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late List<String> uiModes;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reader_fullscreen');
    Hive.init(dir.path);
    await ReaderPrefs.init();
    sl.registerSingleton<ReaderPrefs>(ReaderPrefs());

    // SystemChrome goes out over a platform channel, so a test can watch the
    // calls without a device.
    uiModes = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            uiModes.add(call.arguments as String);
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  // Neither comfort method touches `context` or `setState`, so the State on
  // its own is enough — no need to pump a widget tree.
  final state = _HostState();

  // Platform-channel messages are delivered on the next turn of the event
  // loop, so the mock handler hasn't run yet when the call returns.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('fullscreen is on out of the box', () {
    expect(sl<ReaderPrefs>().fullscreen, isTrue);
  });

  test('the toggle persists', () async {
    await sl<ReaderPrefs>().setFullscreen(false);
    expect(ReaderPrefs().fullscreen, isFalse);
    await sl<ReaderPrefs>().setFullscreen(true);
    expect(ReaderPrefs().fullscreen, isTrue);
  });

  test('entering the reader hides the bars', () async {
    await sl<ReaderPrefs>().setFullscreen(true);

    uiModes.clear();
    state.applyReaderComfort();
    await settle();
    expect(uiModes, ['SystemUiMode.immersiveSticky']);
  });

  test('with fullscreen off the bars stay put', () async {
    await sl<ReaderPrefs>().setFullscreen(false);

    uiModes.clear();
    state.applyReaderComfort();
    await settle();
    expect(uiModes, ['SystemUiMode.edgeToEdge']);
  });

  test('leaving the reader brings the bars back', () async {
    await sl<ReaderPrefs>().setFullscreen(true);
    state.applyReaderComfort();

    uiModes.clear();
    state.restoreReaderComfort();
    await settle();
    expect(uiModes, ['SystemUiMode.edgeToEdge']);
  });

  test('leaving restores even after the toggle was switched off', () async {
    // The toggle lives in the in-reader Comfort sheet, so it can flip while
    // the bars are already hidden. Restoring only when the *current* pref
    // says so would strand them hidden over the rest of the app.
    await sl<ReaderPrefs>().setFullscreen(true);
    state.applyReaderComfort();
    await sl<ReaderPrefs>().setFullscreen(false);

    uiModes.clear();
    state.restoreReaderComfort();
    await settle();
    expect(uiModes, ['SystemUiMode.edgeToEdge']);
  });
}
