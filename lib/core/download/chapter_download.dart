import '../mode/content_mode.dart';

enum ChapterDownloadStatus { queued, downloading, done, failed }

/// One saved manga or novel chapter.
///
/// Deliberately NOT part of [DownloadRecord]. That model carries quality,
/// sub/dub, subtitle sidecars and a torrent flag, and its pipeline is HLS
/// segments and a foreground service — none of which a chapter has or needs.
/// Bolting nullable fields onto it would put reading downloads in the way of
/// video downloads for no gain.
class ChapterDownload {
  const ChapterDownload({
    required this.id,
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    required this.chapterId,
    required this.chapterUrl,
    required this.chapterTitle,
    required this.mode,
    required this.status,
    this.cover,
    this.pageCount = 0,
    this.pagesDone = 0,
    this.bytes = 0,
    this.error,
    this.createdAt = 0,
    this.pagePaths = const <String>[],
    this.textPath,
    this.number,
    this.archivePath,
  });

  /// `sourceId|chapterUrl` — stable across a chapter-list refetch, which
  /// chapter ids from some sources are not.
  final String id;
  final String sourceId;
  final String showId;
  final String showTitle;
  final String? cover;
  final String chapterId;
  final String chapterUrl;
  final String chapterTitle;

  /// manga or novel. Drives which reader opens it and which icon it gets;
  /// there is no separate screen per mode.
  final ContentMode mode;

  final ChapterDownloadStatus status;

  /// Manga only — novels are a single text blob, so both stay 0.
  final int pageCount;
  final int pagesDone;

  final int bytes;
  final String? error;
  final int createdAt;

  /// Absolute page files in reading order (manga). Recorded explicitly rather
  /// than listed off disk: once a chapter lands in the shared Downloads folder
  /// its files go in through MediaStore, and the app can open them by path but
  /// can't reliably list the directory back.
  ///
  /// Empty for a novel, and for chapters saved by an older build — those still
  /// resolve by listing their app-private folder.
  final List<String> pagePaths;

  /// Absolute path of the saved HTML (novel). Null for manga and for older
  /// records, same as above.
  final String? textPath;

  /// The `.cbz` holding this chapter's pages (manga). One zip beats forty
  /// loose images: it keeps the pages out of the gallery scanner, and any
  /// comic reader can open it.
  ///
  /// Null for novels, and for manga saved by an older build — those still read
  /// from [pagePaths].
  final String? archivePath;

  /// The source's chapter number, when it gives one. Only used to put a show's
  /// saved chapters back in reading order when they're opened from the
  /// downloads screen — download order isn't reading order.
  final double? number;

  bool get isActive =>
      status == ChapterDownloadStatus.queued ||
      status == ChapterDownloadStatus.downloading;

  double get progress {
    if (status == ChapterDownloadStatus.done) return 1;
    if (pageCount <= 0) return 0;
    return (pagesDone / pageCount).clamp(0.0, 1.0);
  }

  static String idFor(String sourceId, String chapterUrl) =>
      '$sourceId|$chapterUrl';

  ChapterDownload copyWith({
    ChapterDownloadStatus? status,
    int? pageCount,
    int? pagesDone,
    int? bytes,
    String? Function()? error,
    List<String>? pagePaths,
    String? textPath,
    String? archivePath,
  }) => ChapterDownload(
    number: number,
    archivePath: archivePath ?? this.archivePath,
    id: id,
    sourceId: sourceId,
    showId: showId,
    showTitle: showTitle,
    cover: cover,
    chapterId: chapterId,
    chapterUrl: chapterUrl,
    chapterTitle: chapterTitle,
    mode: mode,
    status: status ?? this.status,
    pageCount: pageCount ?? this.pageCount,
    pagesDone: pagesDone ?? this.pagesDone,
    bytes: bytes ?? this.bytes,
    error: error != null ? error() : this.error,
    createdAt: createdAt,
    pagePaths: pagePaths ?? this.pagePaths,
    textPath: textPath ?? this.textPath,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'showId': showId,
    'showTitle': showTitle,
    'cover': cover,
    'chapterId': chapterId,
    'chapterUrl': chapterUrl,
    'chapterTitle': chapterTitle,
    'mode': mode.name,
    'status': status.name,
    'pageCount': pageCount,
    'pagesDone': pagesDone,
    'bytes': bytes,
    'error': error,
    'createdAt': createdAt,
    'pagePaths': pagePaths,
    'textPath': textPath,
    'number': number,
    'archivePath': archivePath,
  };

  static ChapterDownload? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final id = m['id'];
    if (id is! String || id.isEmpty) return null;
    return ChapterDownload(
      id: id,
      sourceId: '${m['sourceId'] ?? ''}',
      showId: '${m['showId'] ?? ''}',
      showTitle: '${m['showTitle'] ?? ''}',
      cover: m['cover'] as String?,
      chapterId: '${m['chapterId'] ?? ''}',
      chapterUrl: '${m['chapterUrl'] ?? ''}',
      chapterTitle: '${m['chapterTitle'] ?? ''}',
      mode: ContentMode.values.firstWhere(
        (e) => e.name == m['mode'],
        orElse: () => ContentMode.manga,
      ),
      // Anything caught mid-flight when the app died is failed, not
      // downloading — otherwise it sits at a progress bar that never moves.
      status: switch (m['status']) {
        'done' => ChapterDownloadStatus.done,
        'failed' => ChapterDownloadStatus.failed,
        _ => ChapterDownloadStatus.failed,
      },
      pageCount: (m['pageCount'] as num?)?.toInt() ?? 0,
      pagesDone: (m['pagesDone'] as num?)?.toInt() ?? 0,
      bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      error: m['error'] as String?,
      createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      pagePaths:
          (m['pagePaths'] as List?)?.map((e) => '$e').toList() ??
          const <String>[],
      textPath: m['textPath'] as String?,
      number: (m['number'] as num?)?.toDouble(),
      archivePath: m['archivePath'] as String?,
    );
  }
}
