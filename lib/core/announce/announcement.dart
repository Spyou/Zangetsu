import 'package:hive/hive.dart';

/// A developer announcement fetched from the app's public announcements.json.
///
/// Read-only content: everything is rendered as plain text, and [actionUrl]
/// (if any) is opened in the system browser — only http/https are honoured.
/// No code is ever executed from an announcement.
class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    this.type = 'info',
    this.actionLabel,
    this.actionUrl,
    this.date,
    this.imageUrl,
  });

  /// Unique, stable id. Drives "show once" — never reuse an id for new content.
  final String id;
  final String title;
  final String body;

  /// 'info' | 'warning' | 'update' — drives the sheet's icon/accent only.
  final String type;

  /// Optional call-to-action. [actionUrl] opens in the browser (http/https).
  final String? actionLabel;
  final String? actionUrl;

  /// Publish date string from the JSON (display only).
  final String? date;

  /// Optional image — shown full-width in the sheet and as the list thumbnail.
  final String? imageUrl;

  /// Parse one entry from the fetched JSON. Returns null when it's missing the
  /// required id/title, or when the action is malformed (so bad data is skipped
  /// rather than crashing the fetch).
  static Announcement? fromJson(Map<dynamic, dynamic> m) {
    final id = (m['id'] ?? '').toString().trim();
    final title = (m['title'] ?? '').toString().trim();
    if (id.isEmpty || title.isEmpty) return null;

    String? label;
    String? url;
    final action = m['action'];
    if (action is Map) {
      final l = (action['label'] ?? '').toString().trim();
      final u = (action['url'] ?? '').toString().trim();
      // Only honour real web links; anything else is dropped (no code exec).
      if (l.isNotEmpty && (u.startsWith('http://') || u.startsWith('https://'))) {
        label = l;
        url = u;
      }
    }

    final img = (m['imageUrl'] ?? m['image'] ?? '').toString().trim();
    return Announcement(
      id: id,
      title: title,
      body: (m['body'] ?? '').toString().trim(),
      type: (m['type'] ?? 'info').toString().trim().toLowerCase(),
      actionLabel: label,
      actionUrl: url,
      date: (m['date'] as String?)?.trim(),
      imageUrl: img.isEmpty ? null : img,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'body': body,
    'type': type,
    'actionLabel': actionLabel,
    'actionUrl': actionUrl,
    'date': date,
    'imageUrl': imageUrl,
  };

  static Announcement fromMap(Map m) => Announcement(
    id: (m['id'] ?? '').toString(),
    title: (m['title'] ?? '').toString(),
    body: (m['body'] ?? '').toString(),
    type: (m['type'] ?? 'info').toString(),
    actionLabel: m['actionLabel'] as String?,
    actionUrl: m['actionUrl'] as String?,
    date: m['date'] as String?,
    imageUrl: m['imageUrl'] as String?,
  );
}

/// Local, device-only store of received announcements (Hive). Keeps the history
/// shown in the Notifications screen and a per-id "seen" flag so the launch
/// sheet pops only once per announcement.
class AnnouncementStore {
  static const String boxName = 'announcements';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
  }

  Box get _box => Hive.box(boxName);

  bool has(String id) => _box.containsKey(id);

  /// Store a newly-received announcement as unseen. No-op if already stored, so
  /// re-fetching the same feed never resurrects a dismissed one. [receivedAt] is
  /// a monotonic stamp used only for ordering the history list.
  Future<void> saveNew(Announcement a, int receivedAt) async {
    if (_box.containsKey(a.id)) return;
    await _box.put(a.id, {...a.toMap(), 'seen': false, 'receivedAt': receivedAt});
  }

  Future<void> markSeen(String id) async {
    final raw = _box.get(id);
    if (raw is Map && raw['seen'] != true) {
      await _box.put(id, {...raw, 'seen': true});
    }
  }

  Future<void> markAllSeen() async {
    for (final k in _box.keys.toList()) {
      final raw = _box.get(k);
      if (raw is Map && raw['seen'] != true) {
        await _box.put(k, {...raw, 'seen': true});
      }
    }
  }

  /// Received announcements, newest first (by [receivedAt]).
  List<Announcement> all() {
    final rows = _box.values.whereType<Map>().toList()
      ..sort(
        (a, b) => ((b['receivedAt'] as num?) ?? 0)
            .compareTo((a['receivedAt'] as num?) ?? 0),
      );
    return rows.map(Announcement.fromMap).toList();
  }

  /// Whether a given stored announcement id is still unseen.
  bool isUnseen(String id) {
    final raw = _box.get(id);
    return raw is Map && raw['seen'] != true;
  }

  int unseenCount() =>
      _box.values.whereType<Map>().where((m) => m['seen'] != true).length;
}
