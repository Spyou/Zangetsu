import 'dart:async';

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

/// Counts what it was actually asked for, so a test can tell a cache hit from
/// a second request.
class _CountingProvider implements BaseProvider, ReadingProvider {
  _CountingProvider(this.sourceId, {this.empty = false});

  @override
  final String sourceId;

  /// Answers with an empty page list — the transient source hiccup the reader
  /// already retries for.
  final bool empty;

  final List<String> calls = [];

  @override
  String get displayName => sourceId;

  @override
  Future<List<PageImage>> getPages(String chapterUrl) async {
    calls.add(chapterUrl);
    if (empty) return const [];
    return [PageImage(url: 'https://img/$chapterUrl/1.jpg')];
  }

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
  Future<ChapterText> getText(String chapterUrl) => throw UnimplementedError();
}

SourceRepository _repoWith(AniyomiManager ani) => SourceRepository(
  manager: ProviderManager(dio: Dio()),
  csManager: CloudStreamManager(),
  aniManager: ani,
  activeSource: ActiveSourceCubit(),
  prefs: PlaybackPrefs(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A fresh repository per test — the cache is an instance field, so this is
  /// what keeps one test's fetch out of the next one's.
  (SourceRepository, _CountingProvider) harness({bool empty = false}) {
    final ani = AniyomiManager();
    final fake = _CountingProvider('ani:manga', empty: empty);
    ani.register(fake);
    return (_repoWith(ani), fake);
  }

  group('page-list cache', () {
    // The reported symptom: opening a chapter sat on a spinner for seconds,
    // and opening the SAME chapter again paid the identical wait, because
    // nothing remembered the answer.
    test('reopening a chapter does not re-request its pages', () async {
      final (repo, fake) = harness();

      final first = await repo.pages('c1', sourceId: 'ani:manga');
      final second = await repo.pages('c1', sourceId: 'ani:manga');

      expect(fake.calls, ['c1']); // asked once, not twice
      expect(second, first);
    });

    test('a different chapter is still fetched', () async {
      final (repo, fake) = harness();

      await repo.pages('c1', sourceId: 'ani:manga');
      await repo.pages('c2', sourceId: 'ani:manga');

      expect(fake.calls, ['c1', 'c2']);
    });

    // An empty answer is the transient failure `_fetchPages` retries for.
    // Caching it would make one bad response stick for ten minutes and turn a
    // self-healing hiccup into "this chapter is broken until you restart".
    test('an empty page list is never cached', () async {
      final (repo, fake) = harness(empty: true);

      await repo.pages('c1', sourceId: 'ani:manga');
      await repo.pages('c1', sourceId: 'ani:manga');

      expect(fake.calls, ['c1', 'c1']);
    });

    test('warmPages makes the next chapter free to open', () async {
      final (repo, fake) = harness();

      await repo.warmPages('c2', sourceId: 'ani:manga');
      expect(fake.calls, ['c2']);

      final pages = await repo.pages('c2', sourceId: 'ani:manga');
      expect(fake.calls, ['c2']); // still one — the reader opened from cache
      expect(pages, isNotEmpty);
    });

    // Measured on a real source: a page list took 8-14 SECONDS. Warming the
    // next chapter, then tapping through to it before the warm landed, fired
    // the SAME 8-second request twice — the result cache can't help, because
    // neither request has finished. The second caller must join the first.
    test(
      'two overlapping requests for one chapter make a single fetch',
      () async {
        final ani = AniyomiManager();
        final gate = Completer<List<PageImage>>();
        final fake = _GatedProvider('ani:manga', gate.future);
        ani.register(fake);
        final repo = _repoWith(ani);

        final a = repo.pages('c1', sourceId: 'ani:manga'); // the warm
        final b = repo.pages(
          'c1',
          sourceId: 'ani:manga',
        ); // the user tapping in

        gate.complete([const PageImage(url: 'https://img/1.jpg')]);
        expect(await a, await b);
        expect(fake.calls, ['c1']); // one request, both callers served
      },
    );

    test('warmPages swallows a source failure', () async {
      final ani = AniyomiManager();
      final repo = _repoWith(ani); // nothing registered — pages() will throw

      await expectLater(
        repo.warmPages('c9', sourceId: 'ani:missing'),
        completes,
      );
    });

    // Reading a long series must not grow the cache without bound; a page list
    // is small but 500 of them are not.
    test('the cache holds a bounded number of chapters', () async {
      final (repo, fake) = harness();

      for (var i = 0; i < 14; i++) {
        await repo.pages('c$i', sourceId: 'ani:manga');
      }
      // c0 and c1 were pushed out by the 12-chapter cap; c13 is still there.
      await repo.pages('c13', sourceId: 'ani:manga');
      expect(fake.calls.where((c) => c == 'c13').length, 1);

      await repo.pages('c0', sourceId: 'ani:manga');
      expect(fake.calls.where((c) => c == 'c0').length, 2);
    });
  });
}

/// Holds its answer open so a test can start a second request while the first
/// is still in the air.
class _GatedProvider extends _CountingProvider {
  _GatedProvider(super.sourceId, this.gate);

  final Future<List<PageImage>> gate;

  @override
  Future<List<PageImage>> getPages(String chapterUrl) {
    calls.add(chapterUrl);
    return gate;
  }
}
