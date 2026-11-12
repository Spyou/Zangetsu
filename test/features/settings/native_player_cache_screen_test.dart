import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/ui/settings_widgets.dart';
import 'package:watch_app/features/settings/native_player_cache_screen.dart';

class _Prefs extends PlaybackPrefs {
  bool nativeEnabled = false;
  bool diskEnabled = false;
  int nativeMb = 128;
  @override
  bool get phoneNativeCacheEnabled => nativeEnabled;
  @override
  bool get phoneDiskCacheEnabled => diskEnabled;
  @override
  int get phoneNativeCacheMb => nativeMb;
  @override
  int get phoneDiskCacheGb => 2;
  @override
  String get videoBufferSize => 'default';
  @override
  String get videoBufferLength => 'default';
  @override
  Future<void> setPhoneNativeCacheEnabled(bool value) async {
    nativeEnabled = value;
  }

  @override
  Future<void> setPhoneDiskCacheEnabled(bool value) async {
    diskEnabled = value;
  }

  @override
  Future<void> setPhoneNativeCacheMb(int value) async {
    nativeMb = value;
  }
}

void main() {
  const channel = MethodChannel('zangetsu/phone_player');
  late _Prefs prefs;
  final calls = <String>[];
  setUp(() async {
    prefs = _Prefs();
    sl.registerSingleton<PlaybackPrefs>(prefs);
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == 'cacheInfo'
              ? {'nativeLimitMb': 256, 'javaLimitMb': 64, 'diskBytes': 1048576}
              : false;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await sl.reset();
  });

  testWidgets('cache sliders are opt-in, limited and saved separately', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NativePlayerCacheScreen()));
    await tester.pumpAndSettle();
    final sliders = find.byType(Slider);
    expect(sliders, findsNWidgets(2));
    expect(tester.widget<Slider>(sliders.first).max, 256);
    expect(tester.widget<Slider>(sliders.last).max, 20);
    expect(tester.widget<Slider>(sliders.first).onChanged, isNull);
    expect(tester.widget<Slider>(sliders.last).onChanged, isNull);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(prefs.phoneNativeCacheEnabled, isTrue);
    final slider = tester.widget<Slider>(sliders.first);
    slider.onChanged!(256);
    slider.onChangeEnd!(256);
    await tester.pumpAndSettle();
    expect(prefs.phoneNativeCacheMb, 256);
    expect(find.text('64 MB'), findsNothing);
    expect(find.text('Player buffer'), findsNothing);
    expect(prefs.videoBufferSize, 'default');
    expect(prefs.videoBufferLength, 'default');
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy cache clear is explained and does not report success', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NativePlayerCacheScreen()));
    await tester.pumpAndSettle();
    final clear = find.text('Clear playback cache');
    await tester.ensureVisible(clear);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(calls, contains('clearPlaybackCache'));
    expect(
      find.text('Close the Android player before clearing its playback cache.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'unavailable memory cache can still be turned off after restore',
    (tester) async {
      prefs.nativeEnabled = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {
              'nativeLimitMb': 0,
              'javaLimitMb': 64,
              'diskBytes': 0,
              'cacheError': true,
            },
          );
      await tester.pumpWidget(
        const MaterialApp(home: NativePlayerCacheScreen()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsNWidgets(2));
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(prefs.phoneNativeCacheEnabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  for (final direction in TextDirection.values) {
    testWidgets(
      'cache cards fit a narrow $direction screen with readable descriptions',
      (tester) async {
        tester.view.physicalSize = const Size(360, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Directionality(
              textDirection: direction,
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
                child: const NativePlayerCacheScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final memoryCard = find
            .ancestor(
              of: find.byType(Slider).first,
              matching: find.byType(SettingsCard),
            )
            .first;
        final surface = find
            .descendant(of: memoryCard, matching: find.byType(DecoratedBox))
            .first;
        expect(tester.getRect(surface).left, 16);
        expect(tester.getRect(surface).right, 344);
        final description = find.text(
          'Extra read-ahead memory outside the Java heap. Limited by available device memory.',
        );
        expect(tester.widget<Text>(description).maxLines, isNull);
        final diskCard = find
            .ancestor(
              of: find.byType(Slider).last,
              matching: find.byType(SettingsCard),
            )
            .first;
        final clearCard = find
            .ancestor(
              of: find.text('Clear playback cache'),
              matching: find.byType(SettingsCard),
            )
            .first;
        expect(
          Directionality.of(tester.element(find.byType(Slider).first)),
          TextDirection.ltr,
        );
        await tester.scrollUntilVisible(
          find.text('Clear playback cache'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          tester.getRect(clearCard).top - tester.getRect(diskCard).bottom,
          greaterThanOrEqualTo(12),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
