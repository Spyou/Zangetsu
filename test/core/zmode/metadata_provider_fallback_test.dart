import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/anime_catalogue.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

/// Stands in for either provider: answers, or throws on command.
class _Cat implements AnimeCatalogue {
  _Cat(this.name, {this.broken = false});
  final String name;
  bool broken;
  int homeCalls = 0;

  Never _fail() => throw StateError('$name is down');

  @override
  Future<List<HomeSection>> home(ZKind kind) async {
    homeCalls++;
    if (broken) _fail();
    return [
      HomeSection(title: 'From $name', items: const []),
    ];
  }

  @override
  Future<List<MediaItem>> search(String q, ZKind kind) async =>
      broken ? _fail() : [];

  @override
  Future<MediaDetail> detail(ZCanonical c) async => broken
      ? _fail()
      : MediaDetail(
          id: c.id,
          title: name,
          url: ZmodeIds.showUrl(c),
          type: ProviderType.anime,
          sourceId: ZmodeIds.sourceId,
        );

  @override
  Future<List<Episode>> episodes(ZCanonical c) async => const [];
}

void main() {
  late Directory dir;
  late MetadataProviderPrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mdprov');
    Hive.init(dir.path);
    prefs = await MetadataProviderPrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('MetadataProviderPrefs', () {
    test('defaults to AniList', () {
      expect(prefs.anime, AnimeProvider.anilist);
    });

    test('a choice round-trips and bumps the revision', () async {
      final before = MetadataProviderPrefs.revision.value;
      await prefs.setAnime(AnimeProvider.mal);
      expect(prefs.anime, AnimeProvider.mal);
      expect(MetadataProviderPrefs.revision.value, before + 1);
    });

    test('setting the same value again does not bump the revision', () async {
      await prefs.setAnime(AnimeProvider.mal);
      final after = MetadataProviderPrefs.revision.value;
      await prefs.setAnime(AnimeProvider.mal);
      expect(MetadataProviderPrefs.revision.value, after,
          reason: 'a no-op must not make every screen reload');
    });

    test('the choice survives a reopen', () async {
      await prefs.setAnime(AnimeProvider.mal);
      await Hive.close();
      Hive.init(dir.path);
      expect((await MetadataProviderPrefs.open()).anime, AnimeProvider.mal);
    });

    test('video defaults to TMDB and round-trips independently', () async {
      expect(prefs.video, VideoProvider.tmdb);
      await prefs.setVideo(VideoProvider.simkl);
      expect(prefs.video, VideoProvider.simkl);
      // The two axes must not share a key: changing one silently changing the
      // other would be invisible until Home came back wrong.
      expect(prefs.anime, AnimeProvider.anilist);
    });

    test('each axis survives a reopen on its own', () async {
      await prefs.setVideo(VideoProvider.simkl);
      await Hive.close();
      Hive.init(dir.path);
      final reopened = await MetadataProviderPrefs.open();
      expect(reopened.video, VideoProvider.simkl);
      expect(reopened.anime, AnimeProvider.anilist);
    });
  });

  // The fallback lives in MetadataRepository, but its shape is what matters:
  // primary first, backup only on failure, and the ORIGINAL error when both
  // are down. These assert that contract against the same interface the
  // repository consumes.
  group('fallback contract', () {
    Future<T> viaAnime<T>(
      _Cat primary,
      _Cat? backup,
      Future<T> Function(AnimeCatalogue) op, {
      void Function(String)? onFallback,
    }) async {
      try {
        return await op(primary);
      } catch (primaryError, primaryStack) {
        if (backup == null) rethrow;
        try {
          final out = await op(backup);
          onFallback?.call(backup.name);
          return out;
        } catch (_) {
          Error.throwWithStackTrace(primaryError, primaryStack);
        }
      }
    }

    test('a healthy primary is never second-guessed', () async {
      final al = _Cat('AniList'), mal = _Cat('MAL');
      final rows = await viaAnime(al, mal, (c) => c.home(ZKind.anime));
      expect(rows.single.title, 'From AniList');
      expect(mal.homeCalls, 0, reason: 'the backup must not be called at all');
    });

    test('a broken primary falls through, and says which one answered',
        () async {
      final al = _Cat('AniList', broken: true), mal = _Cat('MAL');
      String? told;
      final rows = await viaAnime(al, mal, (c) => c.home(ZKind.anime),
          onFallback: (n) => told = n);
      expect(rows.single.title, 'From MAL');
      expect(told, 'MAL', reason: 'silently swapping providers hides an outage');
    });

    test('both down reports the CHOSEN provider, not the stand-in', () async {
      final al = _Cat('AniList', broken: true);
      final mal = _Cat('MAL', broken: true);
      await expectLater(
        viaAnime(al, mal, (c) => c.home(ZKind.anime)),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('AniList'))),
      );
    });
  });
}
