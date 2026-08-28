import 'debrid_result.dart';

/// Debrid backends supported in v1, plus the file-pick heuristic shared with
/// the native torrent engine (largest video extension).

enum DebridService {
  realDebrid,
  torbox;

  String get displayName => switch (this) {
        realDebrid => 'Real-Debrid',
        torbox => 'TorBox',
      };

  /// Overlay copy while that service is resolving a magnet.
  String get phaseLabel => switch (this) {
        realDebrid => 'Resolving via Real-Debrid…',
        torbox => 'Waiting for TorBox…',
      };

  String get tokenHelpUrl => switch (this) {
        realDebrid => 'https://real-debrid.com/apitoken',
        torbox => 'https://torbox.app/settings',
      };

  String get tokenHelp => switch (this) {
        realDebrid =>
          'Paste the API token from real-debrid.com/apitoken. It stays on '
              'this device only — never in backup or the cloud.',
        torbox =>
          'Paste the API key from TorBox Settings. It stays on this device '
              'only — never in backup or the cloud.',
      };
}

enum DebridMode {
  off,
  prefer,
  always;

  String get label => switch (this) {
        off => 'Off',
        prefer => 'Prefer',
        always => 'Always',
      };

  String get description => switch (this) {
        off => 'Stream torrents on this device only',
        prefer => 'Try debrid first; fall back to local torrent if it misses',
        always => 'Debrid only — no local torrent fallback',
      };

  static DebridMode fromName(String? raw) => switch (raw) {
        'prefer' => DebridMode.prefer,
        'always' => DebridMode.always,
        _ => DebridMode.off,
      };
}

/// Same extensions the native torrent engine uses when picking a file.
const List<String> kDebridVideoExts = [
  '.mp4',
  '.mkv',
  '.avi',
  '.webm',
  '.mov',
  '.m4v',
  '.ts',
  '.flv',
];

class DebridFile {
  const DebridFile({
    required this.id,
    required this.path,
    required this.bytes,
  });

  final String id;
  final String path;
  final int bytes;

  String get name {
    final n = path.replaceAll('\\', '/');
    final slash = n.lastIndexOf('/');
    return slash < 0 ? n : n.substring(slash + 1);
  }
}

bool isVideoFilename(String path) {
  final n = path.toLowerCase();
  return kDebridVideoExts.any(n.endsWith);
}

/// Prefer the largest video file; if none match, the largest file overall.
DebridFile? pickLargestVideo(Iterable<DebridFile> files) {
  final list = files.toList();
  if (list.isEmpty) return null;
  final videos = list.where((f) => isVideoFilename(f.path)).toList();
  final pool = videos.isNotEmpty ? videos : list;
  pool.sort((a, b) => b.bytes.compareTo(a.bytes));
  return pool.first;
}

/// HTTP client each debrid backend implements.
abstract class DebridClient {
  DebridService get service;

  Future<bool> validateToken(String token);

  /// Resolve [uri] (magnet or .torrent URL) to a direct HTTP link.
  ///
  /// When [requireCached] is true (Prefer mode), return [DebridFailure.notCached]
  /// quickly instead of waiting for the provider to download the torrent.
  Future<DebridResolved> resolve(
    String uri, {
    required String token,
    required Duration timeout,
    bool requireCached = false,
    void Function(String phase)? onPhase,
  });
}
