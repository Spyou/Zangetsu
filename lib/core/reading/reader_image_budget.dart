import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/painting.dart';

/// Raises Flutter's image cache for as long as a chapter is open, and puts it
/// back on the way out.
///
/// The app-wide budget is 80MB (`main.dart`), sized for covers and posters. A
/// manga page is a different animal: `ResizeImage` caps width only, so a slice
/// keeps its full aspect and one page can run to tens of megabytes. Measured on
/// device mid-scroll, the cache sat pinned at **79.4 / 80MB** with 19 images —
/// full, permanently, evicting a page for every page it took in. Frames were
/// fine (1020 rendered, 2 janky); what the reader felt as lag was pages that
/// had been thrown away and had to be decoded again.
///
/// So the ceiling is lifted while reading, and only while reading — nothing
/// else in the app gets a bigger budget, and the memory is handed back when
/// the chapter closes.
class ReaderImageBudget {
  ReaderImageBudget._();

  /// Multiple of the app-wide budget to allow while a chapter is open, by how
  /// much RAM the device actually has. A 2GB phone must not be asked to hold
  /// 200MB of bitmaps — there is at least one Android 8 device in the shared
  /// reports already struggling to load a native library.
  static int budgetFor(int ramMb) {
    if (ramMb >= 7000) return 320 << 20; // 8GB+
    if (ramMb >= 5500) return 256 << 20; // 6GB
    if (ramMb >= 3500) return 192 << 20; // 4GB
    if (ramMb >= 2500) return 128 << 20; // 3GB
    return 0; // 2GB or unknown — leave the app budget alone
  }

  static int? _saved;
  static int? _savedCount;
  static int _depth = 0;

  /// Cached across chapters: the lookup is a platform channel round trip and
  /// the answer cannot change while the app is running.
  static int? _ramMb;

  /// Call when a reader opens. Safe to nest — two readers (a chapter and the
  /// next one pulled in) only raise it once.
  static Future<void> acquire() async {
    _depth++;
    if (_depth > 1 || _saved != null) return;
    final ram = await _ram();
    final want = budgetFor(ram);
    if (want == 0) return;
    final cache = PaintingBinding.instance.imageCache;
    if (want <= cache.maximumSizeBytes) return;
    _saved = cache.maximumSizeBytes;
    _savedCount = cache.maximumSize;
    cache.maximumSizeBytes = want;
    // The count ceiling has to move too, or a chapter of small pages hits 300
    // images long before it hits the byte budget.
    cache.maximumSize = 600;
  }

  /// Call when the reader closes. Restoring the ceiling evicts down to it,
  /// which is the point: the pages go back to the OS rather than sitting in a
  /// cache nothing is reading from.
  static void release() {
    if (_depth > 0) _depth--;
    if (_depth > 0) return;
    final saved = _saved;
    if (saved == null) return;
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = saved;
    cache.maximumSize = _savedCount ?? 300;
    _saved = null;
    _savedCount = null;
  }

  static Future<int> _ram() async {
    final memo = _ramMb;
    if (memo != null) return memo;
    if (!Platform.isAndroid) return _ramMb = 0;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return _ramMb = info.physicalRamSize;
    } catch (_) {
      // No answer is not permission to take more memory.
      return _ramMb = 0;
    }
  }

  /// Test seam — lets a test drive [acquire] without a platform channel.
  static set debugRamMb(int? mb) => _ramMb = mb;

  /// Test seam — the reader is a singleton screen in practice, but a test
  /// that never calls [release] would leak the depth into the next one.
  static void debugReset() {
    _depth = 0;
    _saved = null;
    _savedCount = null;
    _ramMb = null;
  }
}
