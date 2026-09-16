import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/di/injector.dart';
import '../../core/download/chapter_download.dart';
import '../../core/download/chapter_download_store.dart';
import '../../core/download/download_prefs.dart';
import '../../core/export/epub_writer.dart';
import '../../core/models/episode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';
import '../settings/download_location_screen.dart';

/// "Export as EPUB" — packs every DOWNLOADED chapter of a novel (or a picked
/// range of them) into a real EPUB file. A chapter's text only exists on
/// disk once it's been downloaded, so the sheet says up front how many of
/// the total are actually available and won't let you export none of them.
Future<void> showEpubExportSheet(
  BuildContext context, {
  required String sourceId,
  required String showTitle,
  required List<Episode> chapters,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _EpubExportBody(
      sourceId: sourceId,
      showTitle: showTitle,
      chapters: chapters,
    ),
  );
}

class _EpubExportBody extends StatefulWidget {
  const _EpubExportBody({
    required this.sourceId,
    required this.showTitle,
    required this.chapters,
  });

  final String sourceId;
  final String showTitle;
  final List<Episode> chapters;

  @override
  State<_EpubExportBody> createState() => _EpubExportBodyState();
}

class _EpubExportBodyState extends State<_EpubExportBody> {
  late final List<Episode> _downloaded = widget.chapters
      .where(
        (e) => sl<ChapterDownloadStore>().isDownloaded(widget.sourceId, e.url),
      )
      .toList();

  late final TextEditingController _nameCtrl = TextEditingController(
    text: widget.showTitle,
  );

  bool _allChapters = true;
  int _startIdx = 0;
  int _endIdx = 0;
  bool _includeNumber = true;

  bool _exporting = false;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    if (_downloaded.isNotEmpty) _endIdx = _downloaded.length - 1;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  List<Episode> get _selected {
    if (_downloaded.isEmpty) return const [];
    if (_allChapters) return _downloaded;
    final lo = _startIdx.clamp(0, _downloaded.length - 1);
    final hi = _endIdx.clamp(lo, _downloaded.length - 1);
    return _downloaded.sublist(lo, hi + 1);
  }

