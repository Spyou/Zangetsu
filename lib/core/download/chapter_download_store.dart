import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../di/injector.dart';
import '../logging/app_logger.dart';
import '../mode/content_mode.dart';
import 'cbz_image.dart';
import 'chapter_download.dart';
import 'download_prefs.dart';

/// Hive-backed index of saved manga/novel chapters, plus the on-disk layout
/// they live in.
///
/// Deliberately separate from the `downloads` box: video records carry
/// quality/sub/dub/torrent fields, and nothing about a chapter fits them.
///
/// A chapter is fetched into an app-private staging folder and only published
/// once every page is on disk, so a run that dies can't leave a half chapter
/// reading as complete. Publishing puts it where the "Saving to" line on the
/// Downloads screen says it goes:
///   `Zangetsu/<Show>/<Chapter>.cbz` (manga — a zip of the pages)
///   `Zangetsu/<Show>/<Chapter>/text.html` (novel)
///
/// Manga is packed into a `.cbz` rather than left as loose images for two
/// reasons: the gallery scanner picks up loose pages and floods the user's
/// photos with them, and any comic reader can open a cbz.
/// under the shared Downloads folder, or under a picked drive if the user set
/// one. From Android 10 the app can't write there directly, so pages go in via
/// MediaStore and the resulting paths are recorded on the chapter — see
/// [ChapterDownload.pagePaths].
class ChapterDownloadStore {
  static const String boxName = 'chapter_downloads';

  /// Sibling of the real chapter folder that a download writes into. It's
  /// renamed into place once the whole chapter is on disk, so an app killed
  /// mid-run can never leave a half chapter that reads as complete.
  static const String partSuffix = '.part';

  static const String textFile = 'text.html';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  /// Notifies the downloads screen on any add/update/delete.
  ValueListenable<Box<Map>> listenable() => _box.listenable();

  /// Parsed records, newest first.
  ///
  /// Cached, because this deserialises and sorts the whole box and the
  /// downloads screen asks for it on every rebuild — with a few thousand saved
  /// chapters that was the screen's entire frame budget. Every write below
  /// drops the cache, and writes are the only way the box changes.
  List<ChapterDownload> all() {
    final cached = _cache;
    if (cached != null) return cached;
    final out = _box.values
        .map(ChapterDownload.fromJson)
        .whereType<ChapterDownload>()
        .toList();
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return _cache = List.unmodifiable(out);
  }

  List<ChapterDownload>? _cache;

  /// Counts without building the parsed list — the Downloads screen only wants
  /// two numbers, and reading the raw maps skips a few thousand `fromJson`.
  int countDone(ContentMode mode) {
    final name = mode.name;
    var n = 0;
    for (final raw in _box.values) {
      if (raw['status'] == 'done' && raw['mode'] == name) n++;
    }
    return n;
  }

  @visibleForTesting
  void invalidateCache() => _cache = null;

  ChapterDownload? get(String id) => ChapterDownload.fromJson(_box.get(id));

  /// True only for a chapter that finished — a queued or failed one still has
  /// a record, but nothing readable behind it.
  bool isDownloaded(String sourceId, String chapterUrl) =>
      get(ChapterDownload.idFor(sourceId, chapterUrl))?.status ==
      ChapterDownloadStatus.done;

  Future<void> put(ChapterDownload d) {
    _cache = null;
    return _box.put(d.id, d.toJson());
  }

  /// One write for a whole batch. Queueing a long series chapter-by-chapter
  /// meant a box write and a listener notify each, which is what made a big
  /// "download all" lock the UI up.
  Future<void> putAll(List<ChapterDownload> ds) {
    _cache = null;
    return _box.putAll({for (final d in ds) d.id: d.toJson()});
  }

  /// Drops the record and the files. Both halves are best-effort: a record
  /// with no folder (or the reverse) is still worth clearing.
  Future<void> remove(String id) async {
    _cache = null;
    final d = get(id);
    if (d != null) {
      // The reader may still hold the archive open.
      if (d.archivePath != null) releaseCbz();
      for (final p in [...d.pagePaths, ?d.textPath, ?d.archivePath]) {
        try {
          await File(p).delete();
        } catch (_) {
          // Already gone, or the user deleted it themselves. Either way the
          // record still goes.
        }
      }
      final dir = await dirFor(d);
      await deleteDir(dir);
      await deleteDir(Directory('${dir.path}$partSuffix'));
    }
    await _box.delete(id);
  }

  Future<Directory> dirFor(ChapterDownload d) async {
    final root = await _root();
    return Directory(
      '${root.path}/${safeName(d.sourceId)}/${_hash(d.chapterUrl)}',
    );
  }

  /// Absolute page paths in reading order. Empty when the chapter isn't
  /// downloaded (or is a novel).
  Future<List<String>> localPages(ChapterDownload d) async {
    if (d.mode == ContentMode.novel) return const [];
    final archive = d.archivePath;
    if (archive != null) {
      // Trust the recorded count, but check the archive still holds that many
      // — a half-copied file would otherwise read as a chapter with holes.
      final n = await cbzPageCount(archive);
      if (n == 0) return const [];
      return [for (var i = 0; i < n; i++) cbzUrl(archive, i)];
    }
    if (d.pagePaths.isNotEmpty) {
      // Published chapter. Every page has to still be there — a user who
      // deleted a few from a file manager should get the source's pages, not a
      // chapter with holes in it.
      for (final p in d.pagePaths) {
        if (!await File(p).exists()) return const [];
      }
      return d.pagePaths;
    }
    final dir = await dirFor(d);
    if (!await dir.exists()) return const [];
    final files = (await dir.list().toList())
        .whereType<File>()
        .where((f) => !f.path.endsWith(partSuffix))
        .toList();
    // Names are zero-padded (001, 002 …) so plain string order is page order.
    files.sort((a, b) => a.path.compareTo(b.path));
    return files.map((f) => f.path).toList();
  }

