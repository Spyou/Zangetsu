import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import '../models/home_section.dart';
import '../models/media_item.dart';
import '../tracker/relay/tracker_relay_crypto.dart';
import 'stremio_manager.dart';

/// An encrypted last-good preview; fresh catalogue requests always run alongside it.
class StremioHomeCache {
  StremioHomeCache({StremioSecretStore? secrets, DateTime Function()? clock})
    : _secrets = secrets ?? const StremioSecureStore(),
      _clock = clock ?? DateTime.now;

  static const boxName = 'stremio_home_cache';
  static const _keyName = 'stremio:home-cache:key';
  static const _maxBytes = 2 * 1024 * 1024;
  final StremioSecretStore _secrets;
  final DateTime Function() _clock;
  Future<String>? _keyFuture;
  Future<void> _writes = Future.value();

  static String scope({
    required String owner,
    required String profile,
    required Iterable<StremioInstallation> addons,
  }) => _digest(
    jsonEncode([owner, profile, addons.map((item) => item.toJson()).toList()]),
  );

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  Future<String> _key() {
    final running = _keyFuture;
    if (running != null) return running;
    final future = () async {
      final saved = await _secrets.read(_keyName);
      if (saved != null) return saved;
      final key = TrackerRelayCrypto.newNonce();
      await _secrets.write(_keyName, key);
      return key;
    }();
    _keyFuture = future;
    return future.onError((Object error, StackTrace stack) {
      if (identical(_keyFuture, future)) _keyFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<Box> _box() async => Hive.isBoxOpen(boxName)
      ? Hive.box(boxName)
      : await openBoxSafely(boxName);

  Future<List<HomeSection>?> read(String scope) async {
    try {
      final id = _digest(scope);
      final raw = (await _box()).get(id);
      if (raw is! Map || raw['data'] is! String) return null;
      final data = raw['data'] as String;
      if (data.length > _maxBytes * 2) return null;
      final key = await _key();
      final now = _clock().millisecondsSinceEpoch;
      return await Isolate.run(() => _decode(data, key, id, now));
    } catch (_) {
      return null;
    }
  }

  static List<HomeSection>? _decode(
    String data,
    String key,
    String id,
    int now,
  ) {
    final snapshot = jsonDecode(TrackerRelayCrypto.decrypt(data, key)) as Map;
    final age = now - (snapshot['at'] as num).toInt();
    if (snapshot['scope'] != id ||
        snapshot['version'] != 1 ||
        age < 0 ||
        age > const Duration(days: 7).inMilliseconds) {
      return null;
    }
    return [
      for (final rawSection in snapshot['sections'] as List)
        HomeSection(
          title: rawSection['title'] as String,
          items: [
            for (final rawItem in rawSection['items'] as List)
              MediaItem.fromJson(
                Map<String, dynamic>.from(rawItem as Map),
              ).copyWith(
                titleLogo: rawItem['titleLogo'] as String?,
                posterShape: rawItem['posterShape'] as String?,
                landscapePoster: rawItem['landscapePoster'] as String?,
              ),
          ],
          more: rawSection['more'] == null
              ? null
              : BrowseMore(
                  sourceId: rawSection['more']['sourceId'] as String,
                  kind: rawSection['more']['kind'] as String,
                  categoryId: rawSection['more']['categoryId'] as String?,
                ),
        ),
    ];
  }

  Future<void> write(String scope, List<HomeSection> sections) =>
      _writes = _writes.then((_) => _write(scope, sections));

  Future<void> _write(String scope, List<HomeSection> sections) async {
    try {
      final id = _digest(scope);
      if (sections.isEmpty) {
        await (await _box()).delete(id);
        return;
      }
      final at = _clock().millisecondsSinceEpoch;
      final key = await _key();
      final data = await Isolate.run(() => _encode(sections, id, at, key));
      if (data == null) return;
      final box = await _box();
      await box.put(id, {'at': at, 'data': data});
      final keys = box.keys.toList()
        ..sort(
          (a, b) => ((box.get(a)?['at'] as num?) ?? 0).compareTo(
            (box.get(b)?['at'] as num?) ?? 0,
          ),
        );
      if (keys.length > 8) await box.deleteAll(keys.take(keys.length - 8));
    } catch (_) {
      // A cache write must never block browsing or change saved user data.
    }
  }

  static String? _encode(
    List<HomeSection> sections,
    String id,
    int at,
    String key,
  ) {
    final rows = <Map<String, dynamic>>[];
    var bytes = 1024;
    for (final section in sections.take(100)) {
      // Keep pages complete so cached See All pagination cannot skip titles.
      final row = <String, dynamic>{
        'title': section.title,
        'items': [
          for (final item in section.items)
            {
              ...item.toJson(),
              'titleLogo': item.titleLogo,
              'posterShape': item.posterShape,
              'landscapePoster': item.landscapePoster,
            },
        ],
        'more': section.more == null
            ? null
            : {
                'sourceId': section.more!.sourceId,
                'kind': section.more!.kind,
                'categoryId': section.more!.categoryId,
              },
      };
      bytes += utf8.encode(jsonEncode(row)).length;
      if (bytes > _maxBytes) break;
      rows.add(row);
    }
    if (rows.isEmpty) return null;
    final snapshot = {'version': 1, 'scope': id, 'at': at, 'sections': rows};
    final encoded = jsonEncode(snapshot);
    if (utf8.encode(encoded).length > _maxBytes) return null;
    return TrackerRelayCrypto.encrypt(encoded, key);
  }
}