  Future<void> _pickIndex({required bool isStart}) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _downloaded.length,
          itemBuilder: (listContext, i) => ListTile(
            title: Text(
              _downloaded[i].title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.body,
            ),
            trailing: i == (isStart ? _startIdx : _endIdx)
                ? Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
            onTap: () => Navigator.of(listContext).pop(i),
          ),
        ),
      ),
    );
    if (chosen == null) return;
    setState(() {
      if (isStart) {
        _startIdx = chosen;
        if (_endIdx < _startIdx) _endIdx = _startIdx;
      } else {
        _endIdx = chosen;
        if (_startIdx > _endIdx) _startIdx = _endIdx;
      }
    });
  }

  Future<void> _changeFolder() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DownloadLocationScreen()),
    );
    if (mounted) setState(() {}); // the folder label may have changed
  }

  /// The chosen drive path, mirroring `ChapterDownloadStore._drivePath()` —
  /// same rule, re-expressed here since that helper is private to its own
  /// file: a picked drive (USB/SD) is a plain path we can write to directly,
  /// a SAF `content://` tree isn't, so that case falls through to the
  /// shared-storage move below. Not a third mechanism, the same two.
  String? _drivePath() {
    if (!sl.isRegistered<DownloadPrefs>()) return null;
    final loc = sl<DownloadPrefs>().locationUri;
    if (loc == null || loc.isEmpty || isUriPath(loc)) return null;
    return loc;
  }

  /// Moves the written EPUB out of app storage and into the user's download
  /// folder, exactly the way `ChapterDownloadStore.publish` does for a
  /// chapter: a picked drive gets a plain file copy, otherwise it goes
  /// through the shared Downloads folder. Returns the final path, or null if
  /// the move failed (the file is left at [local] either way).
  Future<String?> _publish(File local, String subDir) async {
    final drive = _drivePath();
    if (drive != null) {
      try {
        final dir = Directory('$drive/$subDir');
        await dir.create(recursive: true);
        final dest = '${dir.path}/${local.uri.pathSegments.last}';
        await local.copy(dest);
        await local.delete();
        return dest;
      } catch (_) {
        return null;
      }
    }
    try {
      return await FileDownloader().moveFileToSharedStorage(
        local.path,
        SharedStorage.downloads,
        directory: subDir,
      );
    } catch (_) {
      return null;
    }
  }

  /// This chapter's saved images, keyed by the bare filename its html's
  /// `<img src>` already uses (`img_0.jpg`, …) — the exact layout
  /// `ChapterDownloader._downloadImages` wrote them in, beside `text.html`.
  Future<Map<String, String>> _imagesFor(ChapterDownload rec) async {
    final dir = rec.textPath != null
        ? File(rec.textPath!).parent
        : await sl<ChapterDownloadStore>().dirFor(rec);
    if (!await dir.exists()) return const {};
    final out = <String, String>{};
    await for (final f in dir.list()) {
      if (f is File && f.path != rec.textPath && !f.path.endsWith('.html')) {
        out[f.uri.pathSegments.last] = f.path;
      }
    }
    return out;
  }

  Future<void> _export() async {
    final chapters = _selected;
    if (chapters.isEmpty || _exporting) return;
    setState(() {
      _exporting = true;
      _done = 0;
      _total = chapters.length;
    });

    final store = sl<ChapterDownloadStore>();
    final built = <EpubChapter>[];
    for (final ep in chapters) {
      final rec = store.get(ChapterDownload.idFor(widget.sourceId, ep.url));
      if (rec == null) continue;
      final html = await store.localText(rec);
      if (html == null) continue;
      built.add(
        EpubChapter(
          title: EpubWriter.chapterTitle(
            ep.title,
            ep.number,
            includeNumber: _includeNumber,
          ),
          html: html,
          images: await _imagesFor(rec),
        ),
      );
    }

    final baseName = ChapterDownloadStore.safeName(
      _nameCtrl.text.trim().isEmpty ? widget.showTitle : _nameCtrl.text.trim(),
    );
    final tmpDir = await getTemporaryDirectory();
    final tmpPath = '${tmpDir.path}/$baseName.epub';

    File written;
    try {
      written = await EpubWriter.write(
        outPath: tmpPath,
        title: widget.showTitle,
        chapters: built,
        onProgress: (done, total) {
          if (mounted) setState(() => _done = done);
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() => _exporting = false);
        showAppToast(context, context.l10n.epubExportFailed);
      }
      return;
    }

    final show = 'Zangetsu/${ChapterDownloadStore.safeName(widget.showTitle)}';
    final saved = await _publish(written, show);
    if (!mounted) return;
    setState(() => _exporting = false);
    final folderLabel =
        sl<DownloadPrefs>().locationLabel ?? context.l10n.downloadsZangetsu;
    Navigator.of(context).pop();
    showAppToast(
      context,
      saved != null
          ? context.l10n.exportedToFolder(folderLabel)
          : context.l10n.epubExportFailed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final total = widget.chapters.length;
    final downloadedCount = _downloaded.length;
    final canExport = downloadedCount > 0 && !_exporting;
    final folderLabel =
        sl<DownloadPrefs>().locationLabel ?? l10n.downloadsZangetsu;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(l10n.exportAsEpub, style: AppText.headline),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  downloadedCount == 0
                      ? l10n.noChaptersDownloadedToExport
                      : l10n.chaptersDownloadedCount(downloadedCount, total),
                  style: AppText.caption.copyWith(
                    color: downloadedCount == 0
                        ? AppColors.accent
                        : AppColors.textSecondary,
                  ),
                ),
              ),
              if (downloadedCount > 0) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text(l10n.fileNameLabel, style: AppText.caption),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      controller: _nameCtrl,
                      style: AppText.body,
                      cursorColor: AppColors.accent,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.folder_rounded,
                      title: l10n.folderLabel,
                      subtitle: folderLabel,
                      trailing: TextButton(
                        onPressed: _changeFolder,
                        child: Text(l10n.change),
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.menu_book_rounded,
                      title: l10n.allChapters,
                      trailing: Switch(
                        value: _allChapters,
                        onChanged: (v) => setState(() => _allChapters = v),
                      ),
                    ),
                    if (!_allChapters) ...[
                      SettingsTile(
                        icon: Icons.first_page_rounded,
                        title: l10n.startChapter,
                        subtitle: _downloaded[_startIdx].title,
                        onTap: () => _pickIndex(isStart: true),
                      ),
                      SettingsTile(
                        icon: Icons.last_page_rounded,
                        title: l10n.endChapter,
                        subtitle: _downloaded[_endIdx].title,
                        onTap: () => _pickIndex(isStart: false),
                      ),
                    ],
                    SettingsTile(
                      icon: Icons.format_list_numbered_rounded,
                      title: l10n.includeChapterNumber,
                      subtitle: l10n.includeChapterNumberSubtitle,
                      subtitleMaxLines: null,
                      trailing: Switch(
                        value: _includeNumber,
                        onChanged: (v) => setState(() => _includeNumber = v),
                      ),
                    ),
                  ],
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: _exporting
                    ? Column(
                        children: [
                          LinearProgressIndicator(
                            value: _total == 0 ? null : _done / _total,
                            color: AppColors.accent,
                            backgroundColor: AppColors.surface2,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.exportingChapterProgress(_done, _total),
                            style: AppText.caption,
                          ),
                        ],
                      )
                    : FilledButton(
                        onPressed: canExport ? _export : null,
                        child: Text(l10n.export),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
