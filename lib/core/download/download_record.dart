/// Lifecycle of one downloaded episode/movie.
enum DownloadStatus {
  queued, // accepted, waiting to resolve a source
  resolving, // calling the provider to find a direct-file stream
  downloading,
  paused,
  done,
  failed,
  unsupported, // no direct-file (e.g. HLS-only) source — phase 2
  canceled,
}

DownloadStatus _statusFromName(String? n) => DownloadStatus.values.firstWhere(
  (s) => s.name == n,
  orElse: () => DownloadStatus.queued,
);

/// A single download, persisted in the Hive `downloads` box (as a Map) so the
/// library survives restarts. [id] doubles as the background_downloader task id
/// and is deterministic per (source, episode) so re-downloads are idempotent.
class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    this.cover,
    this.coverHeaders,
    required this.showUrl,
    required this.episodeId,
    required this.episodeUrl,
    this.episodeNumber,
    required this.episodeTitle,
    required this.category,
    required this.quality,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.bytesTotal = 0,
    this.filePath,
    this.error,
    required this.createdAt,
  });

  final String id;
  final String sourceId;
  final String showId;
  final String showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String showUrl;
  final String episodeId;
  final String episodeUrl;
  final double? episodeNumber;
  final String episodeTitle;
  final String category; // sub/dub — kept for re-resolution + offline history
  final String quality; // requested quality label (e.g. '1080p' / 'best')
  final DownloadStatus status;
  final double progress; // 0..1
  final int bytesTotal; // expected file size in bytes (0 when unknown)
  final String? filePath; // final shared-storage path once complete
  final String? error;
  final int createdAt;

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.resolving ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.paused;

  DownloadRecord copyWith({
    DownloadStatus? status,
    double? progress,
    int? bytesTotal,
    String? Function()? filePath,
    String? Function()? error,
  }) => DownloadRecord(
    id: id,
    sourceId: sourceId,
    showId: showId,
    showTitle: showTitle,
    cover: cover,
    coverHeaders: coverHeaders,
    showUrl: showUrl,
    episodeId: episodeId,
    episodeUrl: episodeUrl,
    episodeNumber: episodeNumber,
    episodeTitle: episodeTitle,
    category: category,
    quality: quality,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    bytesTotal: bytesTotal ?? this.bytesTotal,
    filePath: filePath != null ? filePath() : this.filePath,
    error: error != null ? error() : this.error,
    createdAt: createdAt,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'sourceId': sourceId,
    'showId': showId,
    'showTitle': showTitle,
    'cover': cover,
    'coverHeaders': coverHeaders,
    'showUrl': showUrl,
    'episodeId': episodeId,
    'episodeUrl': episodeUrl,
    'episodeNumber': episodeNumber,
    'episodeTitle': episodeTitle,
    'category': category,
    'quality': quality,
    'status': status.name,
    'progress': progress,
    'bytesTotal': bytesTotal,
    'filePath': filePath,
    'error': error,
    'createdAt': createdAt,
  };

  factory DownloadRecord.fromMap(Map raw) {
    final m = Map<String, dynamic>.from(raw);
    return DownloadRecord(
      id: m['id'] as String,
      sourceId: m['sourceId'] as String? ?? '',
      showId: m['showId'] as String? ?? '',
      showTitle: m['showTitle'] as String? ?? '',
      cover: m['cover'] as String?,
      coverHeaders: (m['coverHeaders'] as Map?)?.map(
        (k, v) => MapEntry('$k', '$v'),
      ),
      showUrl: m['showUrl'] as String? ?? '',
      episodeId: m['episodeId'] as String? ?? '',
      episodeUrl: m['episodeUrl'] as String? ?? '',
      episodeNumber: (m['episodeNumber'] as num?)?.toDouble(),
      episodeTitle: m['episodeTitle'] as String? ?? '',
      category: m['category'] as String? ?? 'sub',
      quality: m['quality'] as String? ?? 'best',
      status: _statusFromName(m['status'] as String?),
      progress: (m['progress'] as num?)?.toDouble() ?? 0,
      bytesTotal: (m['bytesTotal'] as num?)?.toInt() ?? 0,
      filePath: m['filePath'] as String?,
      error: m['error'] as String?,
      createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}
