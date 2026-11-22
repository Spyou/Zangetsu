import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mangayomi/mangayomi_manager.dart';
import 'package:watch_app/core/mangayomi/mangayomi_provider.dart';
import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

class _FakeManager extends MangayomiManager {
  _FakeManager(this.worker)
    : super(MangayomiExtensionService(Directory.systemTemp));

  final _FakeWorker worker;

  @override
  Future<T> run<T>(
    String sourceId,
    Future<T> Function(MangayomiRuntimeWorker worker) operation,
  ) => operation(worker);
}

class _FakeWorker extends MangayomiRuntimeWorker {
  _FakeWorker() : super(MSource(), '', MangayomiCodeLanguage.javascript);

  @override
  Future<List<MPage>> getPageList(String url) async => [
    MPage(
      'https://img.example/page-1.jpg',
      headers: {
        'Referer': 'extension',
        'user-agent': 'Extension UA',
        'cookie': 'session=source',
      },
    ),
    MPage('https://img.example/page-2.jpg', headers: {'Referer': 'extension'}),
  ];

  @override
  Future<List<MVideo>> getVideoList(String url) async => [
    MVideo(
      'https://video.example/stream.m3u8',
      '1080p',
      'https://video.example',
      headers: {'user-agent': 'Extension UA'},
    ),
    MVideo(
      'https://video.example/stream-alt.m3u8',
      '720p',
      'https://video.example',
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('AniAura/mihon');

  final source = MangayomiSource(
    repository: Uri.parse('https://repo.example/index.json'),
    key: 'mg:repo:1:1:1',
    id: 1,
    name: 'Protected source',
    baseUrl: Uri.parse('https://source.example'),
    codeUrl: Uri.parse('https://repo.example/source.js'),
    version: '1',
    contentType: MangayomiContentType.manga,
    codeLanguage: MangayomiCodeLanguage.javascript,
    language: 'en',
    hasCloudflare: true,
  );

  test('recognizes the challenge error returned by the isolated bridge', () {
    expect(
      mangayomiCloudflareChallengeUrl(
        StateError(
          'Bad state: Cloudflare challenge at https://source.example/chapter',
        ),
      ),
      'https://source.example/chapter',
    );
    expect(
      mangayomiCloudflareChallengeUrl(StateError('source failed')),
      isNull,
    );
  });

  test(
    'adds saved headers to video and each page without duplicate host lookups',
    () async {
      var cookieLookups = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'imageCookie');
            cookieLookups++;
            return {'Cookie': 'cf_clearance=ok', 'User-Agent': 'WebView UA'};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final provider = MangayomiProvider(
        manager: _FakeManager(_FakeWorker()),
        installed: InstalledMangayomiSource(source, File('unused.js')),
      );

      final videos = await provider.getVideoSources('/episode');
      final pages = await provider.getPages('/chapter');

      expect(cookieLookups, 2); // one video host and one page host
      for (final video in videos) {
        expect(video.headers, containsPair('Cookie', 'cf_clearance=ok'));
      }
      expect(videos.first.headers, containsPair('user-agent', 'Extension UA'));
      expect(videos.last.headers, containsPair('User-Agent', 'WebView UA'));
      for (final page in pages) {
        expect(page.headers?['Cookie'], contains('cf_clearance=ok'));
      }
      expect(pages.first.headers?['Cookie'], contains('session=source'));
      expect(pages.first.headers, containsPair('user-agent', 'Extension UA'));
      expect(pages.first.headers, containsPair('Referer', 'extension'));
      expect(pages.last.headers, containsPair('User-Agent', 'WebView UA'));
    },
  );

  test('does not replace extension headers before clearance exists', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {'User-Agent': 'WebView UA'},
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final provider = MangayomiProvider(
      manager: _FakeManager(_FakeWorker()),
      installed: InstalledMangayomiSource(source, File('unused.js')),
    );

    final videos = await provider.getVideoSources('/episode');
    final pages = await provider.getPages('/chapter');
    expect(videos.first.headers, containsPair('user-agent', 'Extension UA'));
    expect(videos.last.headers, isNull);
    expect(pages.first.headers, containsPair('cookie', 'session=source'));
    expect(pages.last.headers, containsPair('Referer', 'extension'));
    expect(pages.last.headers, isNot(contains('User-Agent')));
  });

  test('missing native channel leaves headers untouched', () async {
    // A missing channel handler must degrade to plain extension headers.
    final provider = MangayomiProvider(
      manager: _FakeManager(_FakeWorker()),
      installed: InstalledMangayomiSource(source, File('unused.js')),
    );

    final videos = await provider.getVideoSources('/episode');
    final pages = await provider.getPages('/chapter');
    expect(videos.first.headers, containsPair('user-agent', 'Extension UA'));
    expect(videos.first.headers, isNot(contains('Cookie')));
    expect(pages.first.headers, containsPair('cookie', 'session=source'));
    expect(pages.last.headers, containsPair('Referer', 'extension'));
  });
}
