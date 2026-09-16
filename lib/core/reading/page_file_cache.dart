import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../cache/app_image_cache.dart';
import '../download/cbz_image.dart';
import '../platform/app_paths.dart';

/// Resolves a chapter page to a real file on disk, because a region decoder
/// needs a file descriptor and most pages do not have one.
///
/// Four page kinds, in resolution order:
///  1. a page inside a `.cbz` (`cbz:/path/Chapter 1.cbz#3`) — read the entry
///     and cache it as a file.
///  2. a loose local file — handed back directly, never copied.
///  3. a scrambled/native-provider page (`x-mihon-src` / `x-ani-src` header)
///     — fetched through the same native channel the image provider uses,
///     then cached as a file.
///  4. an ordinary network page — only returned if it's already in the image
///     disk cache; this class never downloads, or a page ends up fetched
///     twice.
class PageFileCache {
  PageFileCache({
    Directory? dir,
    this.maxBytes = 256 * 1024 * 1024,
    Future<Uint8List?> Function(String archivePath, int index)? readCbzEntry,
    Future<Uint8List?> Function(String channel, int sourceId, String url)?
    fetchNativeBytes,
    Future<File?> Function(String url)? lookupCachedFile,
  }) : _dir = dir,
       _readCbzEntry = readCbzEntry ?? readCbzArchiveEntry,
       _fetchNativeBytes = fetchNativeBytes ?? _defaultFetchNativeBytes,
       _lookupCachedFile = lookupCachedFile ?? _defaultLookupCachedFile;

  final Directory? _dir;
  final int maxBytes;
  final Future<Uint8List?> Function(String archivePath, int index)
  _readCbzEntry;
  final Future<Uint8List?> Function(String channel, int sourceId, String url)
  _fetchNativeBytes;
  // Kept behind a seam like the other two native-ish paths: flutter_cache_
  // manager's default store is sqflite-backed, and sqflite has no
  // databaseFactory in a plain unit test — the failure surfaces from a
  // detached future chain a try/catch can't see, so it hangs the test
  // instead of throwing. Real callers get the real cache; tests get a fake.
  final Future<File?> Function(String url) _lookupCachedFile;

  /// The page's bytes as a file, or null when one cannot be had.
  /// Never throws: a page that cannot be resolved just means no tiling.
  Future<File?> fileFor(String url, Map<String, String>? headers) async {
    try {
      final cbz = CbzImage.tryParse(url);
      if (cbz != null) {
        return _cacheBytes(
          url,
          () => _readCbzEntry(cbz.archivePath, cbz.index),
        );
      }

      if (!url.startsWith('http')) {
        final f = File(url);
        return await f.exists() ? f : null;
      }

      final mihonId = headers?['x-mihon-src'];
      final aniId = headers?['x-ani-src'];
      final marker = mihonId ?? aniId;
      if (marker != null) {
        final id = int.tryParse(marker);
        if (id == null) return null;
        final channel = mihonId != null ? 'zangetsu/mihon' : 'zangetsu/aniyomi';
        return _cacheBytes(url, () => _fetchNativeBytes(channel, id, url));
      }

      return await _lookupCachedFile(url);
    } catch (_) {
      return null;
    }
  }

  /// Total bytes currently held.
  Future<int> size() async {
    final dir = await _resolveDir();
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Deletes oldest-first until under [maxBytes].
  Future<void> trim() async {
    final dir = await _resolveDir();
    if (!await dir.exists()) return;

    final stats = <File, FileStat>{};
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      stats[entity] = stat;
      total += stat.size;
    }
    if (total <= maxBytes) return;

    final files = stats.keys.toList()
      ..sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    for (final f in files) {
      if (total <= maxBytes) break;
      try {
        await f.delete();
        total -= stats[f]!.size;
      } catch (_) {
        // Already gone, or in use — leave it for the next trim.
      }
    }
  }

  /// Removes everything. For the Storage settings screen later.
  Future<void> clear() async {
    final dir = await _resolveDir();
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  /// Writes [fetch]'s bytes to this url's cache file, unless it's already
  /// there — a second call for the same url neither re-fetches nor rewrites.
  Future<File?> _cacheBytes(
    String url,
    Future<Uint8List?> Function() fetch,
  ) async {
    final dir = await _resolveDir();
    final file = File('${dir.path}/${_cacheFileName(url)}');
    if (await file.exists()) return file;

    final bytes = await fetch();
    if (bytes == null || bytes.isEmpty) return null;

    await file.writeAsBytes(bytes, flush: true);
    unawaited(trim());
    return file;
  }

  Future<Directory> _resolveDir() async {
    final d = _dir;
    if (d != null) {
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    }
    return writableAppSubdir('page_files');
  }
}

Future<File?> _defaultLookupCachedFile(String url) async {
  final info = await AppImageCache.manager.getFileFromCache(url);
  return info?.file;
}

Future<Uint8List?> _defaultFetchNativeBytes(
  String channel,
  int sourceId,
  String url,
) async {
  try {
    return await MethodChannel(channel).invokeMethod<Uint8List>('getImage', {
      'sourceId': sourceId,
      'url': url,
    });
  } catch (_) {
    return null;
  }
}

/// Keys on a stable hash of the url so two pages at the same url map to the
/// same file, and keeps the url's own extension where it has a sane one —
/// the region decoder sniffs the format either way, but a real extension
/// helps anyone poking at the cache dir by hand.
String _cacheFileName(String url) {
  final hash = sha1.convert(utf8.encode(url)).toString();
  return '$hash${_extensionOf(url)}';
}

String _extensionOf(String url) {
  final withoutQuery = url.split('?').first;
  final slash = withoutQuery.lastIndexOf('/');
  final name = slash == -1
      ? withoutQuery
      : withoutQuery.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '.img';
  final ext = name.substring(dot);
  // A `cbz:` url's tail is `Chapter 1.cbz#3`, not a page extension — guard
  // against picking that up as one.
  if (ext.length > 6 || ext.contains('#') || ext.contains(':')) return '.img';
  return ext;
}
