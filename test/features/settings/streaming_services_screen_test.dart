import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/metadata/streaming_providers.dart';
import 'package:watch_app/core/ui/streaming_prefs.dart';
import 'package:watch_app/features/settings/streaming_services_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// A 1x1 transparent GIF. `Image.network` in a widget test otherwise hits the
/// real HttpClient, which never completes under the test binding and hangs
/// `pumpAndSettle` for the whole file.
final _pixel = Uint8List.fromList([
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
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
  home: StreamingServicesScreen(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    HttpOverrides.global = _StubImageHttpOverrides();
    dir = await Directory.systemTemp.createTemp('streaming_screen');
    Hive.init(dir.path);
    await StreamingPrefs.init();
    StreamingPrefs.deviceRegion = () => 'IN';
    sl.registerSingleton<StreamingProvidersService>(
      StreamingProvidersService((path, params) async => _providers()),
    );
  });

  tearDown(() async {
    HttpOverrides.global = null;
    StreamingPrefs.resetDeviceRegionForTest();
    await sl.reset();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('lists the services for the region', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('Crunchyroll'), findsOneWidget);
  });

  testWidgets('says plainly that this is browsing, not streaming', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(
      find.textContaining('play through your own sources'),
      findsOneWidget,
    );
  });

  testWidgets('an empty provider list shows the empty state, not a blank page',
      (t) async {
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

  // The provider list is cached per region. Changing the region without
  // clearing it would show the old country's services under the new name.
  test('clearCache drops the cached list so a new region refetches', () async {
    var hits = 0;
    final svc = StreamingProvidersService((path, params) async {
      hits++;
      return _providers();
    });
    await svc.list('IN');
    await svc.list('IN');
    expect(hits, 2);
    svc.clearCache();
    await svc.list('IN');
    expect(hits, 4);
  });

  testWidgets('the grid asks for the stored region, not the device one',
      (t) async {
    await t.runAsync(() => StreamingPrefs.setRegion('GB'));
    final asked = <String>[];
    await sl.reset();
    sl.registerSingleton<StreamingProvidersService>(
      StreamingProvidersService((path, params) async {
        asked.add('${params['watch_region']}');
        return _providers();
      }),
    );
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(asked, everyElement('GB'));
  });
}
