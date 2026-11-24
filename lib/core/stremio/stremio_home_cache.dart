import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/home_section.dart';
import '../models/media_item.dart';
import '../tracker/relay/tracker_relay_crypto.dart';
import 'stremio_manager.dart';

/// An encrypted last-good preview; fresh catalogue requests always run alongside it.
///
/// One small file per scope, read and written with async file IO. It used to
/// be a Hive box, but Hive reads (and CRC-checks) a whole box on the UI thread
/// when it opens, and stale overwritten copies pile up until it compacts — the
/// file grew large enough that opening it froze the screen for over a second
/// right after picking a profile.
class StremioHomeCache {
  StremioHomeCache({
    StremioSecretStore? secrets,
    DateTime Function()? clock,
    Directory? directory,
  }) : _secrets = secrets ?? const StremioSecureStore(),
       _clock = clock ?? DateTime.now,
       _directory = directory;

  /// Name of the old Hive box; only used to delete it.
  static const boxName = 'stremio_home_cache';
  static const _keep = 8;
  static const _keyName = 'stremio:home-cache:key';
  static const _maxBytes = 2 * 1024 * 1024;
  final StremioSecretStore _secrets;
  final DateTime Function() _clock;
  final Directory? _directory;
  Future<void>? _legacy;
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

  Future<Directory>? _folderFuture;

  Future<Directory> _folder() => _folderFuture ??= () async {
    final base = _directory;
    if (base != null) return base;
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/stremio_home_cache');
  }();

  Future<File> _file(String id) async =>
      File('${(await _folder()).path}/$id.bin');

  /// The old box is dead weight now; drop it once (a cache, so nothing to save).
  Future<void> _dropLegacyBox() => _legacy ??= () async {
    try {
      if (!Hive.isBoxOpen(boxName)) await Hive.deleteBoxFromDisk(boxName);
    } catch (_) {
      // Hive not initialised (tests) or already gone.
    }
  }();

  Future<List<HomeSection>?> read(String scope) async {
    try {
      unawaited(_dropLegacyBox());
      final id = _digest(scope);
      final file = await _file(id);
      if (!await file.exists()) return null;
      final data = await file.readAsString();
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
      unawaited(_dropLegacyBox());
      final id = _digest(scope);
      final file = await _file(id);
      if (sections.isEmpty) {
        if (await file.exists()) await file.delete();
        return;
      }
      final at = _clock().millisecondsSinceEpoch;
      final key = await _key();
      final data = await Isolate.run(() => _encode(sections, id, at, key));
      if (data == null) return;
      await (await _folder()).create(recursive: true);
      // Write beside, then rename: a crash mid-write can't leave a torn file.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(data, flush: true);
      await tmp.rename(file.path);
      await _evictOldest();
    } catch (_) {
      // A cache write must never block browsing or change saved user data.
    }
  }

  /// Keep only the newest [_keep] previews.
  Future<void> _evictOldest() async {
    final files = [
      for (final entry in await (await _folder()).list().toList())
        if (entry is File && entry.path.endsWith('.bin')) entry,
    ];
    if (files.length <= _keep) return;
    final stamped = [
      for (final f in files) (file: f, at: (await f.stat()).modified),
    ]..sort((a, b) => a.at.compareTo(b.at));
    for (final old in stamped.take(stamped.length - _keep)) {
      await old.file.delete();
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