  /// Saved chapter HTML, or null when it isn't downloaded.
  Future<String?> localText(ChapterDownload d) async {
    if (d.textPath != null) {
      final saved = File(d.textPath!);
      return await saved.exists() ? saved.readAsString() : null;
    }
    final f = File('${(await dirFor(d)).path}/$textFile');
    return await f.exists() ? f.readAsString() : null;
  }

  /// Move a finished chapter out of staging and into the user's download
  /// folder. Returns the record with the published paths recorded on it, or
  /// unchanged if publishing failed — a chapter that's readable where it
  /// already sits beats one lost to a failed move.
  Future<ChapterDownload> publish(ChapterDownload d, Directory staged) async {
    final files = (await staged.list().toList()).whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) return d;

    final show = 'Zangetsu/${safeName(d.showTitle)}';
    final chapter = safeName(d.chapterTitle);
    // Manga leaves as one archive; a novel is a single html file already.
    final packed = d.mode == ContentMode.novel
        ? files
        : [await zipPages(files, staged, chapter)];
    final sub = d.mode == ContentMode.novel ? '$show/$chapter' : show;

    final drive = _drivePath();
    final moved = <String>[];
    try {
      for (final f in packed) {
        final to = drive != null
            ? await _moveToDrive(f, '$drive/$sub')
            : await FileDownloader().moveFileToSharedStorage(
                f.path,
                SharedStorage.downloads,
                directory: sub,
              );
        if (to == null) throw const FileSystemException('move returned null');
        moved.add(to);
      }
    } catch (e) {
      AppLogger.instance.log(
        '[chapters] keeping ${d.chapterTitle} in app storage — $e',
        level: 'W',
      );
      // Roll back the half-move so the chapter isn't split across two places.
      for (final m in moved) {
        try {
          await File(m).delete();
        } catch (_) {}
      }
      return d;
    }

    await deleteDir(staged);
    return d.mode == ContentMode.novel
        ? d.copyWith(textPath: moved.first)
        : d.copyWith(archivePath: moved.first, pageCount: files.length);
  }

  /// Pack a chapter's pages into a `.cbz` beside the staging folder.
  ///
  /// Stored, not deflated — JPEG and WebP are already compressed, so deflating
  /// them burns CPU to save nothing, and stored entries read back as a plain
  /// seek and copy.
  @visibleForTesting
  static Future<File> zipPages(
    List<File> pages,
    Directory staged,
    String chapterName,
  ) async {
    final out = '${staged.parent.path}/$chapterName.cbz';
    final encoder = ZipFileEncoder()..create(out);
    final streams = <InputFileStream>[];
    try {
      for (final p in pages) {
        // `level` doesn't decide this — the encoder reads `compression` off
        // the entry and defaults it to deflate, so it has to be set here.
        final stream = InputFileStream(p.path);
        streams.add(stream);
        encoder.addArchiveFile(
          ArchiveFile.stream(p.uri.pathSegments.last, stream)
            ..compression = CompressionType.none,
        );
      }
    } finally {
      await encoder.close();
      for (final st in streams) {
        await st.close();
      }
    }
    return File(out);
  }

  /// A picked drive (USB/SD) is a plain path we can write to directly. A SAF
  /// `content://` tree isn't — pages there couldn't be opened back as images,
  /// so those users get the shared Downloads folder instead.
  static String? _drivePath() {
    if (!sl.isRegistered<DownloadPrefs>()) return null;
    final loc = sl<DownloadPrefs>().locationUri;
    if (loc == null || loc.isEmpty || isUriPath(loc)) return null;
    return loc;
  }

  static Future<String> _moveToDrive(File f, String dirPath) async {
    await Directory(dirPath).create(recursive: true);
    final to = '$dirPath/${f.uri.pathSegments.last}';
    await f.copy(to);
    await f.delete();
    return to;
  }

  static Future<void> deleteDir(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // A locked or already-vanished folder isn't worth failing a delete over.
    }
  }

  Directory? _cachedRoot;

  /// Staging root, and where chapters from older builds still live.
  Future<Directory> _root() async =>
      _cachedRoot ??= Directory(
        '${(await getApplicationSupportDirectory()).path}/chapters',
      );

  static String _hash(String url) =>
      crypto.sha1.convert(utf8.encode(url)).toString();

  /// Trim a title down to something a filesystem accepts, keeping it readable.
  ///
  /// Only the characters that are actually illegal go — spaces are fine, and
  /// replacing them turned `Chapter 1: Outer Court Disciple` into
  /// `Chapter_1___Outer_Court_Disciple`. Trailing dots and spaces go too
  /// (FAT/exFAT on an SD card rejects them), and the length is capped well
  /// under the 255-byte limit most filesystems have.
  static String safeName(String s) {
    final cleaned = s
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final capped = cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
    final trimmed = capped.replaceAll(RegExp(r'[. ]+$'), '');
    return trimmed.isEmpty ? 'source' : trimmed;
  }
}
