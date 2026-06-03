import 'package:hive/hive.dart';

/// Remembers per-title user choices (currently the sub/dub category), keyed by
/// `"<sourceId>::<showUrl>"`. Netflix-style "remember my choice for this title".
class TitlePrefsStore {
  static const String boxName = 'title_prefs';
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  String _key(String sourceId, String showUrl) => '$sourceId::$showUrl';

  String? category(String sourceId, String showUrl) {
    final m = _box.get(_key(sourceId, showUrl));
    final c = m == null ? null : Map<String, dynamic>.from(m)['category'];
    return (c == 'sub' || c == 'dub') ? c as String : null;
  }

  Future<void> setCategory(
    String sourceId,
    String showUrl,
    String category,
  ) async {
    final k = _key(sourceId, showUrl);
    final m = _box.get(k) == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(_box.get(k)!);
    m['category'] = category;
    await _box.put(k, m);
  }

  /// The label of the source the user last picked for this title (e.g. a
  /// language/server name). Used to re-select the same source on reopen for
  /// providers that expose languages as separate sources (e.g. 4khdhub).
  String? sourceLabel(String sourceId, String showUrl) {
    final m = _box.get(_key(sourceId, showUrl));
    final v = m == null ? null : Map<String, dynamic>.from(m)['sourceLabel'];
    return (v is String && v.isNotEmpty) ? v : null;
  }

  Future<void> setSourceLabel(
    String sourceId,
    String showUrl,
    String label,
  ) async {
    final k = _key(sourceId, showUrl);
    final m = _box.get(k) == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(_box.get(k)!);
    m['sourceLabel'] = label;
    await _box.put(k, m);
  }

  /// Whether this title is marked as a favorite. Keyed identically to the
  /// sub/dub choice so a title's UI prefs all travel together.
  bool isFavorite(String sourceId, String showUrl) {
    final m = _box.get(_key(sourceId, showUrl));
    if (m == null) return false;
    return Map<String, dynamic>.from(m)['favorite'] == true;
  }

  /// Flip the favorite flag and return the new value.
  Future<bool> toggleFavorite(String sourceId, String showUrl) async {
    final k = _key(sourceId, showUrl);
    final m = _box.get(k) == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(_box.get(k)!);
    final next = !(m['favorite'] == true);
    m['favorite'] = next;
    await _box.put(k, m);
    return next;
  }
}
