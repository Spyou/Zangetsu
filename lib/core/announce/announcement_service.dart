import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_config.dart';
import 'announcement.dart';

/// Fetches the developer announcements feed (a public JSON file in the app repo)
/// and records any not-yet-seen announcements that target the running version.
///
/// Read-only and fail-safe: offline, GitHub down, or malformed JSON all resolve
/// to "nothing new" — it never throws and never blocks launch.
class AnnouncementService {
  AnnouncementService(this._dio, this._store);

  final Dio _dio;
  final AnnouncementStore _store;

  /// Fetch + store new announcements. Returns the freshly-arrived ones (newest
  /// first) so the caller can pop the launch sheet; the history list reads from
  /// the store. Returns `[]` on any error.
  Future<List<Announcement>> check() async {
    try {
      final res = await _dio.get<String>(
        kAnnouncementsUrl,
        options: Options(
          // raw.githubusercontent serves .json as text/plain, so take the raw
          // body and decode it ourselves rather than trusting content-type.
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
        ),
      );
      final list = _extractList(res.data);
      if (list.isEmpty) return const [];

      final current = _normalize((await PackageInfo.fromPlatform()).version);
      final fresh = <Announcement>[];
      var stamp = DateTime.now().millisecondsSinceEpoch;
      for (final raw in list) {
        if (raw is! Map) continue;
        final a = Announcement.fromJson(raw);
        if (a == null) continue;
        if (_store.has(a.id)) continue; // already recorded on a prior run
        await _store.saveNew(a, stamp);
        stamp += 1; // keep insertion order stable for the history list
        if (_targetsVersion(raw, current)) {
          fresh.add(a);
        } else {
          // Out of the target version window → keep it in history but don't pop
          // it (and never pop it later, even after an app update).
          await _store.markSeen(a.id);
        }
      }
      return fresh;
    } catch (_) {
      return const [];
    }
  }

  List _extractList(String? body) {
    if (body == null || body.trim().isEmpty) return const [];
    dynamic data;
    try {
      data = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    if (data is Map && data['announcements'] is List) {
      return data['announcements'] as List;
    }
    if (data is List) return data;
    return const [];
  }

  /// A version-targeted announcement shows only when the running version is
  /// within [minVersion, maxVersion] (either bound optional).
  bool _targetsVersion(Map raw, String current) {
    final min = _normalize((raw['minVersion'] ?? '').toString());
    final max = _normalize((raw['maxVersion'] ?? '').toString());
    if (min.isNotEmpty && _cmp(current, min) < 0) return false;
    if (max.isNotEmpty && _cmp(current, max) > 0) return false;
    return true;
  }

  /// "v1.6.0+12" → "1.6.0" (digits and dots only).
  static String _normalize(String raw) {
    final m = RegExp(r'(\d+(?:\.\d+)*)').firstMatch(raw.trim());
    return m?.group(1) ?? '';
  }

  /// -1 / 0 / 1 comparison of dotted-int versions.
  static int _cmp(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }
}
