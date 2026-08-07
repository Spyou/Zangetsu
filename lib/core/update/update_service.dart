import 'dart:io';
import 'package:watch_app/core/hive/safe_box.dart';

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
    this.isPrerelease = false,
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

  /// True when the chosen release is a GitHub pre-release (beta).
  final bool isPrerelease;
}

/// In-app updater: checks the public GitHub Releases of the app repo, compares
/// the latest tag to the running build, downloads the matching APK and hands it
/// to the Android package installer. The repo is public, so no token is needed.
class UpdateService {
  static const String _repo = 'Spyou/Zangetsu';
  static const String _latestUrl =
      'https://api.github.com/repos/$_repo/releases/latest';
  static const String _releasesUrl =
      'https://api.github.com/repos/$_repo/releases?per_page=10';
  static const String _boxName = 'updates';
  static const String _skipKey = 'skippedVersion';
  static const String _betaKey = 'betaOptIn';

  final Dio _dio = Dio();

  /// Query GitHub for the latest release. Returns an [UpdateInfo] when it is
  /// newer than the installed version (and, when [respectSkip] is true, not the
  /// version the user chose to skip). Returns null on no-update or any error —
  /// callers must treat null as "nothing to do" (never throws).
  Future<UpdateInfo?> checkForUpdate({bool respectSkip = false}) async {
    try {
      final beta = await betaOptIn();
      final release =
          beta ? await _newestBetaRelease() : await _latestStableRelease();
      if (release == null) return null;

      final rawTag = ((release['tag_name'] as String?) ?? '').trim();
      if (rawTag.isEmpty) return null;
      final version = rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;

      final pkg = await PackageInfo.fromPlatform();
      if (compareVersions(version, pkg.version) <= 0) return null;
      if (respectSkip && await _skippedVersion() == version) return null;

      final apk = _pickApk(
          (release['assets'] as List?) ?? const [], await _deviceAbis());
      if (apk == null) return null;

      return UpdateInfo(
        version: version,
        notes: ((release['body'] as String?) ?? '').trim(),
        apkUrl: apk.$2,
        assetName: apk.$1,
        apkSize: apk.$3,
        isPrerelease: release['prerelease'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Latest **stable** release — GitHub's /releases/latest excludes
  /// pre-releases, so this is the toggle-off behaviour (unchanged from before).
  Future<Map<String, dynamic>?> _latestStableRelease() async {
    final res = await _dio.get<Map<String, dynamic>>(
      _latestUrl,
      options: Options(
        headers: const {'Accept': 'application/vnd.github+json'},
        receiveTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 12),
      ),
    );
    return res.data;
  }

  /// Newest release **including pre-releases** — the toggle-on behaviour.
  /// Scans the recent releases list and returns the highest version by
  /// [compareVersions]; skips drafts.
  Future<Map<String, dynamic>?> _newestBetaRelease() async {
    final res = await _dio.get<List<dynamic>>(
      _releasesUrl,
      options: Options(
        headers: const {'Accept': 'application/vnd.github+json'},
        receiveTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 12),
      ),
    );
    final list = res.data;
    if (list == null || list.isEmpty) return null;
    Map<String, dynamic>? best;
    var bestVer = '';
    for (final item in list) {
      if (item is! Map) continue;
      final m = item.cast<String, dynamic>();
      if (m['draft'] == true) continue;
      final tag = ((m['tag_name'] as String?) ?? '').trim();
      if (tag.isEmpty) continue;
      final v = tag.startsWith('v') ? tag.substring(1) : tag;
      if (best == null || compareVersions(v, bestVer) > 0) {
        best = m;
        bestVer = v;
      }
    }
    return best;
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

  /// Whether the user opted into pre-release (beta) updates. Defaults to false.
  Future<bool> betaOptIn() async =>
      (await _box()).get(_betaKey, defaultValue: false) as bool;

  /// Persist the beta opt-in choice.
  Future<void> setBetaOptIn(bool value) async =>
      (await _box()).put(_betaKey, value);

  Future<Box> _box() async => Hive.isBoxOpen(_boxName)
      ? Hive.box(_boxName)
      : await openBoxSafely(_boxName);

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

  /// Compare two version strings with semver pre-release ordering.
  /// Returns <0 if [a] < [b], 0 if equal, >0 if [a] > [b].
  /// A leading "v" is ignored. Rules: higher numeric core wins; on an equal
  /// core a final build (no "-label") outranks a pre-release ("-betaN"); two
  /// pre-releases are ordered by the label's trailing integer (beta2 > beta1).
  static int compareVersions(String a, String b) {
    final pa = _parseVersion(a);
    final pb = _parseVersion(b);
    final len = pa.core.length > pb.core.length ? pa.core.length : pb.core.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.core.length ? pa.core[i] : 0;
      final y = i < pb.core.length ? pb.core[i] : 0;
      if (x != y) return x < y ? -1 : 1;
    }
    // Cores equal → a final (pre == null) is greater than any pre-release.
    if (pa.pre == null && pb.pre == null) return 0;
    if (pa.pre == null) return 1;
    if (pb.pre == null) return -1;
    if (pa.pre != pb.pre) return pa.pre! < pb.pre! ? -1 : 1;
    return 0;
  }

  /// "v1.9.2-beta3" → (core: [1,9,2], pre: 3). No label → pre == null. A label
  /// without digits ("beta") → pre == 0.
  static ({List<int> core, int? pre}) _parseVersion(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final dash = s.indexOf('-');
    final corePart = dash >= 0 ? s.substring(0, dash) : s;
    final label = dash >= 0 ? s.substring(dash + 1) : null;
    final core =
        corePart.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    int? pre;
    if (label != null) {
      final m = RegExp(r'(\d+)').firstMatch(label);
      pre = m != null ? int.parse(m.group(1)!) : 0;
    }
    return (core: core, pre: pre);
  }
}
