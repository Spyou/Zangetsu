import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:watch_app/features/detail/stremio_episode_links_sheet.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _manifest = {
  'id': 'org.test.addon',
  'version': '1.0.0',
  'name': 'Test Addon',
  'resources': ['stream', 'subtitles'],
  'types': ['movie', 'series'],
  'idPrefixes': ['tt'],
};

class _FakeSecrets implements StremioSecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _Server {
  int streamCalls = 0;
  bool failFirst = false;
  int extraLinks = 0;
  int? videoSize;
  String description = 'WEB-DL';
  Completer<void>? subtitleGate;

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/manifest.json')) {
      return _json(_manifest);
    }
    if (request.url.path.contains('/subtitles/')) {
      await subtitleGate?.future;
      return _json({
        'subtitles': [
          {'url': 'https://subs.example/en.srt', 'lang': 'English'},
        ],
      });
    }
    streamCalls++;
    if (failFirst && streamCalls == 1) {
      return http.Response('', 500);
    }
    return _json({
      'streams': [
        for (var i = 0; i < extraLinks; i++)
          {'name': 'Link $i', 'url': 'https://cdn.example/$i.m3u8'},
        {
          'name': '4K',
          'description': description,
          'title': 'Legacy fallback',
          'url': 'https://cdn.example/video.m3u8',
          'behaviorHints': {
            if (videoSize != null) 'videoSize': videoSize,
            'proxyHeaders': {
              'request': {'Referer': 'https://ref/'},
            },
          },
          'subtitles': [
            {'url': 'https://subs.example/inline.srt', 'lang': 'Inline'},
          ],
        },
      ],
    });
  }

  http.Response _json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
}

void main() {
  late Directory tempDir;
  late _Server server;
  late StremioManager manager;
  late StremioRef ref;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stremio_sheet_test');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    if (Hive.isBoxOpen(StremioManager.boxName)) {
      await Hive.box<Map>(StremioManager.boxName).close();
    }
    await Hive.deleteBoxFromDisk(StremioManager.boxName);
    await sl.reset();
    server = _Server();
    manager = StremioManager(
      client: StremioClient(httpClient: MockClient(server.handle)),
      secrets: _FakeSecrets(),
      clock: () => DateTime(2026, 1, 1),
    );
    final installation = await manager.install('https://addon.example/addon');
    ref = StremioRef(
      installationId: installation.id,
      type: 'series',
      itemId: 'tt1',
      videoId: 'tt1:1:1',
    );
    sl.registerSingleton<StremioManager>(manager);
  });

  tearDown(() async {
    await sl.reset();
  });

  Future<void> openSheet(
    WidgetTester tester,
    ValueGetter<VideoSource?> read,
    void Function(VideoSource?) write,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                write(
                  await showStremioEpisodeLinksSheet(
                    context,
                    manager: manager,
                    ref: ref,
                    title: 'Game of Thrones · Winter Is Coming',
                  ),
                );
              },
              child: const Text('Open links'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open links'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('long press copies a stream without selecting or closing it', (
    tester,
  ) async {
    String? copied;
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
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);
    await tester.tap(find.byKey(const ValueKey('filter-chip:Test Addon')));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('WEB-DL'));
    await tester.pumpAndSettle();
    expect(copied, 'https://cdn.example/video.m3u8');
    expect(picked, isNull);
    expect(find.text('WEB-DL'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('best match long press copies the link without playing', (
    tester,
  ) async {
    String? copied;
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
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);
    await tester.longPress(find.text('BEST MATCH'));
    await tester.pumpAndSettle();
    expect(copied, 'https://cdn.example/video.m3u8');
    expect(picked, isNull);
    expect(find.text('BEST MATCH'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('groups links by addon and returns the exact source', (
    tester,
  ) async {
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);

    expect(find.text('Test Addon'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('filter-chip:Test Addon')));
    await tester.pumpAndSettle();
    expect(find.text('WEB-DL'), findsOne);

    await tester.tap(find.text('WEB-DL'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(picked, isNotNull);
    expect(picked!.url, 'https://cdn.example/video.m3u8');
    expect(picked!.headers, {'Referer': 'https://ref/'});
    expect(
      picked!.subtitles.every((sub) => sub.providerName == 'Test Addon'),
      isTrue,
    );
    expect(
      picked!.subtitles.map((s) => s.url),
      equals(['https://subs.example/inline.srt']),
    );
  });

  testWidgets('shows the full addon-formatted stream description', (
    tester,
  ) async {
    server.description = 'Custom release\n1080p HDR\nEnglish audio\n2.5 GB';
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);

    final description = find.text(server.description);
    expect(description, findsOneWidget);
    expect(tester.widget<Text>(description).maxLines, isNull);
  });

  testWidgets('shows a size badge only when the addon supplies a size', (
    tester,
  ) async {
    server.videoSize = 1073741824;
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);
    expect(find.text('SIZE 1.0 GB'), findsOneWidget);
    expect(find.text(server.description), findsOneWidget);
  });

  testWidgets('choosing a link never waits for subtitle addons', (
    tester,
  ) async {
    server.subtitleGate = Completer<void>();
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);
    await tester.tap(find.text('WEB-DL').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Checking subtitles…'), findsNothing);
    expect(picked, isNotNull);
    expect(picked!.subtitles.map((s) => s.url), [
      'https://subs.example/inline.srt',
    ]);
    server.subtitleGate!.complete();
  });

  testWidgets('large addon responses build only visible links', (tester) async {
    server.extraLinks = 300;
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);
    expect(find.text('Link 0'), findsWidgets);
    expect(find.text('Link 299'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('filter-chip:Test Addon')));
    await tester.pumpAndSettle();
    expect(find.text('Link 0'), findsWidgets);
    expect(find.text('Link 299'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing returns nothing', (tester) async {
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(picked, isNull);
  });

  testWidgets('a failed addon can be retried', (tester) async {
    server.failFirst = true;
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);

    expect(find.text('HTTP 500'), findsOne);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('WEB-DL'), findsOne);
    await tester.tap(find.text('WEB-DL'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(picked!.url, 'https://cdn.example/video.m3u8');
  });

  testWidgets('double tap picks once and does not throw', (tester) async {
    VideoSource? picked;
    await openSheet(tester, () => picked, (value) => picked = value);

    final link = find.text('WEB-DL');
    await tester.tap(link);
    await tester.tap(link, warnIfMissed: false);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(picked!.url, 'https://cdn.example/video.m3u8');
    expect(find.text('WEB-DL'), findsNothing);
  });

  test('Stremio titles use the sheet for Play and Resume only', () {
    expect(usesStremioLinks('stremio'), isTrue);
    expect(usesStremioLinks('stremio', initialSource: null), isTrue);
    expect(
      usesStremioLinks(
        'stremio',
        initialSource: const VideoSource(url: 'https://x'),
      ),
      isFalse,
    );
    expect(usesStremioLinks('source-a'), isFalse);
  });
}
