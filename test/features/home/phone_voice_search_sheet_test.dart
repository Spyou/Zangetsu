import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:watch_app/features/home/phone_voice_search_sheet.dart';

void main() {
  const voice = MethodChannel('zangetsu/phone_voice_search');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  late PermissionStatus permission;
  late Completer<String?> result;
  late List<MethodCall> calls;
  String? returned;

  Future<void> emit(WidgetTester tester, String state, {String? text}) async {
    final id =
        (calls.lastWhere((c) => c.method == 'listen').arguments
            as Map)['sessionId'];
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          voice.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('state', {
              'sessionId': id,
              'state': state,
              'text': text,
            }),
          ),
          (_) {},
        );
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    result = Completer<String?>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                returned = await showPhoneVoiceSearchSheet(context);
              },
              child: const Text('Open voice'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open voice'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  setUp(() {
    permission = PermissionStatus.granted;
    result = Completer<String?>();
    calls = [];
    returned = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, (call) async {
          if (call.method == 'requestPermissions') {
            return {Permission.microphone.value: permission.index};
          }
          return permission.index;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(voice, (call) async {
          calls.add(call);
          if (call.method == 'listen') return result.future;
          return true;
        });
  });

  tearDown(() {
    for (final channel in [voice, permissions]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('denied permission never starts recognition', (tester) async {
    permission = PermissionStatus.denied;
    await open(tester);
    expect(
      find.text('Allow microphone access to use voice search.'),
      findsOneWidget,
    );
    expect(calls.where((c) => c.method == 'listen'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('cancel releases the recognizer and ignores its late result', (
    tester,
  ) async {
    await open(tester);
    expect(calls.where((c) => c.method == 'listen'), hasLength(1));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'cancel'), isNotEmpty);
    result.complete('Late title');
    await tester.pumpAndSettle();
    expect(returned, isNull);
  });

  testWidgets('a final title closes the sheet once', (tester) async {
    await open(tester);
    result.complete('  Bleach  ');
    await tester.pumpAndSettle();
    expect(returned, 'Bleach');
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('failure offers retry without submitting text', (tester) async {
    await open(tester);
    result.completeError(PlatformException(code: 'voice_no_match'));
    await tester.pumpAndSettle();
    expect(
      find.text('Couldn’t hear a title. Please try speaking again.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(returned, isNull);
    result = Completer<String?>();
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(calls.where((c) => c.method == 'listen'), hasLength(2));
    result.complete('Naruto');
    await tester.pumpAndSettle();
    expect(returned, 'Naruto');
  });

  testWidgets('backgrounding closes the sheet and cancels recording', (
    tester,
  ) async {
    await open(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'cancel'), isNotEmpty);
    expect(returned, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    result.complete('Ignored');
    await tester.pumpAndSettle();
  });

  testWidgets('back dismisses and releases recording immediately', (
    tester,
  ) async {
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(calls.where((c) => c.method == 'cancel'), isNotEmpty);
    result.complete('Ignored');
    await tester.pumpAndSettle();
    expect(returned, isNull);
  });

  testWidgets('missing native completion times out and can be dismissed', (
    tester,
  ) async {
    await open(tester);
    await tester.pump(const Duration(seconds: 36));
    await tester.pumpAndSettle();
    expect(find.text('Voice search failed. Please try again.'), findsOneWidget);
    expect(calls.where((c) => c.method == 'cancel'), isNotEmpty);
    result.complete('Late result');
    await tester.pumpAndSettle();
    expect(returned, isNull);
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('permanent permission denial offers settings without recording', (
    tester,
  ) async {
    permission = PermissionStatus.permanentlyDenied;
    await open(tester);
    expect(find.text('Settings'), findsOneWidget);
    expect(calls.where((c) => c.method == 'listen'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('only matching session events change listening state', (
    tester,
  ) async {
    await open(tester);
    final id =
        (calls.firstWhere((c) => c.method == 'listen').arguments
            as Map)['sessionId'];
    Future<void> emit(int sessionId, String state) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            voice.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('state', {
                'sessionId': sessionId,
                'state': state,
                'level': .6,
              }),
            ),
            (_) {},
          );
      await tester.pump();
    }

    await emit((id as int) + 1, 'processing');
    expect(find.text('Getting ready…'), findsOneWidget);
    await emit(id, 'listening');
    expect(find.text('Listening…'), findsOneWidget);
    await emit(id, 'processing');
    expect(find.text('Finding the words…'), findsOneWidget);
    result.complete(null);
    await tester.pumpAndSettle();
  });

  testWidgets('spoken words appear live but only the final result submits', (
    tester,
  ) async {
    await open(tester);
    await emit(tester, 'listening');
    await emit(tester, 'partial', text: '  Naruto Shippuden  ');
    expect(find.text('Naruto Shippuden'), findsOneWidget);
    expect(returned, isNull);
    await emit(tester, 'processing');
    expect(find.text('Naruto Shippuden'), findsOneWidget);
    result.complete('Naruto Shippūden');
    await tester.pumpAndSettle();
    expect(returned, 'Naruto Shippūden');
  });

  testWidgets('retry clears old spoken text without searching it', (
    tester,
  ) async {
    await open(tester);
    await emit(tester, 'partial', text: 'Wrong title');
    expect(find.text('Wrong title'), findsOneWidget);
    result.completeError(PlatformException(code: 'voice_no_match'));
    await tester.pumpAndSettle();
    expect(returned, isNull);
    result = Completer<String?>();
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.text('Wrong title'), findsNothing);
    result.complete(null);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'character stays visible and pauses instead of becoming a mic icon',
    (tester) async {
      await open(tester);
      expect(find.byIcon(Icons.mic_rounded), findsNothing);
      await emit(tester, 'listening');
      expect(
        tester
            .widget<TickerMode>(find.byKey(const ValueKey('voice-search-art')))
            .enabled,
        isTrue,
      );
      await emit(tester, 'processing');
      expect(
        tester
            .widget<TickerMode>(find.byKey(const ValueKey('voice-search-art')))
            .enabled,
        isFalse,
      );
      result.completeError(PlatformException(code: 'voice_no_match'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.mic_off_rounded), findsNothing);
      expect(
        tester
            .widget<TickerMode>(find.byKey(const ValueKey('voice-search-art')))
            .enabled,
        isFalse,
      );
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'iPhone speech denial offers settings rather than repeated permission prompts',
    (tester) async {
      await open(tester);
      result.completeError(PlatformException(code: 'voice_speech_permission'));
      await tester.pumpAndSettle();
      expect(
        find.text('Allow speech recognition in Settings to use voice search.'),
        findsOneWidget,
      );
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
}
