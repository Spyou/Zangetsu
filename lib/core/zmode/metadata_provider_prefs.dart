import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';

/// Who supplies anime/manga metadata.
enum AnimeProvider { anilist, mal }

/// Who supplies movie/TV metadata.
enum VideoProvider { tmdb, simkl }

/// The user's metadata provider choice, and nothing else — which provider is
/// actually answering right now is [MetadataRepository]'s business, since it
/// falls back on its own when the chosen one is unreachable.
class MetadataProviderPrefs {
  MetadataProviderPrefs._(this._box);
  final Box _box;

  static const String boxName = 'metadata_provider';
  static const String _kAnime = 'anime';
  static const String _kVideo = 'video';

  /// Bumped whenever the choice changes, so screens holding cached rows can
  /// reload without every one of them subscribing to Hive.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<MetadataProviderPrefs> open() async =>
      MetadataProviderPrefs._(await openBoxSafely(boxName));

  AnimeProvider get anime =>
      _box.get(_kAnime) == AnimeProvider.mal.name
          ? AnimeProvider.mal
          : AnimeProvider.anilist;

  Future<void> setAnime(AnimeProvider p) async {
    if (p == anime) return;
    await _box.put(_kAnime, p.name);
    revision.value++;
  }

  VideoProvider get video => _box.get(_kVideo) == VideoProvider.simkl.name
      ? VideoProvider.simkl
      : VideoProvider.tmdb;

  Future<void> setVideo(VideoProvider p) async {
    if (p == video) return;
    await _box.put(_kVideo, p.name);
    revision.value++;
  }
}
