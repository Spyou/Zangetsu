import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../mode/content_mode.dart';

/// A subscribed show — we re-check its source for new episodes or chapters
/// (CloudStream-style). [lastCount] is the count seen at the last check; a
/// higher count on a later check means there's something new → notify.
class Subscription {
  const Subscription({
    required this.sourceId,
    required this.url,
    required this.title,
    this.cover,
    this.coverHeaders,
    this.lastCount = 0,
    this.mode = ContentMode.anime,
  });

  final String sourceId;
  final String url;
  final String title;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final int lastCount;

  /// What this show is, so an alert can say "chapter" rather than "episode"
  /// and tapping it opens the reader instead of the player. Defaults to anime
  /// for subscriptions saved before reading modes were covered.
  final ContentMode mode;

  /// Stable key for the box (one entry per source+show).
  String get key => '$sourceId|$url';

  Subscription copyWith({int? lastCount}) => Subscription(
    sourceId: sourceId,
    url: url,
    title: title,
    cover: cover,
    coverHeaders: coverHeaders,
    lastCount: lastCount ?? this.lastCount,
    mode: mode,
  );

  bool get isReading => mode != ContentMode.anime;

  /// "chapter" / "episode", for the alert text.
  String get unit => isReading ? 'Chapter' : 'Episode';

  Map<String, dynamic> toMap() => {
    'sourceId': sourceId,
    'url': url,
    'title': title,
    'cover': cover,
    'coverHeaders': coverHeaders,
    'lastCount': lastCount,
    'mode': mode.name,
  };

  static Subscription fromMap(Map m) => Subscription(
    sourceId: (m['sourceId'] ?? '').toString(),
    url: (m['url'] ?? '').toString(),
    title: (m['title'] ?? '').toString(),
    cover: m['cover'] as String?,
    coverHeaders: (m['coverHeaders'] is Map)
        ? (m['coverHeaders'] as Map).map((k, v) => MapEntry('$k', '$v'))
        : null,
    lastCount: (m['lastCount'] as num?)?.toInt() ?? 0,
    mode: ContentMode.values.firstWhere(
      (e) => e.name == m['mode'],
      orElse: () => ContentMode.anime,
    ),
  );
}

/// Local, device-only store of subscribed shows (Hive). Opened once at startup
/// — also usable from a background isolate after [init].
class SubscriptionStore {
  static const String boxName = 'subscriptions';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  List<Subscription> all() => _box.values
      .whereType<Map>()
      .map(Subscription.fromMap)
      .where((s) => s.url.isNotEmpty)
      .toList();

  bool contains(String sourceId, String url) =>
      _box.containsKey('$sourceId|$url');

  Future<void> add(Subscription sub) => _box.put(sub.key, sub.toMap());

  Future<void> remove(String sourceId, String url) =>
      _box.delete('$sourceId|$url');

  /// Persist a fresh episode count after a check.
  Future<void> setCount(String sourceId, String url, int count) async {
    final raw = _box.get('$sourceId|$url');
    if (raw is Map) {
      await _box.put('$sourceId|$url', Subscription.fromMap(raw).copyWith(lastCount: count).toMap());
    }
  }
}
