import 'package:hive/hive.dart';

import '../aniyomi/aniyomi_repo.dart';

/// Remembers `pkg -> icon URL` for Aniyomi and Mihon extensions.
///
/// Those ecosystems load extensions from an APK, and the source objects they
/// hand back carry no icon — only the repo index knows where the logo lives.
/// The index is already fetched for browsing, installing and update checks, so
/// this just keeps what passes through: no extra request, and the picker can
/// read it synchronously while it builds its rows.
///
/// Everything here is best-effort. A missing entry means the row keeps its
/// letter tile, which is the design either way.
class SourceIconStore {
  static const String boxName = 'source_icons';

  static Box<String>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<String>(boxName) : null;

  /// Icon URL for [pkg], or null when we have not seen its repo index yet.
  static String? urlFor(String pkg) {
    final url = _box?.get(pkg);
    return (url == null || url.isEmpty) ? null : url;
  }

  /// Records every entry's icon. Fire-and-forget: callers are parsing a repo
  /// index and must not wait on, or fail because of, a cosmetic write.
  static void recordAll(Iterable<AniyomiRepoEntry> entries) {
    final box = _box;
    if (box == null) return;
    final updates = <String, String>{};
    for (final e in entries) {
      if (e.pkg.isEmpty || e.iconUrl.isEmpty) continue;
      if (box.get(e.pkg) == e.iconUrl) continue;
      updates[e.pkg] = e.iconUrl;
    }
    if (updates.isEmpty) return;
    box.putAll(updates);
  }
}
