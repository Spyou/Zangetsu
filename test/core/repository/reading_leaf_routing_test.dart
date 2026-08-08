import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/page_content.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/reading_provider.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';

/// A fake reading-capable source — mirrors a real JsProvider, which is both a
/// [BaseProvider] and a [ReadingProvider] — so pages()/chapterText() routing
/// can be tested without the QuickJS runtime.
class _FakeReadingProvider implements BaseProvider, ReadingProvider {
  _FakeReadingProvider(this.sourceId);

  @override
  final String sourceId;

  @override
  String get displayName => sourceId;

  @override
  Future<ProviderInfo> getInfo() => throw UnimplementedError();

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) => throw UnimplementedError();

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) => throw UnimplementedError();

  @override
  Future<List<PageImage>> getPages(String chapterUrl) async =>
      [const PageImage(url: 'https://img/1.jpg')];

  @override
  Future<ChapterText> getText(String chapterUrl) async =>
      const ChapterText(html: '<p>hello</p>');
}

/// A fake video-only source — like a real CloudStream/Aniyomi provider, it
/// does NOT implement [ReadingProvider] — proving pages()/chapterText()
/// refuse to serve a source that can't read chapters.
class _FakeVideoOnlyProvider implements BaseProvider {
  _FakeVideoOnlyProvider(this.sourceId);

  @override
  final String sourceId;

  @override
  String get displayName => sourceId;

  @override
  Future<ProviderInfo> getInfo() => throw UnimplementedError();

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) => throw UnimplementedError();

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) => throw UnimplementedError();
}

SourceRepository _repoWith(AniyomiManager aniManager) => SourceRepository(
  manager: ProviderManager(dio: Dio()),
  csManager: CloudStreamManager(),
  aniManager: aniManager,
  activeSource: ActiveSourceCubit(),
  prefs: PlaybackPrefs(),
);

void main() {
  // ProviderManager eagerly spins up the QuickJS runtime in its constructor;
  // that needs the Flutter test binding to be initialised first.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SourceRepository reading-leaf routing', () {
    test('pages() routes to the provider for the given sourceId', () async {
      final ani = AniyomiManager();
      final fake = _FakeReadingProvider('ani:fake-manga');
      ani.register(fake);
      final repo = _repoWith(ani);

      final pages = await repo.pages('https://x/ch1', sourceId: fake.sourceId);
      expect(pages.single.url, 'https://img/1.jpg');
    });

    test('chapterText() routes and returns text', () async {
      final ani = AniyomiManager();
      final fake = _FakeReadingProvider('ani:fake-novel');
      ani.register(fake);
      final repo = _repoWith(ani);

      final t = await repo.chapterText('https://x/ch1', sourceId: fake.sourceId);
      expect(t.html, contains('hello'));
    });

    test('pages() throws UnsupportedError for a non-reading source', () async {
      final ani = AniyomiManager();
      final fake = _FakeVideoOnlyProvider('ani:video-only');
      ani.register(fake);
      final repo = _repoWith(ani);

      expect(
        () => repo.pages('https://x/ch1', sourceId: fake.sourceId),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test(
      'chapterText() throws UnsupportedError for a non-reading source',
      () async {
        final ani = AniyomiManager();
        final fake = _FakeVideoOnlyProvider('ani:video-only-2');
        ani.register(fake);
        final repo = _repoWith(ani);

        expect(
          () => repo.chapterText('https://x/ch1', sourceId: fake.sourceId),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );
  });
}
