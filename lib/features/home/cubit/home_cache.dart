import 'package:hive/hive.dart';

import '../../../core/hive/safe_box.dart';
import '../../../core/models/home_section.dart';
import '../../../core/models/media_item.dart';

/// Last good Home rows, persisted per source so launch shows real content
/// instantly and refreshes silently underneath.
///
/// The provider hands all rows over in one call, so per-row lazy loading is
/// impossible — this is the equivalent win: yesterday's rows paint on the
/// first frame, today's replace them when they arrive. Same rows, same order,
/// same screen; only the wait is gone.
///
/// Never worse than no cache: a miss/expired/corrupt entry simply shows the
/// normal loading state, and fresh rows overwrite the cache on every
/// successful load.
class HomeCache {
  static const String boxName = 'home_cache';

  /// Rows per section are capped — covers/posters reload from the image cache
  /// anyway; the JSON is just titles and urls.
  static const int maxItemsPerSection = 30;

  /// A cached home older than this is still shown (beats a spinner) but a
  /// fresh load always overwrites it on success.
  static const Duration maxAge = Duration(days: 7);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  static String _key(String sourceId, String kind) => '$sourceId|$kind';

  static Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// The last good sections for [sourceId]+[kind], or null when there is
  /// nothing usable cached. Never throws.
  static List<HomeSection>? read(String sourceId, String kind) {
    try {
      final box = _box;
      if (box == null) return null;
      final raw = box.get(_key(sourceId, kind));
      if (raw is! Map) return null;
      final m = Map<String, dynamic>.from(raw);
      final savedAt = (m['savedAtMs'] as num?)?.toInt();
      if (savedAt == null ||
          DateTime.now().millisecondsSinceEpoch - savedAt >
              maxAge.inMilliseconds) {
        return null;
      }
      final sections = m['sections'];
      if (sections is! List || sections.isEmpty) return null;
      final out = <HomeSection>[];
      for (final s in sections) {
        if (s is! Map) continue;
        final sm = Map<String, dynamic>.from(s);
        final items = sm['items'];
        if (items is! List) continue;
        final decoded = <MediaItem>[];
        for (final j in items) {
          if (j is! Map) continue;
          try {
            decoded.add(
              MediaItem.fromJson(Map<String, dynamic>.from(j)),
            );
          } catch (_) {
            // One unreadable row item must not drop the whole home.
          }
        }
        if (decoded.isEmpty) continue;
        out.add(HomeSection(title: '${sm['title'] ?? ''}', items: decoded));
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// Remembers a successful load. Best-effort: never throws, never blocks.
  static Future<void> write(
    String sourceId,
    String kind,
    List<HomeSection> sections,
  ) async {
    try {
      final box = _box;
      if (box == null || sections.isEmpty) return;
      await box.put(_key(sourceId, kind), {
        'savedAtMs': DateTime.now().millisecondsSinceEpoch,
        'sections': [
          for (final s in sections)
            {
              'title': s.title,
              'items': [
                for (final i in s.items.take(maxItemsPerSection)) i.toJson(),
              ],
            },
        ],
      });
    } catch (_) {
      // Cache must never break a load.
    }
  }
}
