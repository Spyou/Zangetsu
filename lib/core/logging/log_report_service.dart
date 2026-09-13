import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../app_config.dart';
import '../app_mode.dart';
import '../di/injector.dart';
import '../mode/content_mode_cubit.dart';
import '../repository/source_repository.dart';
import '../zmode/zmode_prefs.dart';
import 'app_logger.dart';

/// Sends the in-app diagnostic log to the intake Worker
/// (`cloudflare/log-intake/`), which stores it and pings Discord.
///
/// Exists because the log was only ever reachable by asking the person to find
/// Settings, tap Share logs, and send the file somewhere — so in practice a bug
/// report arrived as a screen recording with no log at all.
///
/// Never throws: a failed upload falls back to the share sheet, which is what
/// the button did before.
class LogReportService {
  LogReportService(this._dio);

  final Dio _dio;

  /// True when there is somewhere to send to. False keeps the old share-sheet
  /// behaviour, so a build without the Worker deployed still works.
  bool get configured => kLogIntakeUrl.isNotEmpty;

  /// Uploads the current log. Returns the short reference to show the user, or
  /// null if it couldn't be sent.
  Future<String?> send({String note = ''}) async {
    if (!configured) return null;
    final text = AppLogger.instance.contents;
    if (text.trim().isEmpty) return null;

    try {
      // Logs are highly repetitive text — this is roughly a tenfold saving,
      // which is the difference between a report costing nothing and a bucket
      // that needs watching.
      final body = gzip.encode(utf8.encode(text));
      final res = await _dio.post<dynamic>(
        '$kLogIntakeUrl/v1/logs',
        data: Stream<List<int>>.fromIterable([body]),
        queryParameters: {
          // A query parameter, not a header: people write these in their own
          // language and HTTP headers are ASCII.
          if (note.trim().isNotEmpty) 'note': note.trim(),
        },
        options: Options(
          headers: {
            Headers.contentTypeHeader: 'application/gzip',
            Headers.contentLengthHeader: body.length,
            'X-App-Version':
                kAppBuild.isEmpty ? kAppVersion : '$kAppVersion+$kAppBuild',
            // Every one of these is best-effort. Describing the device must
            // never be the reason a report doesn't arrive.
            ...await _context(),
          },
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      return refOf(res.data);
    } catch (e) {
      debugPrint('[logs] report upload failed: $e');
      return null;
    }
  }

  /// The reference out of the Worker's reply, or null if it answered with
  /// anything else. Tolerant on purpose — a proxy or captive portal can return
  /// 200 with a login page, and that must read as "didn't send", not as a
  /// reference the user is then asked to quote back.
  @visibleForTesting
  static String? refOf(dynamic data) {
    Map<dynamic, dynamic>? map;
    if (data is Map) {
      map = data;
    } else if (data is String) {
      // A captive portal answers 200 with HTML, so this has to survive being
      // handed something that isn't JSON at all.
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) map = decoded;
      } catch (_) {
        return null;
      }
    }
    final ref = map?['ref'];
    if (ref is! String) return null;
    final trimmed = ref.trim();
    // The Worker's format: six characters from a fixed alphabet.
    return RegExp(r'^[0-9A-Z]{4,12}$').hasMatch(trimmed) ? trimmed : null;
  }

  /// What the report says about the device and setup, on top of the log.
  ///
  /// Every field is gathered separately and swallowed on failure: a missing
  /// line in a Discord message costs nothing, a report that never arrives
  /// because a plugin threw costs the whole point of this.
  ///
  /// Nothing identifying goes in — model and device class, never an account,
  /// an id, or anything that would make a 30-day-old report trace to a person.
  Future<Map<String, String>> _context() async {
    final out = <String, String>{};
    void put(String key, String Function() build) {
      try {
        final v = ascii(build());
        if (v.isNotEmpty) out[key] = v;
      } catch (_) {
        /* leave the field out */
      }
    }

    try {
      out['X-Device'] = ascii(await deviceLabel());
    } catch (_) {
      out['X-Device'] = 'unknown';
    }
    put('X-Form', () => sl<AppMode>().isTv ? 'tv' : 'phone');
    put('X-Sources', () => sourcesSummary(
          sl<SourceRepository>().pickableSources.map((s) => s.id).toList(),
        ));
    put(
      'X-Mode',
      () => '${sl<ContentModeCubit>().state.name}'
          '${ZModePrefs.enabled ? ' + zmode' : ''}',
    );
    return out;
  }

  /// HTTP headers are ASCII — a device model with a non-Latin character would
  /// otherwise throw on the way out.
  @visibleForTesting
  static String ascii(String s) =>
      s.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();

  /// How many sources are installed, by ecosystem. Most reports are about a
  /// source, and asking "what have you got installed" every time was a round
  /// trip that told us what the app already knew.
  @visibleForTesting
  static String sourcesSummary(List<String> ids) {
    var js = 0, cs = 0, ani = 0, mihon = 0, lnr = 0;
    for (final id in ids) {
      if (id.startsWith('cs:')) {
        cs++;
      } else if (id.startsWith('ani:')) {
        ani++;
      } else if (id.startsWith('mihon:')) {
        mihon++;
      } else if (id.startsWith('lnr:')) {
        lnr++;
      } else {
        js++;
      }
    }
    return 'js:$js cs:$cs ani:$ani mihon:$mihon lnr:$lnr';
  }

  /// Model and OS, e.g. `Xiaomi 2209116AG - Android 15 (SDK 35)`.
  ///
  /// Separators are plain ASCII on purpose: this rides in an HTTP header, and
  /// [ascii] would strip a nicer '·' and run the words together.
  ///
  /// `Platform.operatingSystemVersion` alone said "android 15", which is no
  /// help at all when half the open bugs are specific to one TV.
  @visibleForTesting
  static Future<String> deviceLabel() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return '${a.manufacturer} ${a.model} - Android '
            '${a.version.release} (SDK ${a.version.sdkInt})';
      }
      if (Platform.isIOS) {
        final i = await info.iosInfo;
        return '${i.model} - iOS ${i.systemVersion}';
      }
    } catch (_) {
      /* fall through to the plain one */
    }
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }
}
