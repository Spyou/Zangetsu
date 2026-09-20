import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/metadata/streaming_providers.dart';
import 'package:watch_app/core/ui/streaming_prefs.dart';
import 'package:watch_app/features/settings/streaming_services_screen_tv.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// A 1x1 transparent GIF. `Image.network` in a widget test otherwise hits the
/// real HttpClient, which never completes under the test binding and hangs
/// `pumpAndSettle` for the whole file.
final _pixel = Uint8List.fromList([
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00,
  0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
  0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
]);

class _StubImageHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? _) => _StubClient();
}

class _StubClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _StubRequest(url);

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubRequest implements HttpClientRequest {
  _StubRequest(this.uri);
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _StubHeaders();

  @override
  Future<HttpClientResponse> close() async => _StubResponse();

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubHeaders implements HttpHeaders {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubResponse implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => _pixel.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_pixel).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Map<String, dynamic> _providers() => {
  'results': [
    {
      'provider_id': 8,
      'provider_name': 'Netflix',
      'logo_path': '/n.png',
      'display_priority': 0,
    },
    {
      'provider_id': 283,
      'provider_name': 'Crunchyroll',
      'logo_path': '/c.png',
      'display_priority': 5,
    },
  ],
};

Widget harness() => const MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: StreamingServicesScreenTv(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    HttpOverrides.global = _StubImageHttpOverrides();
    final v = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(1920, 1080);
    v.devicePixelRatio = 1;
    dir = await Directory.systemTemp.createTemp('streaming_tv');
    Hive.init(dir.path);
    await StreamingPrefs.init();
    StreamingPrefs.deviceRegion = () => 'IN';
    sl.registerSingleton<StreamingProvidersService>(
      StreamingProvidersService((path, params) async => _providers()),
    );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
        .resetPhysicalSize();
    HttpOverrides.global = null;
    StreamingPrefs.resetDeviceRegionForTest();
    await sl.reset();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('lists the services', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('Crunchyroll'), findsOneWidget);
  });

  testWidgets('every tile is D-pad focusable', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-service-8')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-service-283')), findsOneWidget);
  });

  testWidgets('says plainly that this is browsing, not streaming', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(
      find.textContaining('play through your own sources'),
      findsOneWidget,
    );
  });

  testWidgets('an empty list shows the empty state', (t) async {
    await sl.reset();
    sl.registerSingleton<StreamingProvidersService>(
      StreamingProvidersService(
        (path, params) async => {'results': <dynamic>[]},
      ),
    );
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(find.textContaining('No services listed'), findsOneWidget);
  });
}
