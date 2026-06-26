import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// A newer release found on GitHub.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.assetName,
    required this.apkSize,
  });

  /// Normalised version, e.g. "1.3.0".
  final String version;

  /// Release notes (the GitHub release body).
  final String notes;

  /// Direct download URL of the chosen .apk asset.
  final String apkUrl;

  /// File name of the chosen asset (shown while downloading).
  final String assetName;

  /// Expected byte size of the asset (from the GitHub API), used to verify the
  /// download completed intact. 0 when unknown.
  final int apkSize;
}

/// In-app updater: checks the public GitHub Releases of the app repo, compares
/// the latest tag to the running build, downloads the matching APK and hands it
/// to the Android package installer. The repo is public, so no token is needed.
class UpdateService {
  static const String _repo = 'Spyou/Zangetsu';
  static const String _latestUrl =
      'https://api.github.com/repos/$_repo/releases/latest';
  static const String _boxName = 'updates';
  static const String _skipKey = 'skippedVersion';

  final Dio _dio = Dio();

  /// Query GitHub for the latest release. Returns an [UpdateInfo] when it is
  /// newer than the installed version (and, when [respectSkip] is true, not the
  /// version the user chose to skip). Returns null on no-update or any error —
  /// callers must treat null as "nothing to do" (never throws).
  Future<UpdateInfo?> checkForUpdate({bool respectSkip = false}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        _latestUrl,
        options: Options(
          headers: const {'Accept': 'application/vnd.github+json'},
          receiveTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
        ),
      );
      final data = res.data;
      if (data == null) return null;

      final latest = _normalize((data['tag_name'] as String?) ?? '');
      if (latest.isEmpty) return null;

      final info = await PackageInfo.fromPlatform();
      final current = _normalize(info.version);
      if (!_isNewer(latest, current)) return null;

      if (respectSkip && await _skippedVersion() == latest) return null;

      final apk = _pickApk((data['assets'] as List?) ?? const [], await _deviceAbis());
      if (apk == null) return null;

      return UpdateInfo(
        version: latest,
        notes: ((data['body'] as String?) ?? '').trim(),
        apkUrl: apk.$2,
        assetName: apk.$1,
        apkSize: apk.$3,
      );
    } catch (_) {
      return null;
    }
  }

  /// The installed version string (e.g. "1.2.0"), for display.
  Future<String> currentVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '';
    }
  }

  /// Download the APK to the cache dir, reporting 0..1 progress. Throws on
  /// failure so the dialog can surface an error.
  Future<File> downloadApk(
    String url, {
    int expectedSize = 0,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/zangetsu-update.apk';
    final file = File(path);
    if (await file.exists()) await file.delete(); // drop any stale partial
    await _dio.download(
      url,
      path,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );
    // Integrity guard: a truncated/corrupt download would otherwise be handed to
    // the installer and rejected as "package appears to be invalid". Fail loudly
    // instead so the user just retries the download.
    if (expectedSize > 0) {
      final actual = await file.length();
      if (actual != expectedSize) {
        await file.delete();
        throw Exception(
          'Download incomplete ($actual/$expectedSize bytes) — please retry.',
        );
      }
    }
    return file;
  }

  /// Hand the APK to the system installer. Requests the "install unknown apps"
  /// permission first. Returns false if the permission was denied or the
  /// installer couldn't be launched.
  Future<bool> installApk(File apk) async {
    if (Platform.isAndroid) {
      final status = await Permission.requestInstallPackages.request();
      if (!status.isGranted) return false;
    }
    final res = await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    return res.type == ResultType.done;
  }

  /// Remember a version the user chose to skip (so auto-check won't re-prompt).
  Future<void> skipVersion(String version) async {
    (await _box()).put(_skipKey, version);
  }

  Future<String?> _skippedVersion() async =>
      (await _box()).get(_skipKey) as String?;

  Future<Box> _box() async => Hive.isBoxOpen(_boxName)
      ? Hive.box(_boxName)
      : await Hive.openBox(_boxName);

  /// This device's supported ABIs, best-first (e.g. ["arm64-v8a","armeabi-v7a"]).
  /// Empty on non-Android or any error — callers fall back to the universal APK.
  Future<List<String>> _deviceAbis() async {
    try {
      if (!Platform.isAndroid) return const [];
      final info = await DeviceInfoPlugin().androidInfo;
      return info.supportedAbis;
    } catch (_) {
      return const [];
    }
  }

  /// Pick the asset to download. Prefer the per-ABI APK matching THIS device
  /// (in the device's own ABI-preference order) — it's ~40% smaller than the
  /// fat universal, so the download is faster and far less likely to truncate,
  /// and the smaller package installs more reliably (a partial/oversized APK is
  /// what surfaces as "package appears to be invalid"). Fall back to the
  /// universal APK, then any .apk. Returns (name, url, size) or null.
  (String, String, int)? _pickApk(List assets, List<String> abis) {
    final apks = <(String, String, int)>[];
    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a['name'] as String?) ?? '';
      final url = (a['browser_download_url'] as String?) ?? '';
      final size = (a['size'] as num?)?.toInt() ?? 0;
      if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) {
        apks.add((name, url, size));
      }
    }
    if (apks.isEmpty) return null;
    (String, String, int)? withFrag(String frag) {
      for (final x in apks) {
        if (x.$1.toLowerCase().contains(frag.toLowerCase())) return x;
      }
      return null;
    }

    for (final abi in abis) {
      final match = withFrag(abi);
      if (match != null) return match;
    }
    return withFrag('universal') ?? apks.first;
  }

  /// "v1.3.0+4" / "1.3.0-beta" → "1.3.0" (digits-and-dots only).
  static String _normalize(String raw) {
    final m = RegExp(r'(\d+(?:\.\d+)*)').firstMatch(raw.trim());
    return m?.group(1) ?? '';
  }

  /// True when [a] is a strictly higher dotted-int version than [b].
  static bool _isNewer(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
